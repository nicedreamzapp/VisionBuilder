import SwiftUI

struct LabeledBox: Identifiable, Codable {
    let id: UUID
    var label: String
    var rect: CGRect // Keep for backward compatibility
    var isSaved: Bool
    var detectionMethod: String?

    // NEW: Precise segmentation data
    var contourPoints: [CGPoint]? // Polygon outline points
    var maskData: Data? // Raw mask bitmap data
    var maskSize: CGSize? // Original mask dimensions
    var hasPreciseSegmentation: Bool {
        return contourPoints != nil || maskData != nil
    }

    // Convenience initializers
    init(id: UUID = UUID(), label: String, rect: CGRect, isSaved: Bool, detectionMethod: String? = nil) {
        self.id = id
        self.label = label
        self.rect = rect
        self.isSaved = isSaved
        self.detectionMethod = detectionMethod
        contourPoints = nil
        maskData = nil
        maskSize = nil
    }

    // New initializer with precise segmentation
    init(id: UUID = UUID(), label: String, rect: CGRect, isSaved: Bool, detectionMethod: String? = nil, contourPoints: [CGPoint]? = nil, maskData: Data? = nil, maskSize: CGSize? = nil) {
        self.id = id
        self.label = label
        self.rect = rect
        self.isSaved = isSaved
        self.detectionMethod = detectionMethod
        self.contourPoints = contourPoints
        self.maskData = maskData
        self.maskSize = maskSize
    }

    // Get display shape - use contour if available, otherwise rect
    var displayPath: Path {
        if let points = contourPoints, !points.isEmpty {
            // Create path from contour points
            var path = Path()
            guard let firstPoint = points.first else { return rectanglePath }

            path.move(to: firstPoint)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            return path
        } else {
            // Fallback to rectangle
            return rectanglePath
        }
    }

    private var rectanglePath: Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    }

    // Convert normalized contour points to screen coordinates (SMART COORDINATE DETECTION)
    func screenContourPoints(imageSize: CGSize, canvasSize: CGSize) -> [CGPoint] {
        guard let points = contourPoints else { return [] }

        let scaleX = canvasSize.width / imageSize.width
        let scaleY = canvasSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let scaledImageSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        let offsetX = (canvasSize.width - scaledImageSize.width) / 2
        let offsetY = (canvasSize.height - scaledImageSize.height) / 2

        return points.map { point in
            // FIXED: Direct coordinate mapping
            CGPoint(
                x: point.x * scaledImageSize.width + offsetX,
                y: point.y * scaledImageSize.height + offsetY
            )
        }
    }

    // Get tight bounding rect from contour points
    var tightBoundingRect: CGRect {
        guard let points = contourPoints, !points.isEmpty else {
            return rect
        }

        let minX = points.map { $0.x }.min() ?? rect.minX
        let maxX = points.map { $0.x }.max() ?? rect.maxX
        let minY = points.map { $0.y }.min() ?? rect.minY
        let maxY = points.map { $0.y }.max() ?? rect.maxY

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Extensions

// Helper for creating SAM2 boxes with precise segmentation
extension LabeledBox {
    static func sam2Box(
        id: UUID = UUID(),
        label: String,
        boundingRect: CGRect,
        contourPoints: [CGPoint],
        detectionMethod: String = "SAM2 CoreML",
        isSaved: Bool = false
    ) -> LabeledBox {
        return LabeledBox(
            id: id,
            label: label,
            rect: boundingRect,
            isSaved: isSaved,
            detectionMethod: detectionMethod,
            contourPoints: contourPoints
        )
    }
}
