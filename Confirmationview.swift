//
//  ConfirmationView.swift
//  Vision Builder
//

import SwiftUI
import Photos

struct ConfirmationView: View {
    let seedLabel: String
    let candidates: [SimilarInstance]
    let onComplete: (ConfirmationResult) -> Void
    let onCancel: () -> Void
    
    @State private var currentIndex: Int = 0
    @State private var acceptedInstances: [ObjectInstance] = []
    @State private var rejectedInstances: [ObjectInstance] = []
    @State private var isLoading: Bool = false
    @State private var currentImage: UIImage?
    @State private var autoAccepted: [ObjectInstance] = []
    
    @Environment(\.dismiss) private var dismiss
    
    private let autoAcceptThreshold = AppSettings.ActiveLearning.autoAcceptThreshold
    private let similarityService = SimilaritySearchService()
    
    private var currentCandidate: SimilarInstance? {
        guard currentIndex < candidates.count else { return nil }
        return candidates[currentIndex]
    }
    
    private var progress: Float {
        let total = candidates.count
        guard total > 0 else { return 1.0 }
        return Float(currentIndex) / Float(total)
    }
    
    private var shouldAutoAccept: Bool {
        acceptedInstances.count >= autoAcceptThreshold
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerView
                progressView
                
                if isLoading {
                    loadingView
                } else if let candidate = currentCandidate {
                    candidateView(candidate)
                } else {
                    completionView
                }
                
                if currentCandidate != nil {
                    controlsView
                }
            }
            .navigationTitle("Confirm Matches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        finishConfirmation()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
        .onAppear {
            loadCurrentCandidateImage()
            checkForAutoAccept()
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Is this the same object?")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Looking for: \(seedLabel)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                Label("\(acceptedInstances.count) confirmed", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                
                Label("\(rejectedInstances.count) rejected", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                
                if !autoAccepted.isEmpty {
                    Label("\(autoAccepted.count) auto-accepted", systemImage: "sparkles")
                        .foregroundColor(.blue)
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
    private var progressView: some View {
        VStack(spacing: 4) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            
            Text("\(currentIndex + 1) of \(candidates.count)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }
    
    private func candidateView(_ candidate: SimilarInstance) -> some View {
        VStack(spacing: 16) {
            if let image = currentImage,
               let contourPoints = candidate.instance.contourPoints,
               !contourPoints.isEmpty {
                
                if let segmentedImage = SegmentedPreviewRenderer.generateSegmentedPreview(
                    from: image,
                    contourPoints: contourPoints,
                    backgroundColor: .white
                ) {
                    Image(uiImage: segmentedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 400)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .shadow(radius: 4)
                } else {
                    placeholderView
                }
            } else {
                placeholderView
            }
            
            if AppSettings.UI.showSimilarityScore {
                HStack {
                    Text("Similarity:")
                        .foregroundColor(.secondary)
                    Text("\(Int(candidate.similarity * 100))%")
                        .fontWeight(.semibold)
                        .foregroundColor(similarityColor(candidate.similarity))
                }
                .font(.subheadline)
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.systemGray5))
            .frame(height: 400)
            .overlay {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading image...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading next candidate...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var completionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text("Review Complete!")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 8) {
                Text("✅ \(acceptedInstances.count) confirmed")
                Text("❌ \(rejectedInstances.count) rejected")
                if !autoAccepted.isEmpty {
                    Text("✨ \(autoAccepted.count) auto-accepted")
                }
            }
            .font(.body)
            .foregroundColor(.secondary)
            
            Button("Finish") {
                finishConfirmation()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var controlsView: some View {
        HStack(spacing: 20) {
            Button {
                handleRejection()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                    Text("No")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.red.opacity(0.1))
                .foregroundColor(.red)
                .cornerRadius(12)
            }
            
            Button {
                handleAcceptance()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                    Text("Yes")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.green.opacity(0.1))
                .foregroundColor(.green)
                .cornerRadius(12)
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
    private func handleAcceptance() {
        guard let candidate = currentCandidate else { return }
        acceptedInstances.append(candidate.instance)
        moveToNext()
        checkForAutoAccept()
    }
    
    private func handleRejection() {
        guard let candidate = currentCandidate else { return }
        rejectedInstances.append(candidate.instance)
        moveToNext()
    }
    
    private func moveToNext() {
        currentIndex += 1
        currentImage = nil
        if currentIndex < candidates.count {
            loadCurrentCandidateImage()
        }
    }
    
    private func checkForAutoAccept() {
        guard shouldAutoAccept else { return }
        let remaining = candidates.suffix(from: currentIndex)
        let result = similarityService.splitCandidatesForAutoAccept(
            candidates: Array(remaining),
            confirmedCount: acceptedInstances.count,
            autoAcceptThreshold: autoAcceptThreshold
        )
        if !result.autoAccepted.isEmpty {
            autoAccepted = result.autoAccepted.map { $0.instance }
            currentIndex = candidates.count

            // Show auto-accept notification
            let avgSimilarity = result.autoAccepted.reduce(0.0) { $0 + $1.similarity } / Float(result.autoAccepted.count)
            ToastManager.shared.showAutoAccept(
                count: autoAccepted.count,
                label: seedLabel,
                confidence: avgSimilarity
            )
        }
    }

    private func finishConfirmation() {
        let result = ConfirmationResult(
            acceptedInstances: acceptedInstances,
            rejectedInstances: rejectedInstances,
            autoAcceptedInstances: autoAccepted
        )

        // Show summary toast
        let totalAccepted = acceptedInstances.count + autoAccepted.count
        if totalAccepted > 0 {
            ToastManager.shared.showSuccess(
                "Labeled \(totalAccepted) objects as '\(seedLabel)'",
                message: autoAccepted.isEmpty ? nil : "\(autoAccepted.count) were auto-accepted"
            )
        }

        onComplete(result)
    }
    
    private func loadCurrentCandidateImage() {
        guard let candidate = currentCandidate else { return }
        isLoading = true
        
        if let sourcePath = candidate.instance.sourceImagePath {
            loadImageFromPath(sourcePath)
        } else {
            isLoading = false
        }
    }
    
    private func loadImageFromPath(_ path: String) {
        if let image = UIImage(contentsOfFile: path) {
            DispatchQueue.main.async {
                self.currentImage = image
                self.isLoading = false
            }
        } else {
            isLoading = false
        }
    }
    
    private func similarityColor(_ similarity: Float) -> Color {
        if similarity >= 0.95 {
            return .green
        } else if similarity >= 0.90 {
            return .blue
        } else if similarity >= 0.85 {
            return .orange
        } else {
            return .red
        }
    }
}
