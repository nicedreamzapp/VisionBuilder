import Combine
import SwiftUI

// Single source of truth for all editor state
@MainActor
class BoxState: ObservableObject {
    // MARK: - State

    @Published var boxes: [LabeledBox] = []
    @Published var selectedBoxID: UUID? = nil
    @Published var mode: EditorMode = .viewing
    var currentImage: UIImage?

    // MARK: - Constants

    let maxBoxes = 4

    // MARK: - Mode Definition

    enum EditorMode: Equatable {
        case viewing
        case adding
        case segmenting
        case removing
    }

    // MARK: - Computed Properties

    var canAddMore: Bool {
        boxes.count < maxBoxes
    }

    var savedCount: Int {
        boxes.filter(\.isSaved).count
    }

    var selectedBox: LabeledBox? {
        guard let id = selectedBoxID else { return nil }
        return boxes.first { $0.id == id }
    }

    // MARK: - Mode Management

    func setMode(_ newMode: EditorMode) {
        mode = newMode

        // Clear selection when entering certain modes
        if newMode == .adding || newMode == .segmenting {
            selectedBoxID = nil
        }
    }

    // MARK: - Box Management

    func addBox(at normalizedPoint: CGPoint, imageSize _: CGSize) {
        guard canAddMore else { return }

        // Create larger box in normalized coordinates (20% of image size)
        let normalizedSize = CGSize(
            width: 0.2, // 20% of image width
            height: 0.2 // 20% of image height
        )

        let rect = CGRect(
            x: normalizedPoint.x - normalizedSize.width / 2,
            y: normalizedPoint.y - normalizedSize.height / 2,
            width: normalizedSize.width,
            height: normalizedSize.height
        ).constrainedToNormalized()

        let newBox = LabeledBox(
            id: UUID(),
            label: "",
            rect: rect,
            isSaved: false,
            detectionMethod: "Manual"
        )

        boxes.append(newBox)
        selectedBoxID = newBox.id

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func updateBox(id: UUID, rect: CGRect) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[index].rect = rect
    }

    func saveBox(id: UUID, label: String) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        // Trim whitespace from label
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        boxes[index].label = trimmedLabel.isEmpty ? "Object" : trimmedLabel
        boxes[index].isSaved = true

        // Success feedback
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func deleteBox(id: UUID) {
        boxes.removeAll { $0.id == id }
        if selectedBoxID == id {
            selectedBoxID = nil
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func selectBox(id: UUID?) {
        selectedBoxID = id
    }

    // MARK: - Segmentation

    func addSegmentedBox(normalizedRect: CGRect, detectionMethod: String = "Unknown") {
        guard canAddMore else { return }

        let constrainedRect = normalizedRect.constrainedToNormalized()
        let newBox = LabeledBox(
            id: UUID(),
            label: "",
            rect: constrainedRect,
            isSaved: false,
            detectionMethod: detectionMethod
        )

        boxes.append(newBox)
        selectedBoxID = newBox.id

        // Success feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Reset

    func reset() {
        boxes.removeAll()
        selectedBoxID = nil
        mode = .viewing
    }
}

// MARK: - Helpers

extension CGRect {
    func constrainedToNormalized() -> CGRect {
        var result = self

        // Ensure minimum size (5% of image)
        let minSize: CGFloat = 0.05
        result.size.width = max(minSize, result.width)
        result.size.height = max(minSize, result.height)

        // Constrain position to 0-1 range
        result.origin.x = max(0, min(result.origin.x, 1.0 - result.width))
        result.origin.y = max(0, min(result.origin.y, 1.0 - result.height))

        return result
    }
}
