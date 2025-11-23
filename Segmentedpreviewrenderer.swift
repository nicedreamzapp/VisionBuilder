//
//  SegmentedPreviewRenderer.swift
//  Vision Builder
//
//  Created for human-in-the-loop active learning flow
//

import SwiftUI
import UIKit
import CoreImage

/// Utility for rendering segmented object previews using SAM2 contour points
class SegmentedPreviewRenderer {

    // MARK: - Preview Generation

    /// Generate a masked preview image showing only the segmented object
    /// - Parameters:
    ///   - image: Source UIImage
    ///   - contourPoints: Array of CGPoints defining the object boundary (in pixel coordinates)
    ///   - backgroundColor: Background color (default: white)
    /// - Returns: Cropped and masked UIImage showing only the object, or nil if generation fails
    static func generateSegmentedPreview(
        from image: UIImage,
        contourPoints: [CGPoint],
        backgroundColor: UIColor = .white
    ) -> UIImage? {

        guard !contourPoints.isEmpty else {
            print("⚠️ SegmentedPreviewRenderer: No contour points provided")
            return nil
        }

        guard let cgImage = image.cgImage else {
            print("⚠️ SegmentedPreviewRenderer: Could not get CGImage")
            return nil
        }

        let fullImageSize = CGSize(width: cgImage.width, height: cgImage.height)

        // Calculate tight bounding box from contour points
        let boundingBox = calculateBoundingBox(for: contourPoints, in: fullImageSize)

        // Add proportional padding (10% of the smaller dimension)
        let padding = min(boundingBox.width, boundingBox.height) * 0.1
        let paddedBox = boundingBox.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: fullImageSize))

        guard paddedBox.width > 1 && paddedBox.height > 1 else {
            print("⚠️ SegmentedPreviewRenderer: Bounding box too small")
            return nil
        }

        // Translate contour points to the cropped coordinate system
        let translatedContour = contourPoints.map { point in
            CGPoint(x: point.x - paddedBox.origin.x, y: point.y - paddedBox.origin.y)
        }

        // Crop the source image first (more efficient than masking full image)
        guard let croppedCG = cgImage.cropping(to: paddedBox) else {
            print("⚠️ SegmentedPreviewRenderer: Could not crop image")
            return nil
        }

        let croppedSize = CGSize(width: croppedCG.width, height: croppedCG.height)

        // Create mask for the cropped region
        guard let maskImage = createMaskImage(from: translatedContour, imageSize: croppedSize) else {
            print("⚠️ SegmentedPreviewRenderer: Could not create mask")
            return nil
        }

        // Apply mask to cropped image
        guard let maskedImage = applyMask(maskImage, to: croppedCG, backgroundColor: backgroundColor) else {
            print("⚠️ SegmentedPreviewRenderer: Could not apply mask")
            return nil
        }

        return UIImage(cgImage: maskedImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Simple Crop (no masking)

    /// Generate a simple cropped preview without masking (faster, for fallback)
    static func generateCroppedPreview(
        from image: UIImage,
        boundingBox: CGRect
    ) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let imageRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)

        // Add 10% padding
        let padding = min(boundingBox.width, boundingBox.height) * 0.1
        let paddedBox = boundingBox.insetBy(dx: -padding, dy: -padding)
            .intersection(imageRect)

        guard let croppedCG = cgImage.cropping(to: paddedBox) else {
            return nil
        }

        return UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Mask Creation

    /// Create a binary mask image from contour points
    private static func createMaskImage(
        from contourPoints: [CGPoint],
        imageSize: CGSize
    ) -> CGImage? {

        let width = Int(imageSize.width)
        let height = Int(imageSize.height)

        guard width > 0 && height > 0 else { return nil }

        // Create bitmap context for mask
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Fill with black (masked out)
        context.setFillColor(gray: 0.0, alpha: 1.0)
        context.fill(CGRect(origin: .zero, size: imageSize))

        // Draw white (unmasked) polygon from contour points
        context.setFillColor(gray: 1.0, alpha: 1.0)

        let path = CGMutablePath()
        guard let firstPoint = contourPoints.first else { return nil }

        path.move(to: firstPoint)
        for point in contourPoints.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()

        context.addPath(path)
        context.fillPath()

        return context.makeImage()
    }

    /// Apply mask to source image with background color
    private static func applyMask(
        _ mask: CGImage,
        to image: CGImage,
        backgroundColor: UIColor
    ) -> CGImage? {

        let width = image.width
        let height = image.height

        // Create output context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Fill background
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        context.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
        context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))

        // Apply mask and draw image
        let rect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        context.clip(to: rect, mask: mask)
        context.draw(image, in: rect)

        return context.makeImage()
    }

    // MARK: - Helper Functions

    /// Calculate tight bounding box for contour points
    private static func calculateBoundingBox(
        for points: [CGPoint],
        in imageSize: CGSize
    ) -> CGRect {

        guard !points.isEmpty else {
            return CGRect(origin: .zero, size: imageSize)
        }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        // Clamp to image bounds
        minX = max(0, minX)
        minY = max(0, minY)
        maxX = min(imageSize.width, maxX)
        maxY = min(imageSize.height, maxY)

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    // MARK: - SwiftUI View Helper

    /// Create a SwiftUI Image view from segmented preview
    static func createSwiftUIPreview(
        from image: UIImage,
        contourPoints: [CGPoint]
    ) -> some View {
        Group {
            if let segmentedImage = generateSegmentedPreview(
                from: image,
                contourPoints: contourPoints,
                backgroundColor: .white
            ) {
                Image(uiImage: segmentedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback to original image with warning
                VStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(0.5)
                    Text("Segmentation preview unavailable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
