import SwiftUI

/// Active Learning Interface - Batch label similar objects
struct ActiveLearningView: View {
    @StateObject private var manager = ActiveLearningManager()
    @Environment(\.dismiss) private var dismiss
    
    let initialSession: InitialSessionData
    
    struct InitialSessionData {
        let cluster: UnlabeledCluster?
        let identity: ObjectIdentity?
        let label: String
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundGradient()
                    .ignoresSafeArea()
                
                if manager.isProcessing {
                    processingOverlay
                } else if manager.currentSuggestions.isEmpty {
                    emptyStateView
                } else {
                    suggestionListView
                }
            }
            .navigationTitle("Active Learning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadSimilarObjects()
            }
        }
    }
    
    // MARK: - Processing Overlay
    
    private var processingOverlay: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.blue)
            
            VStack(spacing: 8) {
                Text(manager.currentOperation)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                
                if manager.progress > 0 {
                    ProgressView(value: manager.progress)
                        .frame(width: 200)
                }
            }
        }
        .padding(40)
        .glassStyle(variant: .regular, floating: true)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text("All Caught Up!")
                .font(.title2.bold())
            
            if let stats = manager.getSessionStats() {
                VStack(spacing: 8) {
                    Text("Session Complete")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 20) {
                        StatPill(value: "\(stats.labeledCount)", label: "Labeled", color: .green)
                        StatPill(value: "\(stats.skippedCount)", label: "Skipped", color: .orange)
                    }
                }
                .padding(.top, 8)
            }
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 12)
        }
        .padding()
    }
    
    // MARK: - Suggestion List
    
    private var suggestionListView: some View {
        VStack(spacing: 0) {
            // Header with stats
            sessionHeader
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            
            // Scrollable grid of suggestions
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    ForEach(manager.currentSuggestions) { suggestion in
                        SuggestionCard(
                            suggestion: suggestion,
                            isSelected: manager.selectedForLabeling.contains(suggestion.id),
                            onTap: {
                                manager.toggleSelection(for: suggestion.id)
                            }
                        )
                    }
                }
                .padding()
            }
            
            // Action buttons
            actionButtons
                .padding()
                .background(.ultraThinMaterial)
        }
    }
    
    private var sessionHeader: some View {
        VStack(spacing: 12) {
            if let session = manager.activeLearningSession {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Labeling as:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(session.proposedLabel)
                            .font(.headline.bold())
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(manager.currentSuggestions.count) similar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(manager.selectedForLabeling.count) selected")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                }
            }
            
            // Select all/none buttons
            HStack(spacing: 12) {
                Button("Select All") {
                    manager.selectAll()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                
                Button("Deselect All") {
                    manager.deselectAll()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                
                Spacer()
            }
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await manager.skipSelectedInstances()
                }
            } label: {
                Label("Skip", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(manager.selectedForLabeling.isEmpty)
            
            Button {
                Task {
                    try? await manager.labelSelectedInstances()
                }
            } label: {
                Label("Label \(manager.selectedForLabeling.count)", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.selectedForLabeling.isEmpty)
        }
    }
    
    // MARK: - Load Data
    
    private func loadSimilarObjects() async {
        do {
            if let cluster = initialSession.cluster {
                try await manager.startSessionFromCluster(cluster, label: initialSession.label)
            } else if let identity = initialSession.identity {
                try await manager.startSessionFromIdentity(identity)
            }
        } catch {
            print("Failed to start active learning: \(error)")
        }
    }
}

// MARK: - Suggestion Card

private struct SuggestionCard: View {
    let suggestion: ActiveLearningManager.SimilarInstance
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // Image
                if let image = suggestion.instance.cropImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 140)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        }
                }
                
                // Similarity score
                HStack {
                    Label {
                        Text("\(Int(suggestion.similarity * 100))%")
                            .font(.caption.bold())
                    } icon: {
                        Image(systemName: "waveform")
                            .font(.caption2)
                    }
                    .foregroundColor(similarityColor(suggestion.similarity))
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.white)
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func similarityColor(_ similarity: Float) -> Color {
        if similarity >= 0.9 {
            return .green
        } else if similarity >= 0.8 {
            return .blue
        } else {
            return .orange
        }
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.1))
        )
    }
}
