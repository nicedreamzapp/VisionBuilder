//
//  DatasetTabView.swift
//  Vision Builder - Dataset browsing and management
//

import SwiftUI

struct DatasetTabView: View {
    @EnvironmentObject var exportManager: ExportManager
    @EnvironmentObject var datasetManager: DatasetManager
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var selectedFolder: LabelFolder?
    @State private var showingExportOptions = false
    @State private var showingDeleteConfirmation = false
    @State private var folderToDelete: LabelFolder?

    // Background indexing
    @State private var photoIndexer: PhotoLibraryIndexer?
    @State private var isIndexing = false
    @State private var indexingProgress: Double = 0
    @State private var indexingOperation = ""

    var filteredFolders: [LabelFolder] {
        if searchText.isEmpty {
            return datasetManager.labelFolders
        }
        return datasetManager.labelFolders.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if datasetManager.isLoading {
                    loadingView
                } else if datasetManager.labelFolders.isEmpty {
                    emptyStateView
                } else {
                    datasetContentView
                }
            }
            .navigationTitle("Dataset")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task { await refreshDataset() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button {
                            showingExportOptions = true
                        } label: {
                            Label("Export All", systemImage: "square.and.arrow.up")
                        }
                        .disabled(datasetManager.labelFolders.isEmpty)

                        Divider()

                        Button {
                            Task { await startBackgroundIndexing() }
                        } label: {
                            Label("Scan Photo Library", systemImage: "photo.stack")
                        }
                        .disabled(isIndexing)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search labels")
            .refreshable {
                await refreshDataset()
            }
            .task {
                if datasetManager.labelFolders.isEmpty {
                    await datasetManager.loadDataset()
                }
                initializeIndexer()
            }
            .sheet(isPresented: $showingExportOptions) {
                ExportOptionsView(exportManager: exportManager, isPresented: $showingExportOptions)
                    .environmentObject(datasetManager)
            }
            .navigationDestination(item: $selectedFolder) { folder in
                FolderDetailView(folder: folder)
                    .environmentObject(datasetManager)
            }
            .alert("Delete Label?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { folderToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let folder = folderToDelete {
                        deleteFolder(folder)
                    }
                }
            } message: {
                if let folder = folderToDelete {
                    Text("Delete '\(folder.name)' and all \(folder.objectCount) objects? This cannot be undone.")
                }
            }
        }
        .withToasts()
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading dataset...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ZStack {
            ThemedBackground(theme: .dataset)

            VStack(spacing: 24) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(colors: [.appGreen, .appTeal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                VStack(spacing: 8) {
                    Text("No Labels Yet")
                        .font(.title2.bold())

                    Text("Scan your photo library to discover objects, then label them to build your dataset.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 12) {
                    // Primary action: Scan
                    Button {
                        Task { await startBackgroundIndexing() }
                    } label: {
                        Label("Scan Photo Library", systemImage: "photo.stack")
                            .frame(maxWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appGreen)
                    .disabled(isIndexing)

                    // Secondary: Manual labeling
                    Button {
                        NotificationCenter.default.post(name: .switchToLabelTab, object: nil)
                    } label: {
                        Label("Manual Labeling", systemImage: "hand.tap")
                            .frame(maxWidth: 220)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    // MARK: - Dataset Content

    private var datasetContentView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Colorful Header
                GradientHeaderCard(
                    title: "Your Dataset",
                    subtitle: "\(datasetManager.labelFolders.count) labels, \(datasetManager.totalObjectCount) objects",
                    icon: "folder.fill",
                    gradient: TabTheme.dataset.headerGradient
                )

                // Prominent Scan Button
                if !isIndexing {
                    scanPhotoLibraryButton
                }

                // Indexing Progress (if active)
                if isIndexing {
                    indexingProgressCard
                }

                // Stats Header
                statsHeader

                // Folder Grid
                folderGrid
            }
            .padding()
        }
        .background(ThemedBackground(theme: .dataset))
    }

    // MARK: - Scan Button

    private var scanPhotoLibraryButton: some View {
        Button {
            Task { await startBackgroundIndexing() }
        } label: {
            HStack {
                Image(systemName: "photo.stack.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Photo Library")
                        .font(.headline)
                    Text("Find new objects to label")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .foregroundColor(.white)
            .padding()
            .background(
                LinearGradient(
                    colors: [.appGreen, .appTeal],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(12)
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: 12) {
            AccentStatCard(
                icon: "tag.fill",
                value: "\(datasetManager.labelFolders.count)",
                label: "Labels",
                accentColor: .appBlue
            )

            AccentStatCard(
                icon: "square.on.square",
                value: "\(datasetManager.totalObjectCount)",
                label: "Objects",
                accentColor: .appGreen
            )
        }
    }

    // MARK: - Folder Grid

    private var folderGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            ForEach(filteredFolders) { folder in
                FolderGridCard(folder: folder)
                    .onTapGesture {
                        selectedFolder = folder
                    }
                    .contextMenu {
                        Button {
                            selectedFolder = folder
                        } label: {
                            Label("Open", systemImage: "folder")
                        }

                        Button(role: .destructive) {
                            folderToDelete = folder
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    // MARK: - Indexing Progress Card

    private var indexingProgressCard: some View {
        VStack(spacing: 12) {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning Photos")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    isIndexing = false
                }
                .font(.caption)
            }

            VStack(spacing: 4) {
                ProgressView(value: indexingProgress)
                    .progressViewStyle(.linear)

                Text(indexingOperation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5)
    }

    // MARK: - Actions

    private func refreshDataset() async {
        isRefreshing = true
        await datasetManager.loadDataset()
        isRefreshing = false
    }

    private func deleteFolder(_ folder: LabelFolder) {
        datasetManager.deleteFolder(folder)
        ToastManager.shared.showSuccess("Deleted '\(folder.name)'")
        folderToDelete = nil
    }

    private func initializeIndexer() {
        guard photoIndexer == nil else { return }
        let sam2 = SAM2CoreMLProcessor()
        let embedding = EmbeddingService()
        let engine = ObjectRecognitionEngine()
        photoIndexer = PhotoLibraryIndexer(
            sam2Processor: sam2,
            embeddingService: embedding,
            recognitionEngine: engine
        )
        photoIndexer?.onProgress = { operation, progress, _, _ in
            Task { @MainActor in
                self.indexingOperation = operation
                self.indexingProgress = progress
            }
        }
    }

    private func startBackgroundIndexing() async {
        guard let indexer = photoIndexer else { return }

        isIndexing = true
        indexingProgress = 0
        indexingOperation = "Starting scan..."

        do {
            try await indexer.indexPhotoLibrary()
            ToastManager.shared.showSuccess("Photo scan complete")
        } catch {
            ToastManager.shared.showError("Scan failed", message: error.localizedDescription)
        }

        isIndexing = false
        await refreshDataset()
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.03), radius: 3)
    }
}

// MARK: - Folder Grid Card

struct FolderGridCard: View {
    let folder: LabelFolder
    @State private var thumbnailImage: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            // Thumbnail or placeholder
            ZStack {
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 100)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .frame(height: 100)
                        .overlay(
                            Image(systemName: "photo.stack")
                                .font(.title)
                                .foregroundColor(.gray)
                        )
                }

                // Object count badge
                VStack {
                    HStack {
                        Spacer()
                        Text("\(folder.objectCount)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(8)
            }
            .cornerRadius(8)

            // Label name
            Text(folder.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // Load first image as thumbnail
        guard let firstImage = folder.images.first else { return }
        let path = firstImage.filepath

        if FileManager.default.fileExists(atPath: path),
           let image = UIImage(contentsOfFile: path) {
            await MainActor.run {
                thumbnailImage = image
            }
        }
    }
}

// MARK: - Notification for Tab Switching

extension Notification.Name {
    static let switchToLabelTab = Notification.Name("switchToLabelTab")
    static let switchToDatasetTab = Notification.Name("switchToDatasetTab")
}

#Preview {
    DatasetTabView()
        .environmentObject(ExportManager())
        .environmentObject(DatasetManager())
}
