// LabelNavigationView.swift
// Redesigned Label tab with New/Resume/Camera options
import SwiftUI
import PhotosUI

struct LabelNavigationView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var datasetManager: DatasetManager
    @StateObject private var qualityManager = DataQualityManager()
    @StateObject private var sessionManager = SessionManager()

    // Navigation state
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var labelImages: [UIImage]?
    @State private var activeSession: LabelingSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerSection

                    // Quick Actions
                    quickActionsSection

                    // Resume Section (if incomplete sessions exist)
                    if !sessionManager.incompleteSessions.isEmpty {
                        resumeSection
                    }

                    // Recent Sessions
                    if !sessionManager.recentSessions.filter({ $0.isCompleted }).isEmpty {
                        recentSessionsSection
                    }
                }
                .padding()
            }
            .background(ThemedBackground(theme: .label))
            .navigationTitle("Label")
            .navigationBarTitleDisplayMode(.large)
            .task {
                sessionManager.refresh()
            }
            .sheet(isPresented: $showImagePicker) {
                ImageSelectorView { images in
                    showImagePicker = false
                    if let images, !images.isEmpty {
                        startNewSession(with: images)
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { image in
                    showCamera = false
                    if let image {
                        startNewSession(with: [image])
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { labelImages != nil },
                set: { if !$0 { labelImages = nil } }
            )) {
                if let images = labelImages {
                    LabelingFlowView(
                        images: images,
                        session: activeSession,
                        sessionManager: sessionManager,
                        qualityManager: qualityManager,
                        onComplete: {
                            labelImages = nil
                            activeSession = nil
                            sessionManager.completeSession()
                            selectedTab = 1 // Go to Dataset
                            Task {
                                await datasetManager.loadDataset()
                            }
                        },
                        onSaveProgress: {
                            labelImages = nil
                            activeSession = nil
                            ToastManager.shared.showSuccess("Session saved", message: "You can resume anytime")
                        }
                    )
                }
            }
        }
        .withToasts()
    }

    // MARK: - Header

    private var headerSection: some View {
        GradientHeaderCard(
            title: "Label Objects",
            subtitle: "Detect and label objects with SAM 2.1",
            icon: "tag.fill",
            gradient: TabTheme.label.headerGradient
        )
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(spacing: 12) {
            // Camera Button
            ActionCard(
                icon: "camera.fill",
                title: "Take Photo",
                subtitle: "Use camera to capture objects",
                color: .appBlue
            ) {
                showCamera = true
            }

            // Photo Library Button
            ActionCard(
                icon: "photo.on.rectangle.angled",
                title: "Choose from Library",
                subtitle: "Select multiple photos to label",
                color: .appGreen
            ) {
                showImagePicker = true
            }
        }
    }

    // MARK: - Resume Section

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(
                        LinearGradient(colors: [.appOrange, .appPink], startPoint: .leading, endPoint: .trailing)
                    )
                Text("Continue Where You Left Off")
                    .font(.headline)
                    .foregroundColor(.primary)
            }

            ForEach(sessionManager.incompleteSessions) { session in
                ResumeSessionCard(session: session) {
                    resumeSession(session)
                } onDelete: {
                    sessionManager.deleteSession(session)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.appOrange.opacity(0.05))
                )
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        )
    }

    // MARK: - Recent Sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(
                        LinearGradient(colors: [.appPurple, .appBlue], startPoint: .leading, endPoint: .trailing)
                    )
                Text("Recent Sessions")
                    .font(.headline)
            }

            ForEach(sessionManager.recentSessions.filter { $0.isCompleted }.prefix(3)) { session in
                RecentSessionRow(session: session)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.appPurple.opacity(0.03))
                )
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        )
    }

    // MARK: - Actions

    private func startNewSession(with images: [UIImage]) {
        let session = sessionManager.createSession(from: images)
        activeSession = session
        labelImages = images
    }

    private func resumeSession(_ session: LabelingSession) {
        sessionManager.resumeSession(session)
        activeSession = session

        // Load images from session
        var images: [UIImage] = []
        for data in session.cameraImageData {
            if let image = UIImage(data: data) {
                images.append(image)
            }
        }

        if images.isEmpty {
            ToastManager.shared.showError("Session corrupted", message: "Could not load images")
            sessionManager.deleteSession(session)
            return
        }

        labelImages = images
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(color)
                    .cornerRadius(12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.05), radius: 5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Resume Session Card

struct ResumeSessionCard: View {
    let session: LabelingSession
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Progress indicator
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                    .frame(width: 44, height: 44)

                Circle()
                    .trim(from: 0, to: session.progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(session.progress * 100))%")
                    .font(.caption2)
                    .fontWeight(.bold)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("\(session.remainingImages) images remaining")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Resume") {
                onResume()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }
}

// MARK: - Recent Session Row

struct RecentSessionRow: View {
    let session: LabelingSession

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.subheadline)

                Text("\(session.totalObjectsLabeled) objects labeled")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(session.lastModifiedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Camera View

struct CameraView: UIViewControllerRepresentable {
    let onComplete: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: (UIImage?) -> Void

        init(onComplete: @escaping (UIImage?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onComplete(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onComplete(nil)
        }
    }
}

// MARK: - Labeling Flow View (Sequential with progress)

struct LabelingFlowView: View {
    let images: [UIImage]
    let session: LabelingSession?
    let sessionManager: SessionManager
    let qualityManager: DataQualityManager
    let onComplete: () -> Void
    let onSaveProgress: () -> Void

    @State private var currentIndex: Int = 0
    @State private var totalLabeled: Int = 0
    @State private var showingExitConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Main labeling editor
            LabelingEditorView(
                image: images[currentIndex],
                onSelectNewPhoto: { },
                onBrowseDataset: { },
                onClose: {
                    advanceToNext()
                },
                qualityManager: qualityManager,
                autoStartSegmentation: true,
                onLabeledCountChanged: { count in
                    totalLabeled += count
                }
            )

            // Progress overlay
            VStack {
                progressHeader
                Spacer()
            }
        }
        .onAppear {
            // Resume from saved position
            if let session {
                currentIndex = session.currentImageIndex
                totalLabeled = session.totalObjectsLabeled
            }
        }
        .alert("Save Progress?", isPresented: $showingExitConfirmation) {
            Button("Discard", role: .destructive) {
                dismiss()
            }
            Button("Save & Exit") {
                saveAndExit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have \(images.count - currentIndex) images remaining. Save your progress to continue later?")
        }
    }

    private var progressHeader: some View {
        HStack {
            Button {
                showingExitConfirmation = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }

            Spacer()

            // Progress indicator
            VStack(spacing: 2) {
                Text("Image \(currentIndex + 1) of \(images.count)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)

                Text("\(totalLabeled) objects labeled")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5))
            .cornerRadius(20)

            Spacer()

            // Skip button
            Button {
                advanceToNext()
            } label: {
                Text("Skip")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(20)
            }
        }
        .padding()
        .padding(.top, 44) // Safe area
    }

    private func advanceToNext() {
        // Save progress
        sessionManager.saveProgress(
            index: currentIndex + 1,
            labeledCount: totalLabeled,
            boxes: []
        )

        if currentIndex + 1 < images.count {
            currentIndex += 1
        } else {
            onComplete()
        }
    }

    private func saveAndExit() {
        sessionManager.saveProgress(
            index: currentIndex,
            labeledCount: totalLabeled,
            boxes: []
        )
        onSaveProgress()
    }
}

#Preview {
    LabelNavigationView(selectedTab: .constant(0))
        .environmentObject(DatasetManager())
}
