// MARK: - LabelingEditorView.swift with UX Fixes

import SwiftUI

struct LabelingEditorView: View {
    let datasetImage: DatasetImage
    let onSelectNewPhoto: () -> Void
    let onBrowseDataset: () -> Void
    let onClose: () -> Void
    let qualityManager: DataQualityManager

    // Direct UIImage parameter for new photos (fixes temporary filepath bug)
    let directImage: UIImage?

    // Auto-start segmentation flag
    let autoStartSegmentation: Bool

    // Callback for labeled count changes
    let onLabeledCountChanged: ((Int) -> Void)?

    @EnvironmentObject private var datasetManager: DatasetManager

    @StateObject private var boxState = BoxState()
    @StateObject private var exportManager = ExportManager()
    @StateObject private var sam2DetectionManager = SAM2DetectionManager()

    @State private var currentImage: UIImage?
    @State private var metadata: EnhancedObjectMetadata?
    @State private var showLabelDialog = false
    @State private var labelText = ""
    @State private var hasStartedAutoSegmentation = false

    // Undo stack
    @State private var undoStack: [[LabeledBox]] = []
    @State private var canUndo = false

    // Quality indicator
    @State private var currentQualityScore: Float = 0
    @State private var showQualityIndicator = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer().frame(height: 60)

                    // Image canvas
                    imageCanvasSection(geometry: geometry)

                    Spacer().frame(height: 16)

                    // Quality indicator (when image loaded)
                    if showQualityIndicator && currentImage != nil {
                        qualityIndicatorView
                    }

                    // Control panel
                    controlPanelSection

                    Spacer().frame(height: 20)
                }
            }
            .ignoresSafeArea(.keyboard)
            .overlay(labelDialogOverlay)
            .onAppear {
                exportManager.datasetManager = datasetManager
                loadImage()
            }
            .onChange(of: boxState.boxes) { _, newBoxes in
                handleBoxesChanged(newBoxes)
            }
            .onChange(of: exportManager.exportComplete) { oldValue, newValue in
                handleExportCompletion(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: exportManager.lastError) { _, newError in
                if let error = newError {
                    ToastManager.shared.showError("Export failed", message: error)
                    exportManager.lastError = nil
                }
            }
            .navigationBarTitle("SAM 2 Labeling", displayMode: .inline)
            .navigationBarItems(
                leading: undoButton,
                trailing: Button("Done") { onClose() }
            )
        }
    }

    // MARK: - Undo Button

    private var undoButton: some View {
        Button {
            performUndo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!canUndo)
    }

    // MARK: - Quality Indicator

    private var qualityIndicatorView: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor(qualityColor)

            Text("Sharpness")
                .font(.caption)
                .foregroundColor(.secondary)

            // Quality bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(qualityColor)
                        .frame(width: geo.size.width * CGFloat(currentQualityScore))
                }
            }
            .frame(width: 80, height: 8)

            Text(qualityLabel)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(qualityColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal)
    }

    private var qualityColor: Color {
        switch currentQualityScore {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .blue
        case 0.4..<0.6: return .orange
        default: return .red
        }
    }

    private var qualityLabel: String {
        switch currentQualityScore {
        case 0.8...1.0: return "Excellent"
        case 0.6..<0.8: return "Good"
        case 0.4..<0.6: return "Fair"
        default: return "Poor"
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.98, green: 0.98, blue: 1.0), Color.white],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Image Canvas

    private func imageCanvasSection(geometry: GeometryProxy) -> some View {
        ZStack {
            if let uiImage = currentImage {
                BoxCanvasView(
                    image: uiImage,
                    boxState: boxState,
                    sam2DetectionManager: sam2DetectionManager,
                    onDataBrowserTap: onBrowseDataset
                )
            } else {
                loadingView
            }
        }
        .frame(
            width: geometry.size.width,
            height: calculateImageHeight(screenHeight: geometry.size.height)
        )
        .clipped()
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading SAM 2...")
                .font(.headline)
                .foregroundColor(.secondary)

            if sam2DetectionManager.isProcessing {
                Text(sam2DetectionManager.currentOperation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func calculateImageHeight(screenHeight: CGFloat) -> CGFloat {
        let reservedSpace: CGFloat = 340
        return max(screenHeight - reservedSpace, 200)
    }

    // MARK: - Control Panel

    private var controlPanelSection: some View {
        VStack(spacing: 12) {
            // Progress and instruction
            HStack {
                Text(instructionText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                // Object count badge
                if !boxState.boxes.isEmpty {
                    Text("\(boxState.savedCount) labeled")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            )

            SimplifiedControlPanel(
                boxState: boxState,
                exportManager: exportManager,
                sam2DetectionManager: sam2DetectionManager,
                showLabelDialog: $showLabelDialog,
                showDatasetBrowser: .constant(false),
                onReturnToLibrary: onClose
            )
        }
        .padding(.horizontal)
        .transition(.move(edge: .bottom))
        .zIndex(2)
        .opacity(showLabelDialog ? 0.3 : 1)
    }

    private var instructionText: String {
        if currentImage == nil {
            return "Loading SAM 2 model..."
        } else if sam2DetectionManager.isProcessing {
            return sam2DetectionManager.currentOperation
        } else if boxState.boxes.isEmpty {
            return "Tap any object for SAM 2 detection"
        } else if let selectedBox = boxState.selectedBox, !selectedBox.isSaved {
            return "SAM 2 detected! Tap Save to label"
        } else {
            return "Tap more objects or export your data"
        }
    }

    // MARK: - Label Dialog

    private var labelDialogOverlay: some View {
        Group {
            if showLabelDialog {
                EnhancedLabelDialog(
                    isPresented: $showLabelDialog,
                    labelText: $labelText,
                    onSave: {
                        saveCurrentBox()
                    }
                )
            }
        }
    }

    // MARK: - Actions

    private func loadImage() {
        // Priority 1: Use direct image if provided (for new photos)
        if let directImage = directImage {
            currentImage = directImage
            boxState.currentImage = directImage
            calculateQualityScore(for: directImage)
            triggerAutoSegmentationIfNeeded()
            return
        }

        // Priority 2: Load from filepath (for existing dataset images)
        guard datasetImage.filepath != "temporary",
              FileManager.default.fileExists(atPath: datasetImage.filepath) else {
            ToastManager.shared.showError("Image not found", message: "Could not load the image file")
            return
        }

        if let image = UIImage(contentsOfFile: datasetImage.filepath) {
            currentImage = image
            boxState.currentImage = image
            calculateQualityScore(for: image)
            triggerAutoSegmentationIfNeeded()

            // Load metadata
            Task {
                await loadMetadataAsync()
            }
        } else {
            ToastManager.shared.showError("Failed to load image", message: "The file may be corrupted")
        }
    }

    private func triggerAutoSegmentationIfNeeded() {
        guard autoStartSegmentation,
              !hasStartedAutoSegmentation,
              let image = currentImage else { return }

        hasStartedAutoSegmentation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            sam2DetectionManager.autoDetectAllObjects(in: image)
        }
    }

    private func calculateQualityScore(for image: UIImage) {
        Task {
            let score = await qualityManager.calculateSharpness(for: image)
            await MainActor.run {
                currentQualityScore = score
            }
        }
    }

    private func loadMetadataAsync() async {
        let metadataPath = URL(fileURLWithPath: datasetImage.filepath)
            .deletingLastPathComponent()
            .appendingPathComponent("metadata.json")

        if let data = try? Data(contentsOf: metadataPath),
           let loadedMetadata = try? JSONDecoder().decode(EnhancedObjectMetadata.self, from: data) {
            await MainActor.run {
                self.metadata = loadedMetadata
            }
        }
    }

    private func saveCurrentBox() {
        if let selectedID = boxState.selectedBoxID {
            // Save state for undo
            pushUndoState()

            boxState.saveBox(id: selectedID, label: labelText)
            onLabeledCountChanged?(1)
            ToastManager.shared.showSuccess("Labeled '\(labelText)'")
            labelText = ""
        }
        showLabelDialog = false
    }

    private func handleBoxesChanged(_ newBoxes: [LabeledBox]) {
        canUndo = !undoStack.isEmpty
    }

    private func pushUndoState() {
        undoStack.append(boxState.boxes)
        if undoStack.count > 10 {
            undoStack.removeFirst()
        }
        canUndo = true
    }

    private func performUndo() {
        guard let previousState = undoStack.popLast() else { return }
        boxState.boxes = previousState
        canUndo = !undoStack.isEmpty
        ToastManager.shared.showInfo("Undone")
    }

    private func handleExportCompletion(oldValue: Bool, newValue: Bool) {
        if newValue, !oldValue {
            ToastManager.shared.showSuccess(
                "Saved to Dataset",
                message: "\(exportManager.exportedCount) object(s) exported"
            )
            exportManager.exportComplete = false
        }
    }
}

// MARK: - Convenience Initializers

extension LabelingEditorView {
    /// Initialize with a UIImage directly (for new photos from camera/library)
    init(
        image: UIImage,
        onSelectNewPhoto: @escaping () -> Void,
        onBrowseDataset: @escaping () -> Void,
        onClose: @escaping () -> Void,
        qualityManager: DataQualityManager,
        autoStartSegmentation: Bool = false,
        onLabeledCountChanged: ((Int) -> Void)? = nil
    ) {
        self.datasetImage = DatasetImage.createTemporary(from: image)
        self.onSelectNewPhoto = onSelectNewPhoto
        self.onBrowseDataset = onBrowseDataset
        self.onClose = onClose
        self.qualityManager = qualityManager
        self.directImage = image
        self.autoStartSegmentation = autoStartSegmentation
        self.onLabeledCountChanged = onLabeledCountChanged
    }

    /// Initialize with a DatasetImage (for existing dataset images)
    init(
        datasetImage: DatasetImage,
        onSelectNewPhoto: @escaping () -> Void,
        onBrowseDataset: @escaping () -> Void,
        onClose: @escaping () -> Void,
        qualityManager: DataQualityManager,
        autoStartSegmentation: Bool = false
    ) {
        self.datasetImage = datasetImage
        self.onSelectNewPhoto = onSelectNewPhoto
        self.onBrowseDataset = onBrowseDataset
        self.onClose = onClose
        self.qualityManager = qualityManager
        self.directImage = nil
        self.autoStartSegmentation = autoStartSegmentation
        self.onLabeledCountChanged = nil
    }
}

// MARK: - Save Success Overlay (deprecated - using ToastManager now)

struct SaveSuccessOverlay: View {
    let exportCount: Int
    @State private var checkmarkScale: CGFloat = 0
    @State private var checkmarkOpacity: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.3))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .scaleEffect(checkmarkScale)
                    .opacity(checkmarkOpacity)
            }
            Text("Saved to Dataset")
                .font(.headline)
                .foregroundColor(.primary)
            Text("\(exportCount) object\(exportCount == 1 ? "" : "s") exported")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
        )
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                checkmarkScale = 1
                checkmarkOpacity = 1
            }
        }
    }
}
