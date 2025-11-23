import CoreML
import Foundation
import UIKit
import Vision

/// Generates feature embeddings (fingerprints) for detected objects
/// These embeddings enable object recognition and identity matching
class EmbeddingService {
    
    // MARK: - Configuration
    
    struct EmbeddingConfig {
        let imageSize: CGSize
        let useSceneClassification: Bool
        
        static let `default` = EmbeddingConfig(
            imageSize: CGSize(width: 299, height: 299), // Standard for Vision feature prints
            useSceneClassification: false // Additional context if needed
        )
    }
    
    // MARK: - Public API
    
    /// Generate embedding for a detected object
    /// Returns a normalized feature vector that uniquely identifies this object's visual appearance
    func generateEmbedding(
        for objectCrop: UIImage,
        config: EmbeddingConfig? = nil
    ) async throws -> ObjectEmbedding {
        let config = config ?? EmbeddingConfig.default
        
        // Validate input
        guard let cgImage = objectCrop.cgImage else {
            throw EmbeddingError.invalidImage
        }
        
        // Generate feature print using Vision framework
        let featurePrint = try await generateFeaturePrint(cgImage: cgImage)
        
        // Optional: Add scene classification for additional context
        var sceneConfidence: [String: Float] = [:]
        if config.useSceneClassification {
            sceneConfidence = try await classifyScene(cgImage: cgImage)
        }
        
        return ObjectEmbedding(
            vector: featurePrint,
            dimension: featurePrint.count,
            sceneContext: sceneConfidence,
            generatedAt: Date()
        )
    }
    
    /// Generate embedding from object crop in full image
    /// Extracts the region, then generates embedding
    func generateEmbedding(
        from image: UIImage,
        boundingBox: CGRect
    ) async throws -> ObjectEmbedding {
        // Extract object crop from full image
        guard let objectCrop = extractObjectCrop(from: image, boundingBox: boundingBox) else {
            throw EmbeddingError.cropExtractionFailed
        }
        
        return try await generateEmbedding(for: objectCrop)
    }
    
    /// Batch generate embeddings for multiple objects
    func generateEmbeddings(
        for objects: [(image: UIImage, box: CGRect)]
    ) async throws -> [ObjectEmbedding] {
        var embeddings: [ObjectEmbedding] = []
        
        for (image, box) in objects {
            do {
                let embedding = try await generateEmbedding(from: image, boundingBox: box)
                embeddings.append(embedding)
            } catch {
                print("Failed to generate embedding for object: \(error)")
                // Continue processing other objects
            }
        }
        
        return embeddings
    }
    
    // MARK: - Feature Print Generation
    
    private func generateFeaturePrint(cgImage: CGImage) async throws -> [Float] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNGenerateImageFeaturePrintRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                    continuation.resume(throwing: EmbeddingError.featurePrintFailed)
                    return
                }
                
                // Extract feature print data
                do {
                    let featureVector = try self.extractFeatureVector(from: observation)
                    continuation.resume(returning: featureVector)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            // Use latest revision for best quality
            request.revision = VNGenerateImageFeaturePrintRequestRevision1
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            Task.detached {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func extractFeatureVector(from observation: VNFeaturePrintObservation) throws -> [Float] {
        // VNFeaturePrintObservation provides a compact feature representation
        let data = observation.data
        let elementCount = observation.elementCount
        let elementType = observation.elementType
        
        // Convert to Float array
        var featureVector: [Float] = []
        
        switch elementType {
        case .float:
            // Data is already in Float format
            featureVector = data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        case .double:
            // Convert from Double to Float
            let doubles = data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Double.self))
            }
            featureVector = doubles.map { Float($0) }
        default:
            throw EmbeddingError.unsupportedFeatureType
        }
        
        // Verify we got the expected number of elements
        guard featureVector.count == elementCount else {
            throw EmbeddingError.featureVectorSizeMismatch
        }
        
        // Normalize the vector (L2 normalization for cosine similarity)
        let normalizedVector = normalizeVector(featureVector)
        
        return normalizedVector
    }
    // MARK: - Scene Classification (Optional Context)
    
    private func classifyScene(cgImage: CGImage) async throws -> [String: Float] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [:])
                    return
                }
                
                // Get top 3 scene classifications
                let topScenes = observations
                    .prefix(3)
                    .reduce(into: [String: Float]()) { result, obs in
                        result[obs.identifier] = obs.confidence
                    }
                
                continuation.resume(returning: topScenes)
            }
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            Task.detached {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Image Processing
    
    private func extractObjectCrop(from image: UIImage, boundingBox: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        
        // Convert normalized coordinates to pixel coordinates
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        
        let pixelRect = CGRect(
            x: boundingBox.origin.x * imageWidth,
            y: boundingBox.origin.y * imageHeight,
            width: boundingBox.size.width * imageWidth,
            height: boundingBox.size.height * imageHeight
        )
        
        // Add small padding (10%)
        let padding: CGFloat = 0.1
        let paddedRect = pixelRect.insetBy(
            dx: -pixelRect.width * padding,
            dy: -pixelRect.height * padding
        )
        
        // Clamp to image bounds
        let clampedRect = CGRect(
            x: max(0, paddedRect.origin.x),
            y: max(0, paddedRect.origin.y),
            width: min(imageWidth - paddedRect.origin.x, paddedRect.width),
            height: min(imageHeight - paddedRect.origin.y, paddedRect.height)
        )
        
        // Crop the image
        guard let croppedCGImage = cgImage.cropping(to: clampedRect) else {
            return nil
        }
        
        return UIImage(cgImage: croppedCGImage)
    }
    
    // MARK: - Vector Math
    
    private func normalizeVector(_ vector: [Float]) -> [Float] {
        // L2 normalization for cosine similarity
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        
        guard magnitude > 0 else {
            return vector // Avoid division by zero
        }
        
        return vector.map { $0 / magnitude }
    }
    
    /// Calculate cosine similarity between two embeddings (0 to 1, higher = more similar)
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        let dotProduct = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        
        // Vectors are already normalized, so dot product IS the cosine similarity
        return max(0, min(1, dotProduct)) // Clamp to [0, 1]
    }
    
    /// Calculate Euclidean distance between two embeddings (lower = more similar)
    static func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return Float.infinity }
        
        let squaredDiffs = zip(a, b).map { pow($0 - $1, 2) }
        return sqrt(squaredDiffs.reduce(0, +))
    }
}

// MARK: - Data Types

/// Represents a feature embedding for an object
struct ObjectEmbedding: Codable {
    let vector: [Float]
    let dimension: Int
    let sceneContext: [String: Float] // Optional scene classification context
    let generatedAt: Date
    
    /// Generate a unique identifier based on the embedding
    var fingerprint: String {
        // Create a hash from the first 10 values for quick comparison
        let sample = vector.prefix(10).map { String(format: "%.3f", $0) }.joined()
        return sample.md5Hash
    }
}

// MARK: - Errors

enum EmbeddingError: Error, LocalizedError {
    case invalidImage
    case cropExtractionFailed
    case featurePrintFailed
    case unsupportedFeatureType
    case featureVectorSizeMismatch
    
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid image provided for embedding generation"
        case .cropExtractionFailed:
            return "Failed to extract object crop from image"
        case .featurePrintFailed:
            return "Vision framework failed to generate feature print"
        case .unsupportedFeatureType:
            return "Unsupported feature vector type"
        case .featureVectorSizeMismatch:
            return "Feature vector size mismatch"
        }
    }
}

// MARK: - Helpers

extension String {
    var md5Hash: String {
        // Simple hash for fingerprinting
        // In production, use CryptoKit
        return String(self.hashValue)
    }
}

