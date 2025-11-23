import CoreImage
import CoreML
import Foundation
import UIKit
@preconcurrency import Vision

// MARK: - SAM2CoreMLProcessor - SAM 2.1 Small ML Processing Module

/// Model name constants for SAM 2.1 Small
private enum SAM2ModelNames {
    static let imageEncoder = "SAM2_1SmallImageEncoderFLOAT16"
    static let promptEncoder = "SAM2_1SmallPromptEncoderFLOAT16"
    static let maskDecoder = "SAM2_1SmallMaskDecoderFLOAT16"
    static let displayName = "SAM 2.1 Small"
}

class SAM2CoreMLProcessor {
    weak var manager: SAM2DetectionManager?
    private let analyzer = SAM2ImageAnalysis()
    private let visionProposals = VisionProposalService()

    // Real SAM2 CoreML Models
    private var imageEncoderModel: MLModel?
    private var promptEncoderModel: MLModel?
    private var maskDecoderModel: MLModel?
    private var isModelsLoaded = false

    // Add this method to load models only when first needed
    private func ensureModelsLoaded() async {
        guard !isModelsLoaded else { return }
        await setupSAM2Models()
    }

    init() {}

    // MARK: - Model Loading

    private func setupSAM2Models() async {
        print("Loading SAM2 CoreML models (\(SAM2ModelNames.displayName))...")

        // Debug: Print actual bundle contents
        if let bundlePath = Bundle.main.resourcePath {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: bundlePath)
            let mlFiles = contents?.filter { $0.contains("SAM2") } ?? []
            print("SAM2 files in bundle: \(mlFiles)")
        }

        do {
            // Load the three SAM2 models
            if let imageEncoderURL = Bundle.main.url(forResource: SAM2ModelNames.imageEncoder, withExtension: "mlmodelc"),
               let promptEncoderURL = Bundle.main.url(forResource: SAM2ModelNames.promptEncoder, withExtension: "mlmodelc"),
               let maskDecoderURL = Bundle.main.url(forResource: SAM2ModelNames.maskDecoder, withExtension: "mlmodelc")
            {
                await MainActor.run {
                    self.manager?.updateOperation("Loading \(SAM2ModelNames.displayName) Image Encoder...")
                }
                imageEncoderModel = try MLModel(contentsOf: imageEncoderURL)

                await MainActor.run {
                    self.manager?.updateOperation("Loading \(SAM2ModelNames.displayName) Prompt Encoder...")
                }
                promptEncoderModel = try MLModel(contentsOf: promptEncoderURL)

                await MainActor.run {
                    self.manager?.updateOperation("Loading \(SAM2ModelNames.displayName) Mask Decoder...")
                }
                maskDecoderModel = try MLModel(contentsOf: maskDecoderURL)

                await MainActor.run {
                    self.isModelsLoaded = true
                    self.manager?.updateOperation("")
                    print("✅ SAM2 CoreML Models loaded successfully!")
                    print("   Model: \(SAM2ModelNames.displayName)")
                    print("   Image Encoder: \(imageEncoderURL.lastPathComponent)")
                    print("   Prompt Encoder: \(promptEncoderURL.lastPathComponent)")
                    print("   Mask Decoder: \(maskDecoderURL.lastPathComponent)")
                }

            } else {
                print("⚠️ SAM2 Small models not found in bundle")
                await MainActor.run {
                    self.manager?.updateOperation("SAM2 models not found")
                }
            }

        } catch {
            print("Error loading SAM2 models: \(error)")
            await MainActor.run {
                self.manager?.updateOperation("SAM2 load failed - using fallback")
            }
        }
    }

    // MARK: - Main Processing Methods

    func performSAM2TapDetection(at point: CGPoint, in image: UIImage, imageViewBounds: CGRect) async {
        await ensureModelsLoaded()

        guard isModelsLoaded,
              let imageEncoderModel = imageEncoderModel,
              let promptEncoderModel = promptEncoderModel,
              let maskDecoderModel = maskDecoderModel
        else {
            print("SAM2 models not available for tap detection")
            await fallbackToVisionTapDetection(at: point, in: image)
            return
        }

        await MainActor.run {
            self.manager?.updateOperation("Real SAM2 encoding image...")
            self.manager?.updateProgress(0.3)
        }

        do {
            // Step 1: Prepare image for SAM2 (1024x1024 expected)
            guard let resizedImage = prepareImageForSAM2(image) else {
                throw SAM2Error.imagePreparationFailed
            }

            await MainActor.run {
                self.manager?.updateOperation("SAM2 generating embeddings...")
                self.manager?.updateProgress(0.5)
            }

            // Step 2: Run Image Encoder
            let imageFeatures = try await runImageEncoder(resizedImage, using: imageEncoderModel)

            await MainActor.run {
                self.manager?.updateOperation("SAM2 processing prompt...")
                self.manager?.updateProgress(0.7)
            }

            // Step 3: Create prompt from tap point
            let imagePoint = convertTapPointToImageCoordinates(
                tapPoint: point,
                imageViewBounds: imageViewBounds,
                imageSize: image.size
            )

            let normalizedImage = normalizeImageOrientation(image)
            let normalizedPoint = CGPoint(
                x: imagePoint.x * (normalizedImage.size.width / image.size.width),
                y: imagePoint.y * (normalizedImage.size.height / image.size.height)
            )

            let sam2Point = normalizePointForSAM2(normalizedPoint, imageSize: normalizedImage.size)
            let promptFeatures = try await runPromptEncoder(sam2Point, using: promptEncoderModel)

            await MainActor.run {
                self.manager?.updateOperation("SAM2 generating mask...")
                self.manager?.updateProgress(0.9)
            }

            // Step 4: Run Mask Decoder
            let mask = try await runMaskDecoder(imageFeatures: imageFeatures, promptFeatures: promptFeatures, using: maskDecoderModel)

            // Step 5: Convert mask to precise contour points and bounding box
            let (boundingBox, contourPoints) = extractPreciseSegmentation(from: mask)

            let tapBox = LabeledBox.sam2Box(
                id: UUID(),
                label: "SAM2 Object",
                boundingRect: boundingBox,
                contourPoints: contourPoints,
                detectionMethod: "SAM2 CoreML Tap Detection",
                isSaved: false
            )

            await MainActor.run {
                self.manager?.addDetectedBox(tapBox)
                print("Real SAM2 CoreML tap detection complete!")
                self.manager?.finishProcessing()
            }

        } catch {
            print("SAM2 tap detection error: \(error)")
            await fallbackToVisionTapDetection(at: point, in: image)
        }
    }

    // MARK: - REAL Auto-Detection Implementation (Vision + SAM2)

    func performAutoEverythingDetection(in image: UIImage) async {
        await ensureModelsLoaded()

        guard isModelsLoaded,
              let imageEncoderModel = imageEncoderModel,
              let promptEncoderModel = promptEncoderModel,
              let maskDecoderModel = maskDecoderModel
        else {
            await fallbackToSimpleDetection(image: image)
            return
        }

        await MainActor.run {
            self.manager?.updateOperation("Using Vision to find objects...")
            self.manager?.updateProgress(0.1)
        }

        // Step 1: Use REAL Vision framework to find object proposals
        let candidatePoints: [CGPoint]
        do {
            candidatePoints = try await visionProposals.generateProposals(for: image)
            print("✅ Vision found \(candidatePoints.count) real object proposals")
        } catch {
            print("⚠️ Vision proposal failed: \(error), using fallback")
            await fallbackToSimpleDetection(image: image)
            return
        }

        guard !candidatePoints.isEmpty else {
            print("⚠️ No object proposals found")
            await MainActor.run {
                self.manager?.updateOperation("No objects detected")
                self.manager?.finishProcessing()
            }
            return
        }

        await MainActor.run {
            self.manager?.updateOperation("SAM2 segmenting \(candidatePoints.count) objects...")
            self.manager?.updateProgress(0.3)
        }

        // Step 2: Pre-encode image once for all detections
        guard let resizedImage = prepareImageForSAM2(image) else {
            await MainActor.run {
                self.manager?.finishProcessing()
            }
            return
        }

        let imageFeatures: [String: MLFeatureValue]
        do {
            imageFeatures = try await runImageEncoder(resizedImage, using: imageEncoderModel)
        } catch {
            print("SAM2 image encoding failed: \(error)")
            await MainActor.run {
                self.manager?.finishProcessing()
            }
            return
        }

        var detectedBoxes: [LabeledBox] = []

        // Step 3: Test each Vision-proposed point with SAM2
        for (index, point) in candidatePoints.enumerated() {
            await MainActor.run {
                self.manager?.updateOperation("SAM2 segmenting object \(index + 1)/\(candidatePoints.count)...")
                self.manager?.updateProgress(0.3 + (0.6 * Double(index) / Double(candidatePoints.count)))
            }

            if let box = await testPointWithSAM2(
                point: point,
                in: image,
                imageFeatures: imageFeatures,
                promptEncoder: promptEncoderModel,
                maskDecoder: maskDecoderModel
            ) {
                // Check if this is a valid detection (not background noise)
                if isValidObjectDetection(box, imageSize: image.size) {
                    // Check for overlap with existing detections
                    if !hasSignificantOverlap(box.rect, with: detectedBoxes.map { $0.rect }) {
                        detectedBoxes.append(box)
                        print("✅ Added object \(detectedBoxes.count): \(box.rect)")
                    } else {
                        print("⚠️ Skipped overlapping detection")
                    }
                }
            }

            // Limit to reasonable number
            if detectedBoxes.count >= 5 {
                print("✅ Reached 5 objects, stopping")
                break
            }
        }

        await MainActor.run {
            if detectedBoxes.isEmpty {
                self.manager?.updateOperation("No valid objects found")
                print("❌ SAM2 auto-detection found no valid objects")
            } else {
                print("✅ Found \(detectedBoxes.count) valid objects")
                
                // Clear existing detections
                self.manager?.clearDetectedBoxes()
                
                // Add all detected boxes
                self.manager?.addDetectedBoxes(detectedBoxes)
                
                print("✅ SAM2 auto-detection complete with \(detectedBoxes.count) objects")
            }
            self.manager?.finishProcessing()
        }
    }

    // MARK: - Test Point with SAM2

    private func testPointWithSAM2(
        point: CGPoint,
        in image: UIImage,
        imageFeatures: [String: MLFeatureValue],
        promptEncoder: MLModel,
        maskDecoder: MLModel
    ) async -> LabeledBox? {
        do {
            // Convert point to SAM2 coordinates
            let normalizedImage = normalizeImageOrientation(image)
            let normalizedPoint = CGPoint(
                x: point.x * (normalizedImage.size.width / image.size.width),
                y: point.y * (normalizedImage.size.height / image.size.height)
            )
            let sam2Point = normalizePointForSAM2(normalizedPoint, imageSize: normalizedImage.size)

            // Run prompt encoder
            let promptFeatures = try await runPromptEncoder(sam2Point, using: promptEncoder)

            // Run mask decoder
            let mask = try await runMaskDecoder(
                imageFeatures: imageFeatures,
                promptFeatures: promptFeatures,
                using: maskDecoder
            )

            // Extract segmentation
            let (boundingBox, contourPoints) = extractPreciseSegmentation(from: mask)

            return LabeledBox.sam2Box(
                id: UUID(),
                label: "SAM2 Auto Object",
                boundingRect: boundingBox,
                contourPoints: contourPoints,
                detectionMethod: "SAM2 Auto-Detection",
                isSaved: false
            )

        } catch {
            print("SAM2 point test error: \(error)")
            return nil
        }
    }

    // MARK: - Validation

    private func isValidObjectDetection(_ box: LabeledBox, imageSize: CGSize) -> Bool {
        let area = box.rect.width * box.rect.height

        // Relaxed size filtering - allow 0.5% to 95% of image
        guard area > 0.005 && area < 0.95 else {
            print("❌ Rejected for size: area=\(area)")
            return false
        }

        // Relaxed aspect ratio - allow very wide or tall objects
        let aspectRatio = box.rect.width / box.rect.height
        guard aspectRatio > 0.05 && aspectRatio < 20.0 else {
            print("❌ Rejected for aspect ratio: \(aspectRatio)")
            return false
        }

        // Reject if completely at edge
        let edgeMargin: CGFloat = 0.01
        let touchesEdge = box.rect.minX <= edgeMargin ||
            box.rect.minY <= edgeMargin ||
            box.rect.maxX >= (1.0 - edgeMargin) ||
            box.rect.maxY >= (1.0 - edgeMargin)

        // Only reject if it's a full-screen detection (likely background noise)
        let isFullScreen = area > 0.8 && touchesEdge
        if isFullScreen {
            print("❌ Rejected full-screen detection")
            return false
        }

        print("✅ Accepted detection: area=\(area), aspectRatio=\(aspectRatio)")
        return true
    }

    // MARK: - CoreML Model Operations

    private func runImageEncoder(_ pixelBuffer: CVPixelBuffer, using model: MLModel) async throws -> [String: MLFeatureValue] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try await model.prediction(from: input)

        // Return all image encoder outputs as a dictionary
        guard let imageEmbedding = output.featureValue(for: "image_embedding"),
              let featsS0 = output.featureValue(for: "feats_s0"),
              let featsS1 = output.featureValue(for: "feats_s1")
        else {
            print("ImageEncoder outputs: \(output.featureNames)")
            throw SAM2Error.modelOutputError
        }

        return [
            "image_embedding": imageEmbedding,
            "feats_s0": featsS0,
            "feats_s1": featsS1,
        ]
    }

    private func runPromptEncoder(_ point: CGPoint, using model: MLModel) async throws -> [String: MLFeatureValue] {
        // Create point and label arrays matching the test format
        let points = try MLMultiArray(shape: [1, 1, 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, 1], dataType: .float32)

        // Set point coordinates
        points[[0, 0, 0] as [NSNumber]] = NSNumber(value: Float(point.x))
        points[[0, 0, 1] as [NSNumber]] = NSNumber(value: Float(point.y))

        // Set label (1.0 for positive click)
        labels[[0, 0] as [NSNumber]] = NSNumber(value: 1.0)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: points),
            "labels": MLFeatureValue(multiArray: labels),
        ])

        let output = try await model.prediction(from: input)

        // Return both sparse and dense embeddings
        guard let sparseEmbedding = output.featureValue(for: "sparse_embeddings"),
              let denseEmbedding = output.featureValue(for: "dense_embeddings")
        else {
            print("PromptEncoder outputs: \(output.featureNames)")
            throw SAM2Error.modelOutputError
        }

        return [
            "sparse_embeddings": sparseEmbedding,
            "dense_embeddings": denseEmbedding,
        ]
    }

    private func runMaskDecoder(imageFeatures: [String: MLFeatureValue], promptFeatures: [String: MLFeatureValue], using model: MLModel) async throws -> MLMultiArray {
        // Extract features from dictionaries
        guard let imageEmbedding = imageFeatures["image_embedding"],
              let featsS0 = imageFeatures["feats_s0"],
              let featsS1 = imageFeatures["feats_s1"],
              let sparseEmbedding = promptFeatures["sparse_embeddings"],
              let denseEmbedding = promptFeatures["dense_embeddings"]
        else {
            throw SAM2Error.modelOutputError
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": imageEmbedding,
            "feats_s0": featsS0,
            "feats_s1": featsS1,
            "sparse_embedding": sparseEmbedding,
            "dense_embedding": denseEmbedding,
        ])

        let output = try await model.prediction(from: input)

        // Get low resolution masks
        guard let masks = output.featureValue(for: "low_res_masks")?.multiArrayValue else {
            print("MaskDecoder outputs: \(output.featureNames)")
            throw SAM2Error.modelOutputError
        }

        return masks
    }

    // MARK: - Image Preprocessing

    private func prepareImageForSAM2(_ image: UIImage) -> CVPixelBuffer? {
        let targetSize = CGSize(width: 1024, height: 1024)

        // Create a properly oriented UIImage first
        let fixedImage = normalizeImageOrientation(image)

        guard let cgImage = fixedImage.cgImage else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, Int(targetSize.width), Int(targetSize.height),
                                         kCVPixelFormatType_32BGRA, nil, &pixelBuffer)

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: Int(targetSize.width),
                                height: Int(targetSize.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)

        // Draw the properly oriented image
        context?.draw(cgImage, in: CGRect(origin: .zero, size: targetSize))
        CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))

        return buffer
    }

    private func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        // If already up orientation, return as-is
        if image.imageOrientation == .up {
            return image
        }

        print("Fixing orientation: \(image.imageOrientation.rawValue) for size: \(image.size)")

        // Calculate the correct size for the oriented image
        var newSize = image.size
        if image.imageOrientation == .left || image.imageOrientation == .right ||
            image.imageOrientation == .leftMirrored || image.imageOrientation == .rightMirrored
        {
            // Portrait photos - swap width/height
            newSize = CGSize(width: image.size.height, height: image.size.width)
        }

        // Create oriented image
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let orientedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        print("Fixed image size: \(orientedImage?.size ?? .zero)")
        return orientedImage ?? image
    }

    // MARK: - Mask Processing

    private func extractPreciseSegmentation(from mask: MLMultiArray) -> (CGRect, [CGPoint]) {
        // Convert SAM2 mask to precise contours
        let shape = mask.shape.map { $0.intValue }
        guard shape.count >= 2 else {
            // Return fallback rect WITH contour points (not empty!)
            let fallbackRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
            return (fallbackRect, generateRectContour(from: fallbackRect))
        }

        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]

        print("Mask shape: \(width) x \(height)")

        // Extract high-quality binary mask using optimal threshold
        let binaryMask = analyzer.createOptimalBinaryMask(from: mask, width: width, height: height)

        // Find the main object (largest connected component)
        let mainObjectMask = analyzer.extractMainObject(from: binaryMask, width: width, height: height)

        // Trace EXACT boundary contour
        let boundaryContour = analyzer.traceExactBoundary(mask: mainObjectMask, width: width, height: height)

        if !boundaryContour.isEmpty {
            print("Perfect boundary contour with \(boundaryContour.count) points")

            // Calculate precise bounding box
            let boundingBox = analyzer.calculatePreciseBoundingBox(from: boundaryContour)

            // SAM2 outputs are already in the correct coordinate system
            let normalizedRect = CGRect(
                x: Double(boundingBox.minX) / Double(width),
                y: Double(boundingBox.minY) / Double(height),
                width: Double(boundingBox.width) / Double(width),
                height: Double(boundingBox.height) / Double(height)
            )

            let normalizedContour = boundaryContour.map { point in
                CGPoint(
                    x: point.x / CGFloat(width),
                    y: point.y / CGFloat(height)
                )
            }

            print("Consistent segmentation: \(normalizedRect) with \(normalizedContour.count) points")
            return (normalizedRect.constrainedToNormalized(), normalizedContour)
        }

        print("Fallback to basic detection")
        let fallbackRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        return (fallbackRect, generateRectContour(from: fallbackRect))
    }

    // MARK: - Helper Methods

    /// Generate contour points from a rectangle (for fallback when precise segmentation fails)
    private func generateRectContour(from rect: CGRect) -> [CGPoint] {
        return [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private func convertTapPointToImageCoordinates(tapPoint: CGPoint, imageViewBounds: CGRect, imageSize: CGSize) -> CGPoint {
        print("Converting: \(tapPoint) in bounds: \(imageViewBounds) for image: \(imageSize)")

        // Calculate the ACTUAL display rect where the image appears
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = imageViewBounds.width / imageViewBounds.height

        var actualImageDisplayRect: CGRect

        if imageAspect > viewAspect {
            // Image is wider than view (landscape in portrait) - LETTERBOXED TOP/BOTTOM
            let displayHeight = imageViewBounds.width / imageAspect
            let yOffset = (imageViewBounds.height - displayHeight) / 2
            actualImageDisplayRect = CGRect(
                x: imageViewBounds.minX,
                y: imageViewBounds.minY + yOffset,
                width: imageViewBounds.width,
                height: displayHeight
            )
        } else {
            // Image is taller than view - LETTERBOXED LEFT/RIGHT
            let displayWidth = imageViewBounds.height * imageAspect
            let xOffset = (imageViewBounds.width - displayWidth) / 2
            actualImageDisplayRect = CGRect(
                x: imageViewBounds.minX + xOffset,
                y: imageViewBounds.minY,
                width: displayWidth,
                height: imageViewBounds.height
            )
        }

        print("Actual image display rect: \(actualImageDisplayRect)")

        // Check if tap is within the actual image bounds
        guard actualImageDisplayRect.contains(tapPoint) else {
            print("Tap is outside image bounds! Clamping to nearest edge.")
            let clampedPoint = CGPoint(
                x: max(actualImageDisplayRect.minX, min(actualImageDisplayRect.maxX, tapPoint.x)),
                y: max(actualImageDisplayRect.minY, min(actualImageDisplayRect.maxY, tapPoint.y))
            )
            print("Clamped tap: \(clampedPoint)")
            return convertClampedPoint(clampedPoint, displayRect: actualImageDisplayRect, imageSize: imageSize)
        }

        // Convert tap to image coordinates
        return convertClampedPoint(tapPoint, displayRect: actualImageDisplayRect, imageSize: imageSize)
    }

    private func convertClampedPoint(_ point: CGPoint, displayRect: CGRect, imageSize: CGSize) -> CGPoint {
        let relativeX = (point.x - displayRect.minX) / displayRect.width
        let relativeY = (point.y - displayRect.minY) / displayRect.height

        let imageX = relativeX * imageSize.width
        let imageY = relativeY * imageSize.height

        let result = CGPoint(x: imageX, y: imageY)
        print("Final image coordinates: \(result)")

        return result
    }

    private func normalizePointForSAM2(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        // Normalize point to SAM2's expected coordinate system
        return CGPoint(
            x: point.x / imageSize.width * 1024,
            y: point.y / imageSize.height * 1024
        )
    }

    private func hasSignificantOverlap(_ rect: CGRect, with existingRects: [CGRect]) -> Bool {
        for existing in existingRects {
            let intersection = rect.intersection(existing)
            let unionArea = rect.area + existing.area - intersection.area
            let iou = intersection.area / unionArea

            if iou > 0.3 { // 30% overlap threshold
                return true
            }
        }
        return false
    }

    // MARK: - Fallback Methods

    private func fallbackToSimpleDetection(image: UIImage) async {
        print("Falling back to simple detection")
        await MainActor.run {
            self.manager?.finishProcessing()
        }
    }

    private func fallbackToVisionTapDetection(at point: CGPoint, in image: UIImage) async {
        print("Falling back to simple tap detection")

        let tapBox = LabeledBox(
            id: UUID(),
            label: "Tapped Object",
            rect: CGRect(
                x: max(0, (point.x / image.size.width) - 0.1),
                y: max(0, (point.y / image.size.height) - 0.1),
                width: 0.2,
                height: 0.2
            ).constrainedToNormalized(),
            isSaved: false,
            detectionMethod: "Simple Tap (Fallback)"
        )

        await MainActor.run {
            self.manager?.addDetectedBox(tapBox)
            self.manager?.finishProcessing()
        }
    }
}

// MARK: - Extensions

extension CGRect {
    var area: CGFloat {
        return width * height
    }
}
