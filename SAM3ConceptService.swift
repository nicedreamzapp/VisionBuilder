//
//  SAM3ConceptService.swift
//  Vision Builder
//
//  Text-prompted segmentation: type a concept ("coffee mug") → segment every
//  instance in the image. Backed by EfficientSAM3 (distilled SAM3) when its
//  CoreML mlpackage is bundled. Falls back to .unavailable until then; the UI
//  should call `isAvailable` before exposing the feature.
//

import CoreML
import Foundation
import UIKit

/// One segmentation mask + metadata for a detected concept instance.
struct ConceptSegment {
    let label: String
    let score: Float
    let bbox: CGRect          // Normalized 0-1
    let centerPoint: CGPoint  // Normalized 0-1
    let mask: [UInt8]?        // Optional RLE/binary mask, nil when only bbox is needed
    let maskWidth: Int
    let maskHeight: Int
}

@MainActor
final class SAM3ConceptService {

    static let shared = SAM3ConceptService()

    private enum ModelNames {
        static let imageEncoder = "efficient_sam3_image_encoder"
        static let decoder = "efficient_sam3_decoder"
    }

    /// Image encoder is heavy → load lazily, share across calls in a session.
    private var imageEncoder: MLModel?
    private var decoder: MLModel?
    private var didAttemptLoad = false

    /// Reuses the project's MobileCLIP text encoder for concept prompts.
    /// EfficientSAM3 student text encoder is a MobileCLIP variant by construction.
    private let mobileCLIP = MobileCLIPService()

    private init() {}

    /// True when both EfficientSAM3 packages are bundled. Hide the UI when false.
    var isAvailable: Bool {
        Bundle.main.url(forResource: ModelNames.imageEncoder, withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: ModelNames.decoder, withExtension: "mlmodelc") != nil
    }

    func ensureLoaded() async throws {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        guard let imageURL = Bundle.main.url(forResource: ModelNames.imageEncoder, withExtension: "mlmodelc"),
              let decoderURL = Bundle.main.url(forResource: ModelNames.decoder, withExtension: "mlmodelc") else {
            throw SAM3Error.modelsNotBundled
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        imageEncoder = try MLModel(contentsOf: imageURL, configuration: config)
        decoder = try MLModel(contentsOf: decoderURL, configuration: config)
    }

    /// Segment every instance of `concept` in `image`.
    /// Returns empty array when the model is not yet available.
    func segment(concept: String, in image: UIImage) async throws -> [ConceptSegment] {
        guard isAvailable else { return [] }
        try await ensureLoaded()

        guard let imageEncoder, let decoder, let cgImage = image.cgImage else { return [] }

        // 1. Encode image (1024x1024 typical for EfficientSAM3 student)
        let imageEmbedding = try await runImageEncoder(model: imageEncoder, cgImage: cgImage)

        // 2. Encode text prompt via MobileCLIP (matches EfficientSAM3 student text encoder)
        let textEmbedding = try await mobileCLIP.generateTextEmbedding(for: concept)

        // 3. Run decoder: image_embed + text_embed → masks + scores
        return try await runDecoder(
            model: decoder,
            imageEmbedding: imageEmbedding,
            textEmbedding: textEmbedding,
            label: concept,
            sourceWidth: cgImage.width,
            sourceHeight: cgImage.height
        )
    }

    // MARK: - Private inference glue (shapes finalized when EfficientSAM3 ships its CoreML I/O spec)

    private func runImageEncoder(model: MLModel, cgImage: CGImage) async throws -> MLMultiArray {
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        guard let pixelBuffer = pixelBuffer(from: cgImage, size: 1024) else {
            throw SAM3Error.preprocessingFailed
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: pixelBuffer])
        let output = try await model.prediction(from: input)
        for name in output.featureNames {
            if let array = output.featureValue(for: name)?.multiArrayValue {
                return array
            }
        }
        throw SAM3Error.unexpectedOutput
    }

    private func runDecoder(
        model: MLModel,
        imageEmbedding: MLMultiArray,
        textEmbedding: [Float],
        label: String,
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws -> [ConceptSegment] {
        // Pack text embedding as MLMultiArray. Final input naming follows whatever
        // EfficientSAM3 emits — we discover it from the model description rather
        // than hardcoding.
        let textArray = try MLMultiArray(shape: [1, NSNumber(value: textEmbedding.count)], dataType: .float32)
        for (i, v) in textEmbedding.enumerated() {
            textArray[i] = NSNumber(value: v)
        }

        let inputs = model.modelDescription.inputDescriptionsByName.keys.sorted()
        guard inputs.count >= 2 else { throw SAM3Error.unexpectedInputs }
        var feed: [String: MLFeatureValue] = [:]
        feed[inputs[0]] = MLFeatureValue(multiArray: imageEmbedding)
        feed[inputs[1]] = MLFeatureValue(multiArray: textArray)

        let provider = try MLDictionaryFeatureProvider(dictionary: feed)
        let output = try await model.prediction(from: provider)

        return decodeMasks(
            output: output,
            label: label,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }

    private func decodeMasks(
        output: MLFeatureProvider,
        label: String,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> [ConceptSegment] {
        // Expected outputs (EfficientSAM3 convention):
        //   masks: [N, H, W] binary/float
        //   scores: [N]
        //   bboxes: [N, 4] (cx, cy, w, h) normalized
        guard let scoresArray = output.featureValue(for: "scores")?.multiArrayValue,
              let bboxesArray = output.featureValue(for: "bboxes")?.multiArrayValue else {
            return []
        }
        let masksArray = output.featureValue(for: "masks")?.multiArrayValue

        let count = scoresArray.count
        var segments: [ConceptSegment] = []
        for n in 0..<count {
            let score = scoresArray[n].floatValue
            guard score > 0.3 else { continue }

            let cx = bboxesArray[[n, 0] as [NSNumber]].doubleValue
            let cy = bboxesArray[[n, 1] as [NSNumber]].doubleValue
            let w = bboxesArray[[n, 2] as [NSNumber]].doubleValue
            let h = bboxesArray[[n, 3] as [NSNumber]].doubleValue

            let bbox = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            let center = CGPoint(x: cx, y: cy)

            var maskBytes: [UInt8]? = nil
            var maskW = 0
            var maskH = 0
            if let masksArray, masksArray.shape.count == 3 {
                let h = masksArray.shape[1].intValue
                let w = masksArray.shape[2].intValue
                let plane = h * w
                maskW = w
                maskH = h
                var bytes = [UInt8](repeating: 0, count: plane)
                for i in 0..<plane {
                    let v = masksArray[[n, i / w, i % w] as [NSNumber]].floatValue
                    bytes[i] = v > 0.5 ? 1 : 0
                }
                maskBytes = bytes
            }

            segments.append(ConceptSegment(
                label: label,
                score: score,
                bbox: bbox,
                centerPoint: center,
                mask: maskBytes,
                maskWidth: maskW,
                maskHeight: maskH
            ))
        }
        return segments
    }

    // MARK: - Pixel buffer helper

    private func pixelBuffer(from cgImage: CGImage, size: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &buffer)
        guard let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pb
    }
}

enum SAM3Error: Error, LocalizedError {
    case modelsNotBundled
    case preprocessingFailed
    case unexpectedOutput
    case unexpectedInputs

    var errorDescription: String? {
        switch self {
        case .modelsNotBundled: return "EfficientSAM3 CoreML models not bundled. Run scripts/convert_models.sh sam3 once available."
        case .preprocessingFailed: return "Failed to preprocess image for SAM3"
        case .unexpectedOutput: return "SAM3 image encoder returned unexpected output"
        case .unexpectedInputs: return "SAM3 decoder input layout did not match expectations"
        }
    }
}
