// FolderDetailView.swift
// Displays all images in a label folder as a thumbnail grid
import SwiftUI

struct FolderDetailView: View {
    let folder: LabelFolder
    @EnvironmentObject var datasetManager: DatasetManager

    @State private var images: [DatasetImage] = []
    @State private var isLoading = true
    @State private var selectedIndex: Int?
    @State private var showingDeleteConfirmation = false

    let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            if isLoading {
                loadingView
            } else if images.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        Task { await loadImages() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Label", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadImages()
        }
        .alert("Delete '\(folder.name)'?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                datasetManager.deleteFolder(folder)
                ToastManager.shared.showSuccess("Deleted '\(folder.name)'")
            }
        } message: {
            Text("This will permanently delete all \(folder.objectCount) objects. This cannot be undone.")
        }
        .fullScreenCover(item: Binding(
            get: { selectedIndex.map { ImageViewerIndex(id: $0) } },
            set: { selectedIndex = $0?.id }
        )) { index in
            ImageViewerSheet(
                images: images,
                currentIndex: index.id,
                onDismiss: { selectedIndex = nil }
            )
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading images...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text("No Images")
                .font(.headline)

            Text("This label folder is empty")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Content View

    private var contentView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(Array(images.enumerated()), id: \.1.id) { index, image in
                    ThumbnailCell(image: image, index: index) {
                        selectedIndex = index
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Load Images

    private func loadImages() async {
        isLoading = true

        // Use DatasetManager to load images
        await datasetManager.loadImagesForFolder(folder)
        images = datasetManager.datasetImages

        isLoading = false
    }
}

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let image: DatasetImage
    let index: Int
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: 100, height: 100)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 100, height: 100)
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.8)
                        )
                }
            }
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 3)
        }
        .buttonStyle(.plain)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard FileManager.default.fileExists(atPath: image.filepath) else { return }

        await MainActor.run {
            thumbnail = UIImage(contentsOfFile: image.filepath)
        }
    }
}

// MARK: - Image Viewer Index

struct ImageViewerIndex: Identifiable {
    let id: Int
}

// MARK: - Image Viewer Sheet

struct ImageViewerSheet: View {
    let images: [DatasetImage]
    @State var currentIndex: Int
    let onDismiss: () -> Void

    @State private var currentImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .gesture(
                            DragGesture()
                                .onEnded { value in
                                    if value.translation.width < -50 && currentIndex < images.count - 1 {
                                        currentIndex += 1
                                        loadImage()
                                    } else if value.translation.width > 50 && currentIndex > 0 {
                                        currentIndex -= 1
                                        loadImage()
                                    }
                                }
                        )
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("Image \(currentIndex + 1) of \(images.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.8), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        onDismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            if currentIndex > 0 {
                                currentIndex -= 1
                                loadImage()
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(currentIndex == 0)

                        Button {
                            if currentIndex < images.count - 1 {
                                currentIndex += 1
                                loadImage()
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(currentIndex >= images.count - 1)
                    }
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        guard currentIndex < images.count else { return }
        let path = images[currentIndex].filepath

        Task {
            let image = UIImage(contentsOfFile: path)
            await MainActor.run {
                currentImage = image
            }
        }
    }
}

#Preview {
    NavigationStack {
        FolderDetailView(folder: LabelFolder(name: "Test", path: "/test"))
            .environmentObject(DatasetManager())
    }
}
