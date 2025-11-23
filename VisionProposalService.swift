import CoreImage
import Foundation
import UIKit
@preconcurrency import Vision

/// Real computer vision-based object proposal service
/// Replaces heuristic sampling with actual image analysis using Vision framework
class VisionProposalService {
    
    // MARK: - Configuration
    
    struct ProposalConfig: Sendable {
        let maxProposals: Int
        let minConfidence: Float
        let minRegionSize: CGFloat
        let edgeMargin: CGFloat
        
        static let `default` = ProposalConfig(
            maxProposals: 8,
            minConfidence: 0.3,
            minRegionSize: 0.05, // 5% of image
            edgeMargin: 0.08 // 8% margin from edges
        )
    }
    
    // MARK: - Public API
    
    /// Generate object proposals for an image using Vision framework
    /// Returns array of candidate points where objects are likely to be found
    func generateProposals(for image: UIImage, config: ProposalConfig? = nil) async throws -> [CGPoint] {
        let config = config ?? ProposalConfig.default
        
        guard let cgImage = image.cgImage else {
            throw VisionError.invalidImage
        }
        
        // Step 1: Get objectness saliency map (where objects are likely)
        let saliencyResults = try await performSaliencyAnalysis(cgImage: cgImage)
        
        // Step 2: Extract high-confidence regions from saliency map
        let salientRegions = extractSalientRegions(
            from: saliencyResults,
            imageSize: image.size,
            config: config
        )
        
        // Step 3: Filter and rank proposals
        let filteredProposals = filterProposals(
            salientRegions,
            imageSize: image.size,
            config: config
        )
        
        // Step 4: Add central fallback if no good proposals found
        let finalProposals = ensureMinimumProposals(
            filteredProposals,
            imageSize: image.size,
            config: config
        )
        
        print("Vision generated \(finalProposals.count) object proposals")
        return finalProposals
    }
    
    // MARK: - Vision Framework Analysis
    
    private func performSaliencyAnalysis(cgImage: CGImage) async throws -> VNSaliencyImageObservation {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNGenerateObjectnessBasedSaliencyImageRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observation = request.results?.first as? VNSaliencyImageObservation else {
                    continuation.resume(throwing: VisionError.noSaliencyResults)
                    return
                }
                
                continuation.resume(returning: observation)
            }
            
            request.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            // Perform on background queue
            Task.detached {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Saliency Processing
    
    private func extractSalientRegions(
        from observation: VNSaliencyImageObservation,
        imageSize: CGSize,
        config: ProposalConfig
    ) -> [SalientRegion] {
        guard let salientObjects = observation.salientObjects else {
            print("No salient objects found, using pixel buffer analysis")
            return extractRegionsFromPixelBuffer(observation, imageSize: imageSize, config: config)
        }
        
        var regions: [SalientRegion] = []
        
        for object in salientObjects {
            // Vision uses normalized coordinates (0-1) with origin at bottom-left
            let visionRect = object.boundingBox
            
            // Convert to our coordinate system (origin at top-left)
            let convertedRect = CGRect(
                x: visionRect.origin.x,
                y: 1.0 - visionRect.origin.y - visionRect.height,
                width: visionRect.width,
                height: visionRect.height
            )
            
            // Calculate center point
            let center = CGPoint(
                x: convertedRect.midX * imageSize.width,
                y: convertedRect.midY * imageSize.height
            )
            
            let region = SalientRegion(
                center: center,
                boundingBox: convertedRect,
                confidence: object.confidence,
                area: convertedRect.width * convertedRect.height
            )
            
            regions.append(region)
        }
        
        print("Extracted \(regions.count) salient regions from Vision")
        return regions
    }
    
    private func extractRegionsFromPixelBuffer(
        _ observation: VNSaliencyImageObservation,
        imageSize: CGSize,
        config: ProposalConfig
    ) -> [SalientRegion] {
        // Fallback: Sample high-saliency pixels from the pixel buffer
        let pixelBuffer = observation.pixelBuffer
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return []
        }
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        // Sample grid of points and collect high-saliency locations
        var highSaliencyPoints: [(point: CGPoint, value: Float)] = []
        let gridSize = 16
        
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let x = (width * col) / gridSize
                let y = (height * row) / gridSize
                
                if x < width && y < height {
                    let pixelOffset = y * bytesPerRow + x
                    let saliencyValue = Float(buffer[pixelOffset]) / 255.0
                    
                    if saliencyValue > config.minConfidence {
                        let normalizedPoint = CGPoint(
                            x: CGFloat(x) / CGFloat(width),
                            y: CGFloat(y) / CGFloat(height)
                        )
                        
                        let imagePoint = CGPoint(
                            x: normalizedPoint.x * imageSize.width,
                            y: normalizedPoint.y * imageSize.height
                        )
                        
                        highSaliencyPoints.append((imagePoint, saliencyValue))
                    }
                }
            }
        }
        
        // Sort by saliency value and take top candidates
        let topPoints = highSaliencyPoints
            .sorted { $0.value > $1.value }
            .prefix(config.maxProposals)
        
        return topPoints.map { point, confidence in
            SalientRegion(
                center: point,
                boundingBox: CGRect(
                    x: (point.x / imageSize.width) - 0.1,
                    y: (point.y / imageSize.height) - 0.1,
                    width: 0.2,
                    height: 0.2
                ),
                confidence: confidence,
                area: 0.04 // 20% x 20% = 4%
            )
        }
    }
    
    // MARK: - Filtering and Ranking
    
    private func filterProposals(
        _ regions: [SalientRegion],
        imageSize: CGSize,
        config: ProposalConfig
    ) -> [CGPoint] {
        return regions
            // Filter by confidence
            .filter { $0.confidence >= config.minConfidence }
            // Filter by size (not too small)
            .filter { $0.area >= config.minRegionSize }
            // Filter edge cases (avoid edges)
            .filter { region in
                let normalizedX = region.center.x / imageSize.width
                let normalizedY = region.center.y / imageSize.height
                
                return normalizedX > config.edgeMargin &&
                       normalizedX < (1.0 - config.edgeMargin) &&
                       normalizedY > config.edgeMargin &&
                       normalizedY < (1.0 - config.edgeMargin)
            }
            // Sort by confidence (best first)
            .sorted { $0.confidence > $1.confidence }
            // Remove overlapping proposals
            .reduce([]) { result, region in
                let hasOverlap = result.contains { existingCenter in
                    let distance = hypot(
                        existingCenter.x - region.center.x,
                        existingCenter.y - region.center.y
                    )
                    let minDistance = min(imageSize.width, imageSize.height) * 0.15
                    return distance < minDistance
                }
                
                return hasOverlap ? result : result + [region.center]
            }
            // Limit to max proposals
            .prefix(config.maxProposals)
            .map { $0 }
    }
    
    private func ensureMinimumProposals(
        _ proposals: [CGPoint],
        imageSize: CGSize,
        config: ProposalConfig
    ) -> [CGPoint] {
        guard proposals.isEmpty else { return proposals }
        
        // If no proposals found, provide smart fallbacks
        let fallbacks = [
            CGPoint(x: imageSize.width * 0.5, y: imageSize.height * 0.4),  // Center-top
            CGPoint(x: imageSize.width * 0.35, y: imageSize.height * 0.5), // Left-center
            CGPoint(x: imageSize.width * 0.65, y: imageSize.height * 0.5), // Right-center
        ]
        
        print("No Vision proposals, using fallback points")
        return fallbacks
    }
}

// MARK: - Supporting Types

private struct SalientRegion {
    let center: CGPoint
    let boundingBox: CGRect
    let confidence: Float
    let area: CGFloat
}

enum VisionError: Error {
    case invalidImage
    case noSaliencyResults
    case processingFailed
}
