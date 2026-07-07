//
//  MobileCLIPService.swift
//  Vision Builder
//
//  On-device MobileCLIP-S0 inference for text-image embeddings via CoreML.
//  Enables text-prompted object discovery and semantic similarity.
//

import CoreML
import Foundation
import UIKit

class MobileCLIPService {

    // MARK: - Configuration

    /// Embedding dimension for MobileCLIP-S0
    static let embeddingDimension = 512

    /// Image input size for MobileCLIP-S0
    static let imageInputSize = 256

    /// ImageNet normalization constants
    private static let imageMean: [Float] = [0.4815, 0.4578, 0.4082]
    private static let imageStd: [Float] = [0.2686, 0.2613, 0.2758]

    // MARK: - Model Names

    /// Preferred order: MobileCLIP 2 if bundled, else fall back to MobileCLIP S0.
    /// MobileCLIP 2 (Apple, 2025) is a same-architecture, retrained-on-better-data drop-in.
    private enum ModelNames {
        static let v2ImageEncoder = "mobileclip2_s0_image"
        static let v2TextEncoder = "mobileclip2_s0_text"
        static let v1ImageEncoder = "mobileclip_s0_image"
        static let v1TextEncoder = "mobileclip_s0_text"
    }

    /// Reflects which generation actually loaded; useful for telemetry.
    enum Generation { case v1, v2 }

    // MARK: - State

    private var imageEncoderModel: MLModel?
    private var textEncoderModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var isLoaded = false
    private(set) var loadedGeneration: Generation = .v1

    // MARK: - Initialization

    init() {}

    /// Load models lazily on first use. Prefers MobileCLIP 2 if its mlpackage is bundled.
    func ensureModelsLoaded() async throws {
        guard !isLoaded else { return }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let (imageName, textName, generation) = resolvePreferredModelNames()
        print("Loading MobileCLIP \(generation == .v2 ? "2" : "S0") CoreML models...")

        guard let imageURL = Bundle.main.url(forResource: imageName, withExtension: "mlmodelc") else {
            throw MobileCLIPError.modelNotFound(imageName)
        }
        imageEncoderModel = try MLModel(contentsOf: imageURL, configuration: config)

        guard let textURL = Bundle.main.url(forResource: textName, withExtension: "mlmodelc") else {
            throw MobileCLIPError.modelNotFound(textName)
        }
        textEncoderModel = try MLModel(contentsOf: textURL, configuration: config)
        loadedGeneration = generation

        // Load tokenizer
        guard let vocabURL = Bundle.main.url(forResource: "clip_vocab", withExtension: "json"),
              let mergesURL = Bundle.main.url(forResource: "clip_merges", withExtension: "txt") else {
            throw MobileCLIPError.tokenizerResourcesNotFound
        }
        tokenizer = try CLIPTokenizer(mergesURL: mergesURL, vocabularyURL: vocabURL)

        isLoaded = true
        print("MobileCLIP-S0 loaded successfully")
        printModelInfo()
    }

    var modelsAreLoaded: Bool { isLoaded }

    /// Picks v2 if bundled (both image + text), otherwise falls back to v1.
    private func resolvePreferredModelNames() -> (image: String, text: String, gen: Generation) {
        let v2Image = Bundle.main.url(forResource: ModelNames.v2ImageEncoder, withExtension: "mlmodelc")
        let v2Text = Bundle.main.url(forResource: ModelNames.v2TextEncoder, withExtension: "mlmodelc")
        if v2Image != nil && v2Text != nil {
            return (ModelNames.v2ImageEncoder, ModelNames.v2TextEncoder, .v2)
        }
        return (ModelNames.v1ImageEncoder, ModelNames.v1TextEncoder, .v1)
    }

    // MARK: - Image Embedding

    /// Generate a 512-dim L2-normalized embedding for an image.
    func generateImageEmbedding(for image: UIImage) async throws -> [Float] {
        try await ensureModelsLoaded()
        guard let model = imageEncoderModel else {
            throw MobileCLIPError.modelNotLoaded
        }

        // Preprocess: resize to 256x256 and create pixel buffer
        guard let pixelBuffer = preprocessImage(image) else {
            throw MobileCLIPError.imagePreprocessingFailed
        }

        // Run inference - try common input names
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input_image"
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: pixelBuffer])
        let result = try await model.prediction(from: input)

        // Extract embedding from output
        let embedding = try extractEmbedding(from: result)
        return normalizeL2(embedding)
    }

    // MARK: - Text Embedding

    /// Generate a 512-dim L2-normalized embedding for a text query.
    func generateTextEmbedding(for text: String) async throws -> [Float] {
        try await ensureModelsLoaded()
        guard let model = textEncoderModel, let tokenizer = tokenizer else {
            throw MobileCLIPError.modelNotLoaded
        }

        // Tokenize
        let tokenIDs = tokenizer.tokenize(text)

        // Create input tensor
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input_text"
        let inputShape = model.modelDescription.inputDescriptionsByName[inputName]?
            .multiArrayConstraint?.shape.map { $0.intValue } ?? [1, 77]

        let inputArray = try MLMultiArray(shape: inputShape.map { NSNumber(value: $0) }, dataType: .int32)
        for (i, tokenID) in tokenIDs.enumerated() {
            if inputShape.count == 2 {
                inputArray[[0, i] as [NSNumber]] = NSNumber(value: tokenID)
            } else {
                inputArray[i] = NSNumber(value: tokenID)
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: inputArray])
        let result = try await model.prediction(from: input)

        let embedding = try extractEmbedding(from: result)
        return normalizeL2(embedding)
    }

    // MARK: - Similarity

    /// Cosine similarity between two L2-normalized embeddings.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return max(-1, min(1, dot))
    }

    /// Rank a set of image embeddings by similarity to a text query.
    func rankBySimilarity(
        query: String,
        imageEmbeddings: [[Float]]
    ) async throws -> [(index: Int, similarity: Float)] {
        let textEmbedding = try await generateTextEmbedding(for: query)

        var results = imageEmbeddings.enumerated().map { (index, embedding) in
            (index: index, similarity: Self.cosineSimilarity(textEmbedding, embedding))
        }
        results.sort { $0.similarity > $1.similarity }
        return results
    }

    // MARK: - Image Preprocessing

    private func preprocessImage(_ image: UIImage) -> CVPixelBuffer? {
        let size = CGSize(width: Self.imageInputSize, height: Self.imageInputSize)

        // Create pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.imageInputSize,
            Self.imageInputSize,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Self.imageInputSize,
            height: Self.imageInputSize,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Aspect-fill + center crop (CLIP's training geometry) — squashing to
        // 256x256 measurably degrades embeddings (0.51 vs 1.0 cosine to reference)
        guard let cgImage = image.cgImage else { return nil }
        let iw = CGFloat(cgImage.width), ih = CGFloat(cgImage.height)
        let fillScale = max(size.width / iw, size.height / ih)
        let drawRect = CGRect(
            x: (size.width - iw * fillScale) / 2,
            y: (size.height - ih * fillScale) / 2,
            width: iw * fillScale,
            height: ih * fillScale
        )
        context.draw(cgImage, in: drawRect)

        return buffer
    }

    // MARK: - Output Extraction

    private func extractEmbedding(from result: MLFeatureProvider) throws -> [Float] {
        // Try known output names (official Apple models use "final_emb_1")
        let outputNames = ["final_emb_1", "output_embeddings", "embOutput", "text_embeddings"]
        var multiArray: MLMultiArray?

        for name in outputNames {
            if let feature = result.featureValue(for: name), let array = feature.multiArrayValue {
                multiArray = array
                break
            }
        }

        // Fallback: use first available multiarray output
        if multiArray == nil {
            for name in result.featureNames {
                if let feature = result.featureValue(for: name), let array = feature.multiArrayValue {
                    multiArray = array
                    break
                }
            }
        }

        guard let array = multiArray else {
            throw MobileCLIPError.embeddingExtractionFailed
        }

        // Convert to [Float] based on data type
        let count = array.count
        var embedding = [Float](repeating: 0, count: count)

        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { embedding[i] = ptr[i] }
        case .float16:
            let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            for i in 0..<count { embedding[i] = Float(ptr[i]) }
        default:
            // Try float32 as best guess
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { embedding[i] = ptr[i] }
        }

        // If shape is [1, 512], we want the 512 values
        if embedding.count == Self.embeddingDimension {
            return embedding
        }

        // Handle potential batch dimension
        if embedding.count > Self.embeddingDimension {
            return Array(embedding.prefix(Self.embeddingDimension))
        }

        return embedding
    }

    // MARK: - Vector Math

    private func normalizeL2(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    // MARK: - Debug

    private func printModelInfo() {
        if let model = imageEncoderModel {
            let inputs = model.modelDescription.inputDescriptionsByName
            let outputs = model.modelDescription.outputDescriptionsByName
            print("  Image Encoder inputs: \(inputs.keys.sorted())")
            print("  Image Encoder outputs: \(outputs.keys.sorted())")
        }
        if let model = textEncoderModel {
            let inputs = model.modelDescription.inputDescriptionsByName
            let outputs = model.modelDescription.outputDescriptionsByName
            print("  Text Encoder inputs: \(inputs.keys.sorted())")
            print("  Text Encoder outputs: \(outputs.keys.sorted())")
        }
    }
}

// MARK: - Errors

enum MobileCLIPError: Error, LocalizedError {
    case modelNotFound(String)
    case modelNotLoaded
    case tokenizerResourcesNotFound
    case imagePreprocessingFailed
    case embeddingExtractionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "MobileCLIP model '\(name)' not found in bundle"
        case .modelNotLoaded:
            return "MobileCLIP models not loaded"
        case .tokenizerResourcesNotFound:
            return "CLIP tokenizer vocabulary/merges files not found in bundle"
        case .imagePreprocessingFailed:
            return "Failed to preprocess image for MobileCLIP"
        case .embeddingExtractionFailed:
            return "Failed to extract embedding from model output"
        }
    }
}
