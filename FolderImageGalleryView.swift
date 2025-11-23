import SwiftUI

private struct GalleryImageCell: View {
    let image: UIImage
    let folderName: String
    let score: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 150, height: 150)
                    .cornerRadius(10)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.appBlue.opacity(0.15), lineWidth: 2)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(folderName)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.black.opacity(0.5))
                        )
                    if let score = score {
                        Label("\(score)%", systemImage: score >= 70 ? "star.fill" : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .labelStyle(.titleOnly)
                            .padding(4)
                            .background(
                                Capsule().fill((score >= 90 ? Color.green : (score >= 70 ? Color.blue : (score >= 50 ? Color.orange : Color.red))).opacity(0.85))
                            )
                    }
                }
                .padding(6)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct FolderImageGalleryView: View {
    let folder: LabelFolder
    @Environment(\.dismiss) private var dismiss
    @StateObject private var qualityManager = DataQualityManager()
    @State private var selectedImage: DatasetImage?
    @State private var showEditor = false
    @State private var qualityScores: [String: Int] = [:]
    @State private var showQualityView = false

    var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(folder.images) { image in
                            if let uiImage = UIImage(contentsOfFile: image.filepath) {
                                GalleryImageCell(
                                    image: uiImage,
                                    folderName: folder.name,
                                    score: qualityScores[image.filepath],
                                    onTap: {
                                        selectedImage = image
                                        showEditor = true
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                // Quality Footer
                Button(action: { showQualityView = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle.magnifyingglass")
                        Text("Check Quality")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(Color.appBlue)
                    )
                }
                .glassStyle(variant: .regular, floating: true)
                .padding(.vertical, 14)
            }
            .navigationTitle("\(folder.name) Images")
            .navigationBarItems(trailing:
                Button("Done") { dismiss() }
                    .glassStyle(variant: .regular, floating: true, tint: .blue)
            )
            .background(AppBackgroundGradient().ignoresSafeArea())
            .sheet(isPresented: $showEditor) {
                if let image = selectedImage {
                    LabelingEditorView(
                        datasetImage: image,
                        onSelectNewPhoto: {},
                        onBrowseDataset: { dismiss() },
                        onClose: { showEditor = false },
                        qualityManager: qualityManager,
                        directImage: nil,
                        autoStartSegmentation: false,
                        onLabeledCountChanged: nil
                    )
                }
            }
            .sheet(isPresented: $showQualityView) {
                QualityView()
            }
            .task {
                // Precompute quality scores for each image in the folder
                var scores: [String: Int] = [:]
                for image in folder.images {
                    let url = URL(fileURLWithPath: image.filepath)
                    let score = await qualityManager.getAverageQualityScore(for: url.deletingLastPathComponent())
                    if let score = score {
                        scores[image.filepath] = score
                    }
                }
                qualityScores = scores
            }
        }
        .glassStyle(variant: .regular, floating: true)
    }
}
