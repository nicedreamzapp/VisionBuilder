import SwiftUI
import UIKit

// MARK: - BoxCanvasView with Precise Segmentation Support

struct BoxCanvasView: View {
    let image: UIImage
    @ObservedObject var boxState: BoxState
    @ObservedObject var sam2DetectionManager: SAM2DetectionManager

    let onDataBrowserTap: () -> Void

    @State private var showTapFeedback = false
    @State private var tapFeedbackLocation: CGPoint = .zero

    // Static palette of colors for overlays
    static let overlayColors: [Color] = [
        .red, .green, .blue, .purple, .orange,
        .yellow, .pink, .teal, .brown, .indigo,
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Base Image
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onTapGesture { location in
                        handleImageTap(at: location, geometry: geometry)
                    }

                // Existing Boxes from BoxState - now with precise segmentation
                ForEach(Array(boxState.boxes.enumerated()), id: \.element.id) { index, box in
                    let color = BoxCanvasView.overlayColors[index % BoxCanvasView.overlayColors.count]
                    PreciseBoxOverlayView(
                        box: box,
                        imageSize: image.size,
                        canvasSize: geometry.size,
                        isSelected: boxState.selectedBoxID == box.id,
                        overlayColor: color,
                        objectNumber: index + 1,
                        onSelect: { boxState.selectBox(id: box.id) }
                    )
                }

                // Remove the red rectangle test and put back:
                ForEach(sam2DetectionManager.detectedBoxes) { detectedBox in
                    if !boxState.boxes.contains(where: { $0.id == detectedBox.id }) {
                        SAM2BoxOverlayView(
                            box: detectedBox,
                            imageSize: image.size,
                            canvasSize: geometry.size,
                            onAccept: {
                                boxState.boxes.append(detectedBox)
                                boxState.selectBox(id: detectedBox.id)
                                sam2DetectionManager.detectedBoxes.removeAll { $0.id == detectedBox.id }
                            },
                            onReject: {
                                sam2DetectionManager.detectedBoxes.removeAll { $0.id == detectedBox.id }
                            }
                        )
                    }
                }

                // Tap Feedback
                if showTapFeedback {
                    TapFeedbackView(location: tapFeedbackLocation)
                        .transition(.opacity)
                }
                if showTapFeedback {
                    // Debug crosshairs
                    ZStack {
                        Rectangle().fill(Color.red).frame(width: 40, height: 2)
                        Rectangle().fill(Color.red).frame(width: 2, height: 40)
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                    }
                    .position(tapFeedbackLocation)
                }

                // SAM 2 Processing Overlay
                if sam2DetectionManager.isProcessing {
                    SAM2ProcessingOverlay(
                        currentOperation: sam2DetectionManager.currentOperation,
                        progress: sam2DetectionManager.processingProgress
                    )
                }
            }
        }
        .onAppear {
            boxState.currentImage = image
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in
                    if !sam2DetectionManager.isProcessing && !sam2DetectionManager.detectedBoxes.isEmpty {
                        print("DEBUG: Timer processing \(sam2DetectionManager.detectedBoxes.count) objects")

                        for detectedBox in sam2DetectionManager.detectedBoxes {
                            print("DEBUG: Object has \(detectedBox.contourPoints?.count ?? 0) contour points")
                            print("DEBUG: Object rect: \(detectedBox.rect)")

                            var box = detectedBox
                            box.isSaved = false
                            box.label = ""
                            boxState.boxes.append(box)
                        }
                        sam2DetectionManager.detectedBoxes.removeAll()
                        print("DEBUG: boxState now has \(boxState.boxes.count) total objects")
                    }
                }
            }
        }
        /*
         .onChange(of: sam2DetectionManager.detectedBoxes) { _, newBoxes in
             // Auto-accept single high-confidence detections
             if newBoxes.count == 1,
                let box = newBoxes.first,
                box.detectionMethod?.contains("SAM2") == true {

                 boxState.boxes.append(box)
                 boxState.selectBox(id: box.id)
                 sam2DetectionManager.detectedBoxes.removeAll()
             }
         }
         */
        /*
         .onReceive(sam2DetectionManager.$isProcessing) { isProcessing in
             if !isProcessing && !sam2DetectionManager.detectedBoxes.isEmpty {
                 // Auto-accept all auto-detected objects
                 for detectedBox in sam2DetectionManager.detectedBoxes {
                     var box = detectedBox
                     box.isSaved = false
                     box.label = ""
                     boxState.boxes.append(box)
                 }
                 sam2DetectionManager.detectedBoxes.removeAll()
             }
         }
         */
    }

    private func handleImageTap(at location: CGPoint, geometry: GeometryProxy) {
        // ADD: Debug logging
        print("🎯 === CANVAS TAP DEBUG ===")
        print("🎯 Tap location: \(location)")
        print("🎯 Canvas size: \(geometry.size)")
        print("🎯 Image size: \(image.size)")
        print("🎯 === END CANVAS DEBUG ===")

        // Show tap feedback (your existing code)
        tapFeedbackLocation = location
        showTapFeedback = true

        // Check if we tapped on a box first (your existing code)
        let tappedBox = findTappedBox(at: location, geometry: geometry)

        if let tappedBox = tappedBox {
            boxState.selectBox(id: tappedBox.id)
        } else {
            sam2DetectionManager.tapToDetect(
                at: location,
                in: image,
                imageViewBounds: CGRect(origin: .zero, size: geometry.size)
            )
        }

        // Hide tap feedback (your existing code)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showTapFeedback = false
        }
    }

    private func findTappedBox(at location: CGPoint, geometry: GeometryProxy) -> LabeledBox? {
        for box in boxState.boxes {
            // Check precise contour first if available
            if box.hasPreciseSegmentation {
                let screenPoints = box.screenContourPoints(imageSize: image.size, canvasSize: geometry.size)
                if pointInsidePolygon(point: location, polygon: screenPoints) {
                    return box
                }
            } else {
                // Fallback to rectangle hit testing
                let screenRect = convertNormalizedToScreen(
                    box.rect,
                    imageSize: image.size,
                    canvasSize: geometry.size
                )

                if screenRect.contains(location) {
                    return box
                }
            }
        }
        return nil
    }

    // Point-in-polygon test for precise hit detection
    private func pointInsidePolygon(point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count > 2 else { return false }

        var inside = false
        var j = polygon.count - 1

        for i in 0 ..< polygon.count {
            let xi = polygon[i].x
            let yi = polygon[i].y
            let xj = polygon[j].x
            let yj = polygon[j].y

            if ((yi > point.y) != (yj > point.y)) &&
                (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi)
            {
                inside = !inside
            }
            j = i
        }

        return inside
    }

    private func convertNormalizedToScreen(_ rect: CGRect, imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        let scaleX = canvasSize.width / imageSize.width
        let scaleY = canvasSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let scaledImageSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        let offsetX = (canvasSize.width - scaledImageSize.width) / 2
        let offsetY = (canvasSize.height - scaledImageSize.height) / 2

        return CGRect(
            x: rect.origin.x * scaledImageSize.width + offsetX,
            y: rect.origin.y * scaledImageSize.height + offsetY,
            width: rect.width * scaledImageSize.width,
            height: rect.height * scaledImageSize.height
        )
    }
}

// MARK: - Precise Box Overlay for Saved Boxes

struct PreciseBoxOverlayView: View {
    let box: LabeledBox
    let imageSize: CGSize
    let canvasSize: CGSize
    let isSelected: Bool
    let overlayColor: Color
    let objectNumber: Int
    let onSelect: () -> Void

    var body: some View {
        ZStack {
            if box.hasPreciseSegmentation {
                // Draw PERFECT segmentation like Python (0.25 opacity fill + crisp outline)
                PreciseSegmentationShape(
                    contourPoints: box.screenContourPoints(imageSize: imageSize, canvasSize: canvasSize)
                )
                .fill(overlayColor.opacity(0.25)) // FIXED: Darker opacity & use overlayColor
                .overlay(
                    PreciseSegmentationShape(
                        contourPoints: box.screenContourPoints(imageSize: imageSize, canvasSize: canvasSize)
                    )
                    .stroke(overlayColor, lineWidth: isSelected ? 3 : 2) // Crisp boundary & overlayColor
                )
                .onTapGesture { onSelect() }
            } else {
                // Fallback to rectangle
                let screenRect = convertNormalizedToScreen()

                Rectangle()
                    .fill(Color.clear)
                    .overlay(
                        Rectangle()
                            .stroke(overlayColor, lineWidth: isSelected ? 3 : 2)
                    )
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .onTapGesture { onSelect() }
            }

            // Label badge - always shown with object number or label if set
            let labelPosition = getLabelPosition()

            Text(box.label.isEmpty ? "Object \(objectNumber)" : box.label)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(overlayColor.opacity(0.9))
                .foregroundColor(.white)
                .cornerRadius(4)
                .position(labelPosition)
        }
    }

    private func getLabelPosition() -> CGPoint {
        if box.hasPreciseSegmentation {
            // Position label at top of precise bounding box
            let tightRect = box.tightBoundingRect
            let screenRect = CGRect(
                x: tightRect.minX * canvasSize.width,
                y: tightRect.minY * canvasSize.height,
                width: tightRect.width * canvasSize.width,
                height: tightRect.height * canvasSize.height
            )
            let minY = max(screenRect.minY - 10, 10)
            return CGPoint(x: screenRect.midX, y: minY)
        } else {
            let screenRect = convertNormalizedToScreen()
            let minY = max(screenRect.minY - 10, 10)
            return CGPoint(x: screenRect.midX, y: minY)
        }
    }

    private func convertNormalizedToScreen() -> CGRect {
        let scaleX = canvasSize.width / imageSize.width
        let scaleY = canvasSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let scaledImageSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        let offsetX = (canvasSize.width - scaledImageSize.width) / 2
        let offsetY = (canvasSize.height - scaledImageSize.height) / 2

        return CGRect(
            x: box.rect.origin.x * scaledImageSize.width + offsetX,
            y: box.rect.origin.y * scaledImageSize.height + offsetY,
            width: box.rect.width * scaledImageSize.width,
            height: box.rect.height * scaledImageSize.height
        )
    }
}

// MARK: - Custom Shape for Precise Segmentation (FIXED FILL)

struct PreciseSegmentationShape: Shape {
    let contourPoints: [CGPoint]

    func path(in _: CGRect) -> Path {
        guard contourPoints.count > 2 else {
            return Path()
        }

        var path = Path()

        // Create FILLED path (like Python mask)
        path.move(to: contourPoints[0])

        // Add all boundary points
        for i in 1 ..< contourPoints.count {
            path.addLine(to: contourPoints[i])
        }

        // CRITICAL: Close the path to enable fill
        path.closeSubpath()

        return path
    }
}

// MARK: - SAM 2 Detection Overlay (Enhanced for Precise Shapes)

struct SAM2BoxOverlayView: View {
    let box: LabeledBox
    let imageSize: CGSize
    let canvasSize: CGSize
    let onAccept: () -> Void
    let onReject: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Pulsing border for SAM 2 detection - use precise shape if available
            if box.hasPreciseSegmentation {
                PreciseSegmentationShape(
                    contourPoints: box.screenContourPoints(imageSize: imageSize, canvasSize: canvasSize)
                )
                .stroke(Color.blue, lineWidth: 3)
                .fill(Color.blue.opacity(0.1))
                .scaleEffect(pulseScale)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseScale)
            } else {
                // Fallback to rectangle
                let screenRect = convertNormalizedToScreen()

                Rectangle()
                    .fill(Color.clear)
                    .overlay(
                        Rectangle()
                            .stroke(Color.blue, lineWidth: 3)
                    )
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .scaleEffect(pulseScale)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseScale)
            }

            // SAM 2 badge and buttons
            let badgePosition = getBadgePosition()
            let buttonsPosition = getButtonsPosition()

            // SAM 2 badge
            Text("🎯 SAM 2")
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.9))
                .foregroundColor(.white)
                .cornerRadius(6)
                .position(badgePosition)

            // Accept/Reject buttons
            HStack(spacing: 8) {
                Button("✓") {
                    onAccept()
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Color.green)
                .clipShape(Circle())

                Button("✗") {
                    onReject()
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Color.red)
                .clipShape(Circle())
            }
            .position(buttonsPosition)
        }
        .onAppear {
            pulseScale = 1.1
        }
    }

    private func getBadgePosition() -> CGPoint {
        if box.hasPreciseSegmentation {
            let tightRect = box.tightBoundingRect
            let screenRect = CGRect(
                x: tightRect.minX * canvasSize.width,
                y: tightRect.minY * canvasSize.height,
                width: tightRect.width * canvasSize.width,
                height: tightRect.height * canvasSize.height
            )
            let minY = max(screenRect.minY - 15, 10)
            return CGPoint(x: screenRect.midX, y: minY)
        } else {
            let screenRect = convertNormalizedToScreen()
            let minY = max(screenRect.minY - 15, 10)
            return CGPoint(x: screenRect.midX, y: minY)
        }
    }

    private func getButtonsPosition() -> CGPoint {
        if box.hasPreciseSegmentation {
            let tightRect = box.tightBoundingRect
            let screenRect = CGRect(
                x: tightRect.minX * canvasSize.width,
                y: tightRect.minY * canvasSize.height,
                width: tightRect.width * canvasSize.width,
                height: tightRect.height * canvasSize.height
            )
            return CGPoint(x: screenRect.midX, y: screenRect.maxY + 20)
        } else {
            let screenRect = convertNormalizedToScreen()
            return CGPoint(x: screenRect.midX, y: screenRect.maxY + 20)
        }
    }

    private func convertNormalizedToScreen() -> CGRect {
        let scaleX = canvasSize.width / imageSize.width
        let scaleY = canvasSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let scaledImageSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        let offsetX = (canvasSize.width - scaledImageSize.width) / 2
        let offsetY = (canvasSize.height - scaledImageSize.height) / 2

        return CGRect(
            x: box.rect.origin.x * scaledImageSize.width + offsetX,
            y: box.rect.origin.y * scaledImageSize.height + offsetY,
            width: box.rect.width * scaledImageSize.width,
            height: box.rect.height * scaledImageSize.height
        )
    }
}

// MARK: - SAM 2 Processing Overlay (unchanged)

struct SAM2ProcessingOverlay: View {
    let currentOperation: String
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // SAM 2 Logo
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 80, height: 80)

                    Text("🎯")
                        .font(.system(size: 40))
                        .scaleEffect(1.2)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: currentOperation)
                }

                VStack(spacing: 8) {
                    Text("SAM 2 Processing")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text(currentOperation)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)

                    if progress > 0 {
                        ProgressView(value: progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                            .frame(width: 200)
                    }
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}
