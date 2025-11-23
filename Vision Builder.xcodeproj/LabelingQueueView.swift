// LabelingQueueView.swift
// Lets users label a queue of images, one at a time, with intuitive navigation
import SwiftUI

struct LabelingQueueView: View {
    let images: [UIImage]
    let onFinish: () -> Void
    let qualityManager: DataQualityManager
    let onCancel: () -> Void

    @State private var currentIndex: Int = 0
    @State private var showLabelingEditor: Bool = false
    @State private var completed: [Bool]

    init(images: [UIImage], onFinish: @escaping () -> Void, qualityManager: DataQualityManager, onCancel: @escaping () -> Void) {
        self.images = images
        self.onFinish = onFinish
        self.qualityManager = qualityManager
        self.onCancel = onCancel
        _completed = State(initialValue: Array(repeating: false, count: images.count))
    }

    var body: some View {
        VStack {
            // Progress
            HStack {
                Text("Photo \(currentIndex + 1) of \(images.count)")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onCancel() }
                    .foregroundColor(.red)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Thumbnail strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                        let border = idx == currentIndex ? Color.blue : Color.gray.opacity(0.5)
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(border, lineWidth: 2)
                            )
                            .onTapGesture { currentIndex = idx }
                            .grayscale(completed[idx] ? 0 : 0.7)
                            .opacity(completed[idx] ? 1 : 0.7)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal)
            }

            // Main image
            Spacer()
            Image(uiImage: images[currentIndex])
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 360)
                .cornerRadius(12)
                .shadow(radius: 8, y: 4)
                .padding()
            Spacer()

            // Navigation
            HStack {
                if currentIndex > 0 {
                    Button("Previous") {
                        currentIndex -= 1
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button(completed[currentIndex] ? "Edit" : "Label") {
                    showLabelingEditor = true
                }
                .buttonStyle(.borderedProminent)
                .tint(completed[currentIndex] ? .orange : .blue)
                Spacer()
                if currentIndex < images.count - 1 {
                    Button("Next") {
                        currentIndex += 1
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Done") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(completed.contains(false))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showLabelingEditor) {
            LabelingEditorView(
                image: images[currentIndex],
                onSelectNewPhoto: {},
                onBrowseDataset: {},
                onClose: {
                    showLabelingEditor = false
                    completed[currentIndex] = true
                },
                qualityManager: qualityManager
            )
        }
    }
}
