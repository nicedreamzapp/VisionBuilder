//
//  BirdsEyeView.swift
//  Vision Builder
//
//  Bird's-eye mosaic of the whole dataset: every labeled object crop on one
//  zoomable wall. Pinch (or slider) changes density; tap a label chip to
//  filter to that label. The "how big is my dataset really" view.
//

import SwiftUI
import UIKit

struct BirdsEyeView: View {
    @EnvironmentObject var datasetManager: DatasetManager
    @Environment(\.dismiss) private var dismiss

    @State private var columns: CGFloat = 5
    @State private var pinchBase: CGFloat = 5
    @State private var filterLabel: String? = nil

    private var allImages: [(image: DatasetImage, label: String)] {
        datasetManager.labelFolders.flatMap { folder in
            folder.images.map { ($0, folder.name) }
        }
        .filter { filterLabel == nil || $0.1 == filterLabel }
    }

    private var labelNames: [String] {
        datasetManager.labelFolders.map(\.name)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                legendStrip

                ScrollView {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: max(2, Int(columns)))
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(allImages, id: \.image.id) { item in
                            MosaicTile(filepath: item.image.filepath, label: item.label,
                                       color: Self.labelColor(item.label))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .padding(2)
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            // zoom in = fewer, bigger tiles
                            columns = min(9, max(2, pinchBase / value))
                        }
                        .onEnded { _ in pinchBase = columns }
                )
            }
            .navigationTitle(filterLabel ?? "Bird's Eye")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(allImages.count) objects")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .task {
                if datasetManager.labelFolders.isEmpty {
                    await datasetManager.loadDataset()
                }
            }
            .overlay {
                if allImages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text(filterLabel == nil ? "No labeled objects yet" : "Nothing labeled '\(filterLabel!)'")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var legendStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: nil, title: "All")
                ForEach(labelNames, id: \.self) { name in
                    chip(label: name, title: name)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func chip(label: String?, title: String) -> some View {
        let selected = filterLabel == label
        return Button {
            withAnimation(.snappy) { filterLabel = label }
        } label: {
            HStack(spacing: 6) {
                if let label {
                    Circle().fill(Self.labelColor(label)).frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.caption.weight(selected ? .bold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    /// Stable per-label color from the label text itself
    static func labelColor(_ label: String) -> Color {
        var hash: UInt64 = 5381
        for b in label.utf8 { hash = hash &* 33 &+ UInt64(b) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.65, brightness: 0.85)
    }
}

// MARK: - Tile with downsampled thumbnail

private struct MosaicTile: View {
    let filepath: String
    let label: String
    let color: Color

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.primary.opacity(0.05))
            }
        }
        .clipped()
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(color)
                .frame(height: 3)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .contentShape(Rectangle())
        .task(id: filepath) {
            thumbnail = await Self.loadThumbnail(path: filepath)
        }
    }

    /// Downsample on a background thread — full-res tiles at mosaic density
    /// would blow memory on big datasets
    static func loadThumbnail(path: String, side: CGFloat = 160) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side * 2,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

#Preview {
    BirdsEyeView().environmentObject(DatasetManager())
}
