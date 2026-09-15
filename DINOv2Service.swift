//
//  DINOv2Service.swift
//  Vision Builder
//
//  On-device DINOv2-small inference for INSTANCE IDENTITY — telling *which* dog,
//  *which* truck, not *what kind*. This is the counterpart to MobileCLIPService:
//  CLIP answers "is this a dog", DINOv2 answers "is this the same dog".
//
//  Measured 2026-09-14 against 4,959 real camera-roll photos (194 dog crops,
//  three animals confirmed by name):
//    - DINOv2-small @ cosine distance 0.75 -> Shanti 26/26, Theo 27/28, Rupert 9/9,
//      all three kept apart.
//    - CLIP-class embeddings cannot do this at ANY threshold: loosen and all 86 dogs
//      collapse into one cluster of 83, tighten and everything is a singleton.
//  Do not swap this back to a semantic embedder for identity work.
//

import CoreML
import Foundation
import UIKit

final class DINOv2Service {

    // MARK: - Configuration

    /// Embedding dimension for DINOv2-small.
    static let embeddingDimension = 384

    /// Input side. Position encodings are baked for this size at conversion time
    /// (see scripts/convert_dinov2.py) — changing it requires reconverting the model.
    static let imageInputSize = 224

    /// Cosine DISTANCE at which two crops are the same individual.
    /// Measured, not guessed: 0.75 separates all three known dogs under direct-resize
    /// preprocessing. 0.80 merges two of them. Note this is distance (1 - similarity),
    /// unlike ObjectRecognitionEngine's similarity thresholds.
    static let sameInstanceDistance: Float = 0.75

    private enum ModelNames {
        static let embedder = "dinov2_small_fp16"
    }

    // MARK: - State

    private var model: MLModel?
    private var isLoaded = false

    init() {}

    // MARK: - Loading

    func ensureModelLoaded() async throws {
        guard !isLoaded else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        guard let url = Bundle.main.url(forResource: ModelNames.embedder, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: ModelNames.embedder, withExtension: "mlpackage") else {
            throw DINOv2Error.modelNotFound
        }
        model = try MLModel(contentsOf: url, configuration: config)
        isLoaded = true
    }

    // MARK: - Embedding

    /// L2-normalized 384-dim identity embedding for one object crop.
    func generateEmbedding(for image: UIImage) async throws -> [Float] {
        try await ensureModelLoaded()
        guard let model else { throw DINOv2Error.modelNotLoaded }
        guard let pixelBuffer = preprocess(image) else { throw DINOv2Error.preprocessingFailed }

        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: pixelBuffer])
        let result = try await model.prediction(from: input)

        guard let array = firstMultiArray(in: result) else { throw DINOv2Error.embeddingExtractionFailed }
        var out = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count { out[i] = array[i].floatValue }
        return normalizeL2(out)
    }

    // MARK: - Comparison

    /// Cosine distance in 0...2. Compare against `sameInstanceDistance`.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return 1 - dot          // inputs are already L2-normalized
    }

    static func isSameInstance(_ a: [Float], _ b: [Float]) -> Bool {
        distance(a, b) <= sameInstanceDistance
    }

    // MARK: - Preprocessing

    /// Direct resize — deliberately NOT aspect-fill + center crop.
    ///
    /// MobileCLIPService center-crops because that is CLIP's training geometry for whole
    /// scenes. These inputs are already tight object crops, so center-cropping shaves the
    /// subject's edges off. Measured on the 194 dog crops: center-crop loses 6 of Theo's
    /// 28 photos at distance 0.70 and MERGES two different dogs at 0.80; direct resize
    /// holds all three apart at every threshold tested.
    private func preprocess(_ image: UIImage) -> CVPixelBuffer? {
        let side = Self.imageInputSize
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let cgImage = image.cgImage,
              let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: side, height: side,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }

    // MARK: - Helpers

    private func firstMultiArray(in result: MLFeatureProvider) -> MLMultiArray? {
        if let feature = result.featureValue(for: "embedding"), let array = feature.multiArrayValue {
            return array
        }
        for name in result.featureNames {
            if let feature = result.featureValue(for: name), let array = feature.multiArrayValue {
                return array
            }
        }
        return nil
    }

    private func normalizeL2(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let n = sqrt(sum)
        guard n > 1e-9 else { return v }
        return v.map { $0 / n }
    }
}

enum DINOv2Error: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case preprocessingFailed
    case embeddingExtractionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "dinov2_small_fp16 is not bundled. Run scripts/convert_dinov2.py."
        case .modelNotLoaded: return "DINOv2 model not loaded."
        case .preprocessingFailed: return "Could not build a pixel buffer for the crop."
        case .embeddingExtractionFailed: return "No embedding output in the model result."
        }
    }
}
