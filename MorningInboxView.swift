//
//  MorningInboxView.swift
//  Vision Builder
//
//  Batch review interface for labeling object clusters

import SwiftUI
import Photos

struct MorningInboxView: View {
    @State private var controller: ActiveLearningController
    @State private var clusterImages: [UUID: UIImage] = [:]
    @State private var isLoadingImages: Bool = false
    @State private var labelText: String = ""
    @State private var showingConfirmation: Bool = false
    @State private var confirmationLabel: String = ""
    @State private var confirmationCandidates: [SimilarInstance] = []
    @State private var showingDeleteAlert: Bool = false
    @State private var showingDeleteAllAlert: Bool = false
    @State private var isLoading: Bool = true

    // Keeps the keyboard up and the label field focused as you fly through
    // clusters — no tap-to-focus per cluster.
    @FocusState private var labelFieldFocused: Bool

    @Environment(\.dismiss) private var dismiss

    private let recognitionEngine: ObjectRecognitionEngine

    // Grid layout
    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 8)
    ]

    // Cap how many thumbnails we render/load per cluster. Labeling still applies
    // to every instance — this is only how many previews we show.
    private let maxThumbnails = 50

    init(recognitionEngine: ObjectRecognitionEngine) {
        self.recognitionEngine = recognitionEngine
        _controller = State(initialValue: ActiveLearningController(recognitionEngine: recognitionEngine))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress header
                clusterProgressHeader

                // Main content
                Group {
                    switch controller.state {
                    case .idle:
                        if isLoading {
                            loadingView
                        } else {
                            emptyStateView
                        }
                    case .labelingObject:
                        if let cluster = controller.currentCluster {
                            clusterReviewView(cluster: cluster)
                        }
                    case .confirmingMatches:
                        searchingView
                    case .applyingLabels:
                        applyingView
                    case .complete:
                        completeView
                    }
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { inboxTrailingMenu }
            .sheet(isPresented: $showingConfirmation) {
                ConfirmationView(
                    seedLabel: confirmationLabel,
                    candidates: confirmationCandidates,
                    onComplete: { result in
                        Task {
                            await controller.confirmationCompleted(label: confirmationLabel, result: result)
                            showingConfirmation = false
                        }
                    },
                    onCancel: {
                        showingConfirmation = false
                        Task { await controller.moveToNextCluster() }
                    }
                )
            }
            .alert("Delete Cluster?", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await deleteCurrentCluster() }
                }
            } message: {
                Text("Delete this cluster and all \(controller.currentCluster?.instances.count ?? 0) objects?")
            }
            .alert("Delete All?", isPresented: $showingDeleteAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete All", role: .destructive) {
                    Task { await deleteAllClusters() }
                }
            } message: {
                Text("Delete all unlabeled clusters?")
            }
        }
        .task {
            isLoading = true
            await controller.startWorkflow()
            isLoading = false
            // Load images for first cluster
            if let cluster = controller.currentCluster {
                await loadClusterImages(cluster)
                labelFieldFocused = true
            }
        }
        .onChange(of: controller.state) { _, newState in
            handleStateChange(newState)
        }
        .onChange(of: controller.currentCluster?.id) { _, _ in
            // Load images when cluster changes
            if let cluster = controller.currentCluster {
                Task { await loadClusterImages(cluster) }
                // Keep the keyboard up and refocus for the next cluster so
                // labeling is type → return → type → return, no tapping.
                labelFieldFocused = true
            }
        }
        .onChange(of: controller.smartName) { _, newName in
            // On-device LLM proposed a name — pre-fill it so you just hit return.
            // Never clobber what you're already typing.
            if let newName, labelText.isEmpty {
                labelText = newName
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var inboxTrailingMenu: some ToolbarContent {
        // Only surface "Delete All" when there are clusters to act on.
        let hasActiveCluster: Bool = {
            switch controller.state {
            case .labelingObject, .confirmingMatches: return true
            default: return false
            }
        }()
        if hasActiveCluster {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showingDeleteAllAlert = true
                    } label: {
                        Label("Delete All Clusters", systemImage: "trash.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Progress Header

    private var clusterProgressHeader: some View {
        let progress = controller.getProgress()
        let currentIndex = progress.labeled + 1
        let total = progress.total

        return VStack(spacing: 8) {
            HStack {
                // Cluster indicator
                VStack(alignment: .leading, spacing: 2) {
                    if total > 0 {
                        Text("Cluster \(currentIndex) of \(total)")
                            .font(.headline)
                            .foregroundStyle(
                                LinearGradient(colors: [.appOrange, .appPink], startPoint: .leading, endPoint: .trailing)
                            )

                        if let cluster = controller.currentCluster {
                            let depths = cluster.instances.compactMap { $0.depthMeters }
                            let avgDepth = depths.isEmpty ? nil : depths.reduce(0, +) / Double(depths.count)
                            Text(avgDepth == nil
                                 ? "\(cluster.instances.count) similar objects"
                                 : String(format: "%d similar objects · ~%.1fm away", cluster.instances.count, avgDepth!))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                // Progress ring
                if total > 0 {
                    ZStack {
                        Circle()
                            .stroke(Color.appOrange.opacity(0.2), lineWidth: 4)
                            .frame(width: 44, height: 44)

                        // Ring tracks review progress (labeled + skipped both count
                        // as "dealt with"); the completion screen splits them out
                        Circle()
                            .trim(from: 0, to: CGFloat(progress.labeled + progress.skipped) / CGFloat(max(1, total)))
                            .stroke(Color.appOrange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 44, height: 44)
                            .rotationEffect(.degrees(-90))

                        Text("\(Int(Float(progress.labeled + progress.skipped) / Float(max(1, total)) * 100))%")
                            .font(.caption2.bold())
                            .foregroundColor(.appOrange)
                    }
                }
            }

            // Progress bar
            if total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.appOrange.opacity(0.2))
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.appOrange)
                            .frame(width: geo.size.width * CGFloat(progress.labeled + progress.skipped) / CGFloat(max(1, total)), height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }

    // MARK: - Cluster Review View (Main Interface)

    private func clusterReviewView(cluster: UnlabeledCluster) -> some View {
        VStack(spacing: 0) {
            // Thumbnail grid — render only the instances we actually load a
            // preview for, plus a "+N more" tile so large clusters read as
            // intentional, not broken.
            let shownInstances = Array(cluster.instances.prefix(maxThumbnails))
            let hiddenCount = cluster.instances.count - shownInstances.count
            ScrollView {
                if cluster.instances.count > maxThumbnails {
                    Text("Showing \(shownInstances.count) of \(cluster.instances.count) — your label applies to all")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 12)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(shownInstances, id: \.id) { instance in
                        thumbnailView(for: instance)
                    }
                    if hiddenCount > 0 {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.appOrange.opacity(0.12))
                            .frame(width: 80, height: 80)
                            .overlay {
                                Text("+\(hiddenCount)")
                                    .font(.headline)
                                    .foregroundColor(.appOrange)
                            }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))

            // Bottom action bar
            VStack(spacing: 12) {
                // Auto-label suggestions
                if !controller.currentSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(controller.currentSuggestions) { suggestion in
                                // One tap on a suggestion labels the whole cluster
                                // and advances — the fast path. Type in the field
                                // below only when no suggestion fits.
                                Button {
                                    labelText = suggestion.label
                                    saveLabel()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "tag.fill")
                                            .font(.caption2)
                                        Text(suggestion.label)
                                            .font(.subheadline)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.appOrange.opacity(0.15))
                                    .cornerRadius(16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Label input — submit via return key OR the "Label All" button below.
                TextField("What are these objects?", text: $labelText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($labelFieldFocused)
                    .onSubmit { saveLabel() }

                // Three distinct actions: destroy / skip / label.
                // Delete is a small icon (low visual weight, destructive),
                // Skip is bordered (neutral), Label All is the prominent primary.
                HStack(spacing: 12) {
                    Button {
                        showingDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundColor(.red)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Delete cluster")

                    Button {
                        Task {
                            labelText = ""
                            clusterImages = [:]
                            // Must mark the cluster presented, otherwise the same
                            // cluster is re-selected and Skip does nothing.
                            await controller.skipCurrentCluster()
                        }
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        saveLabel()
                    } label: {
                        Label("Label All", systemImage: "tag.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appOrange)
                    .disabled(labelText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
            .background(
                Rectangle()
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.1), radius: 5, y: -2)
            )
        }
    }

    // MARK: - Thumbnail View

    private func thumbnailView(for instance: ObjectInstance) -> some View {
        Group {
            if let image = clusterImages[instance.id] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isLoadingImages {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 80, height: 80)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 80, height: 80)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    }
            }
        }
        // Distance badge — shows only on objects that came from a depth-tagged
        // (Portrait/LiDAR) photo, so you can see the free 3D labels landing.
        .overlay(alignment: .bottomTrailing) {
            if let depth = instance.depthMeters {
                Label(String(format: "%.1fm", depth), systemImage: "ruler")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(4)
            }
        }
    }

    // MARK: - Other Views

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading clusters...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(colors: [.appGreen, .appTeal], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(spacing: 8) {
                Text("All Caught Up!")
                    .font(.title2.bold())

                Text("No clusters to review. Scan your photo library to discover more objects.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                NotificationCenter.default.post(name: .switchToDatasetTab, object: nil)
                dismiss()
            } label: {
                Label("Go to Dataset", systemImage: "folder.fill")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.appOrange)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var searchingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.appOrange.opacity(0.2), lineWidth: 6)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.appOrange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))

                Image(systemName: "magnifyingglass")
                    .font(.title)
                    .foregroundColor(.appOrange)
            }

            Text("Finding similar objects...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var applyingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Applying labels...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var completeView: some View {
        let progress = controller.getProgress()
        let labeled = progress.labeled
        let skipped = progress.skipped
        let didLabelAnything = labeled > 0

        return VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.appGreen.opacity(0.3), .appTeal.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)

                Image(systemName: didLabelAnything ? "checkmark.circle.fill" : "tray")
                    .font(.system(size: 50))
                    .foregroundStyle(LinearGradient(colors: [.appGreen, .appTeal], startPoint: .topLeading, endPoint: .bottomTrailing))
            }

            VStack(spacing: 8) {
                Text(didLabelAnything ? "All Done!" : (skipped > 0 ? "Review Complete" : "Inbox is Empty"))
                    .font(.largeTitle.bold())

                Text(didLabelAnything
                     ? (skipped > 0
                        ? "Labeled \(labeled), skipped \(skipped) cluster\(skipped == 1 ? "" : "s")"
                        : "Labeled \(labeled) cluster\(labeled == 1 ? "" : "s")")
                     : (skipped > 0
                        ? "Skipped all \(skipped) clusters — nothing was labeled."
                        : "Scan your photo library from the Dataset tab to discover objects to label."))
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                NotificationCenter.default.post(name: .switchToDatasetTab, object: nil)
            } label: {
                Label(didLabelAnything ? "Back to Dataset" : "Go Scan Photos", systemImage: "folder.fill")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.appGreen)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Actions

    private func saveLabel() {
        let label = labelText.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }

        Task {
            await controller.objectLabeled(with: label)
            labelText = ""
            clusterImages = [:]
        }
    }

    private func deleteCurrentCluster() async {
        guard let cluster = controller.currentCluster else { return }
        do {
            try await recognitionEngine.deleteCluster(cluster)
            clusterImages = [:]
            await controller.moveToNextCluster()
        } catch {
            print("Error deleting cluster: \(error)")
        }
    }

    private func deleteAllClusters() async {
        do {
            try await recognitionEngine.deleteAllUnlabeledClusters()
            dismiss()
        } catch {
            print("Error deleting clusters: \(error)")
        }
    }

    private func handleStateChange(_ newState: ActiveLearningController.WorkflowState) {
        switch newState {
        case .confirmingMatches(let label, _):
            confirmationLabel = label
            confirmationCandidates = controller.getCurrentConfirmationCandidates()
            showingConfirmation = true
        default:
            break
        }
    }

    // MARK: - Image Loading

    private func loadClusterImages(_ cluster: UnlabeledCluster) async {
        isLoadingImages = true
        var loadedImages: [UUID: UIImage] = [:]

        // Load images for all instances in parallel (capped for performance —
        // matches the number of thumbnails the grid renders)
        let instancesToLoad = Array(cluster.instances.prefix(maxThumbnails))

        await withTaskGroup(of: (UUID, UIImage?).self) { group in
            for instance in instancesToLoad {
                group.addTask {
                    let image = await self.loadImage(for: instance)
                    return (instance.id, image)
                }
            }

            for await (id, image) in group {
                if let image = image {
                    loadedImages[id] = image
                }
            }
        }

        await MainActor.run {
            self.clusterImages = loadedImages
            self.isLoadingImages = false
        }
    }

    private func loadImage(for instance: ObjectInstance) async -> UIImage? {
        // Try cropImageData first
        if let cropData = instance.cropImageData,
           let image = UIImage(data: cropData),
           image.size.width > 10 && image.size.height > 10 {
            return image
        }

        // Try source path
        if let sourcePath = instance.sourceImagePath,
           let sourceImage = UIImage(contentsOfFile: sourcePath) {

            // Try to generate segmented preview
            if let contourPoints = instance.contourPoints, !contourPoints.isEmpty {
                if let segmented = SegmentedPreviewRenderer.generateSegmentedPreview(
                    from: sourceImage,
                    contourPoints: contourPoints,
                    backgroundColor: .white
                ) {
                    return segmented
                }
            }

            // Fall back to bounding box crop
            let bbox = instance.boundingBox.cgRect
            if let cropped = SegmentedPreviewRenderer.generateCroppedPreview(
                from: sourceImage,
                boundingBox: bbox
            ) {
                return cropped
            }
        }

        return nil
    }
}
