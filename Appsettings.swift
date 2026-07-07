//
//  AppSettings.swift
//  Vision Builder
//
//  Configuration for active learning and recognition parameters
//

import Foundation

/// Global configuration for active learning and object recognition
struct AppSettings {

    // MARK: - SAM2 Model Settings

    struct SAM2 {
        /// Model name for display purposes
        static let modelName = "SAM 2.1 Small"

        /// Input size for SAM2 models (always 1024x1024)
        static let inputSize: CGFloat = 1024

        /// Maximum number of auto-detected objects (user-facing; persisted)
        static var maxAutoDetections: Int {
            get { UserDefaults.standard.object(forKey: "settings.sam2.maxAutoDetections") as? Int ?? 5 }
            set { UserDefaults.standard.set(newValue, forKey: "settings.sam2.maxAutoDetections") }
        }

        /// Minimum detection area as fraction of image (0.005 = 0.5%)
        static var minDetectionArea: Float = 0.005

        /// Maximum detection area as fraction of image (0.95 = 95%)
        static var maxDetectionArea: Float = 0.95

        /// Overlap threshold for filtering duplicate detections (IoU)
        static var overlapThreshold: Float = 0.3
    }

    // MARK: - Active Learning Settings
    
    struct ActiveLearning {
        /// Number of "Yes" confirmations required before auto-accepting remaining candidates (user-facing; persisted)
        static var autoAcceptThreshold: Int {
            get { UserDefaults.standard.object(forKey: "settings.al.autoAcceptThreshold") as? Int ?? 3 }
            set { UserDefaults.standard.set(newValue, forKey: "settings.al.autoAcceptThreshold") }
        }

        /// Maximum number of candidates to show in confirmation flow
        static var maxCandidatesToShow: Int = 20

        /// Whether to automatically accept very high confidence matches (user-facing; persisted)
        static var enableAutoAccept: Bool {
            get { UserDefaults.standard.object(forKey: "settings.al.enableAutoAccept") as? Bool ?? true }
            set { UserDefaults.standard.set(newValue, forKey: "settings.al.enableAutoAccept") }
        }
    }
    
    // MARK: - Similarity Search Settings
    
    struct SimilaritySearch {
        /// Minimum cosine similarity threshold (0.0 to 1.0)
        /// Higher = more strict matching
        static var minSimilarityThreshold: Float = 0.85
        
        /// High confidence threshold for auto-labeling
        /// Matches above this are auto-accepted after threshold met
        static var highConfidenceThreshold: Float = 0.92
        
        /// Maximum number of candidates to retrieve from database
        static var maxCandidatePoolSize: Int = 50
        
        /// Whether to use contour shape similarity in addition to embeddings
        static var useContourSimilarity: Bool = false
        
        /// Weight for contour similarity (0.0 to 1.0) if enabled
        /// Final score = (embedding * (1-weight)) + (contour * weight)
        static var contourSimilarityWeight: Float = 0.2
    }
    
    // MARK: - Segmentation Settings
    
    struct Segmentation {
        /// Whether to cache segmented preview images
        /// true = faster UI, more storage
        /// false = less storage, more CPU
        static var cachePreviewImages: Bool = false
        
        /// Background color for segmented previews (hex string)
        static var previewBackgroundColor: String = "#FFFFFF"
        
        /// Padding around segmented objects in pixels
        static var boundingBoxPadding: CGFloat = 5.0
        
        /// Target size for cached preview images (if enabled)
        static var previewImageMaxDimension: CGFloat = 512
    }
    
    // MARK: - MobileCLIP Settings

    struct MobileCLIP {
        static let modelName = "MobileCLIP-S0"
        static let embeddingDimension = 512
        static let imageInputSize: CGFloat = 256

        /// Minimum text-image similarity for concept search results
        static var textSearchMinSimilarity: Float = 0.15

        /// Minimum confidence to show an auto-label suggestion
        static var autoLabelMinConfidence: Float = 0.10

        /// Number of auto-label suggestions to show
        static var autoLabelTopK: Int = 3
    }

    // MARK: - Clustering Settings

    struct Clustering {
        /// Minimum cluster size to show in Morning Inbox
        /// Smaller clusters may be noise
        static var minClusterSize: Int = 1
        
        /// Maximum cluster size before splitting
        static var maxClusterSize: Int = 100
        
        /// Distance threshold for DBSCAN clustering (euclidean on L2-normalized
        /// embeddings). 0.9 measured as the working value for MobileCLIP2 —
        /// 0.15 produced only singletons on real photos.
        static var dbscanEpsilon: Float = 0.9
        
        /// Minimum points for DBSCAN core
        static var dbscanMinPoints: Int = 2
    }
    
    // MARK: - UI Settings
    
    struct UI {
        /// Show similarity percentage in confirmation view (user-facing; persisted)
        static var showSimilarityScore: Bool {
            get { UserDefaults.standard.object(forKey: "settings.ui.showSimilarityScore") as? Bool ?? true }
            set { UserDefaults.standard.set(newValue, forKey: "settings.ui.showSimilarityScore") }
        }

        /// Enable haptic feedback on button presses (user-facing; persisted)
        static var enableHaptics: Bool {
            get { UserDefaults.standard.object(forKey: "settings.ui.enableHaptics") as? Bool ?? true }
            set { UserDefaults.standard.set(newValue, forKey: "settings.ui.enableHaptics") }
        }

        /// Animation duration for transitions (seconds)
        static var transitionDuration: Double = 0.3
    }
    
    // MARK: - Performance Settings
    
    struct Performance {
        /// Number of images to process in parallel during indexing
        static var indexingConcurrency: Int = 4
        
        /// Maximum memory for image cache (MB)
        static var imageCacheMaxSize: Int = 200
        
        /// Enable background processing
        static var enableBackgroundProcessing: Bool = true
    }
    
    // MARK: - Logging Settings
    
    struct Logging {
        /// Enable detailed logging
        static var enableVerboseLogging: Bool = true
        
        /// Log similarity scores
        static var logSimilarityScores: Bool = false
        
        /// Log timing information
        static var logTiming: Bool = true
    }
    
    // MARK: - Helper Methods
    
    /// Reset all settings to defaults
    static func resetToDefaults() {
        SAM2.maxAutoDetections = 5
        SAM2.minDetectionArea = 0.005
        SAM2.maxDetectionArea = 0.95
        SAM2.overlapThreshold = 0.3

        ActiveLearning.autoAcceptThreshold = 3
        ActiveLearning.maxCandidatesToShow = 20
        ActiveLearning.enableAutoAccept = true

        SimilaritySearch.minSimilarityThreshold = 0.85
        SimilaritySearch.highConfidenceThreshold = 0.92
        SimilaritySearch.maxCandidatePoolSize = 50
        SimilaritySearch.useContourSimilarity = false
        SimilaritySearch.contourSimilarityWeight = 0.2

        Segmentation.cachePreviewImages = false
        Segmentation.previewBackgroundColor = "#FFFFFF"
        Segmentation.boundingBoxPadding = 5.0
        Segmentation.previewImageMaxDimension = 512

        MobileCLIP.textSearchMinSimilarity = 0.15
        MobileCLIP.autoLabelMinConfidence = 0.10
        MobileCLIP.autoLabelTopK = 3

        Clustering.minClusterSize = 1
        Clustering.maxClusterSize = 100
        Clustering.dbscanEpsilon = 0.9
        Clustering.dbscanMinPoints = 2

        UI.showSimilarityScore = true
        UI.enableHaptics = true
        UI.transitionDuration = 0.3

        Performance.indexingConcurrency = 4
        Performance.imageCacheMaxSize = 200
        Performance.enableBackgroundProcessing = true

        Logging.enableVerboseLogging = true
        Logging.logSimilarityScores = false
        Logging.logTiming = true
    }
    
    /// Validate settings and fix any invalid values
    static func validateSettings() {
        // Clamp thresholds to valid ranges
        ActiveLearning.autoAcceptThreshold = max(1, min(10, ActiveLearning.autoAcceptThreshold))
        
        SimilaritySearch.minSimilarityThreshold = max(0.0, min(1.0, SimilaritySearch.minSimilarityThreshold))
        SimilaritySearch.highConfidenceThreshold = max(
            SimilaritySearch.minSimilarityThreshold,
            min(1.0, SimilaritySearch.highConfidenceThreshold)
        )
        
        Segmentation.boundingBoxPadding = max(0, min(20, Segmentation.boundingBoxPadding))
        
        Clustering.minClusterSize = max(1, Clustering.minClusterSize)
        Clustering.maxClusterSize = max(Clustering.minClusterSize, Clustering.maxClusterSize)
        
        Performance.indexingConcurrency = max(1, min(8, Performance.indexingConcurrency))
    }
}

// MARK: - Settings View

import SwiftUI

struct SettingsView: View {
    @State private var showResetConfirmation = false
    @State private var showDatabaseResetConfirmation = false
    @State private var showDatabaseResetSuccess = false
    @Environment(\.dismiss) private var dismiss

    // Same UserDefaults keys AppSettings reads — @AppStorage keeps the UI
    // live-updating while the engine sees the same persisted values
    @AppStorage("settings.sam2.maxAutoDetections") private var maxAutoDetections = 5
    @AppStorage("settings.al.enableAutoAccept") private var enableAutoAccept = true
    @AppStorage("settings.al.autoAcceptThreshold") private var autoAcceptThreshold = 3
    @AppStorage("settings.ui.showSimilarityScore") private var showSimilarityScore = true
    @AppStorage("settings.ui.enableHaptics") private var enableHaptics = true

    var body: some View {
        NavigationStack {
            List {
                // SAM2 Model Info
                Section {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(AppSettings.SAM2.modelName)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("High-quality segmentation model for precise object boundaries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Label("SAM2 Segmentation", systemImage: "wand.and.rays")
                }

                // MobileCLIP Info
                Section {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(AppSettings.MobileCLIP.modelName)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("Text-image matching for concept search and auto-labeling")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    NavigationLink {
                        MigrationSettingsView()
                    } label: {
                        Label("CLIP Embedding Migration", systemImage: "arrow.triangle.2.circlepath")
                    }
                } header: {
                    Label("MobileCLIP Intelligence", systemImage: "text.magnifyingglass")
                }

                // Detection Settings
                Section {
                    Stepper("Max Objects: \(maxAutoDetections)", value: $maxAutoDetections, in: 1...10)
                } header: {
                    Label("Detection", systemImage: "viewfinder")
                } footer: {
                    Text("How many objects Auto-Detect will find per photo before stopping.")
                }

                // Active Learning Settings
                Section {
                    Toggle("Auto-Accept High Confidence", isOn: $enableAutoAccept)

                    if enableAutoAccept {
                        Stepper("After \(autoAcceptThreshold) confirmations", value: $autoAcceptThreshold, in: 1...10)
                    }
                } header: {
                    Label("Active Learning", systemImage: "brain")
                } footer: {
                    Text("When enabled, very similar objects will be auto-labeled after you confirm a few matches.")
                }

                // UI Settings
                Section {
                    Toggle("Show Similarity Scores", isOn: $showSimilarityScore)
                    Toggle("Haptic Feedback", isOn: $enableHaptics)
                } header: {
                    Label("Interface", systemImage: "paintbrush")
                }

                // Reset Section
                Section {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset All Settings")
                        }
                    }

                    Button(role: .destructive) {
                        showDatabaseResetConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Reset Database")
                        }
                    }
                } footer: {
                    Text("Reset Database will clear all scanned objects, clusters, and labeling sessions. Use if you're experiencing database errors.")
                }

                // About Section
                Section {
                    LabeledContent("SAM2 Model", value: AppSettings.SAM2.modelName)
                    LabeledContent("Version", value: MainTabView.versionString)
                } header: {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Reset Settings?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    AppSettings.resetToDefaults()
                    maxAutoDetections = 5
                    enableAutoAccept = true
                    autoAcceptThreshold = 3
                    showSimilarityScore = true
                    enableHaptics = true
                }
            } message: {
                Text("This will reset all settings to their default values.")
            }
            .alert("Reset Database?", isPresented: $showDatabaseResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset Database", role: .destructive) {
                    ObjectRecognitionStorage.resetDatabase()
                    showDatabaseResetSuccess = true
                }
            } message: {
                Text("This will delete all scanned objects, clusters, and labeling sessions. The app will need to restart. This cannot be undone.")
            }
            .alert("Database Reset", isPresented: $showDatabaseResetSuccess) {
                Button("OK") {
                    // Force quit would be ideal, but we'll just dismiss
                    dismiss()
                }
            } message: {
                Text("Database has been reset. Please restart the app for changes to take effect.")
            }
        }
    }
}

// MARK: - Migration Settings View

struct MigrationSettingsView: View {
    @State private var isMigrating = false
    @State private var migrationProgress: Double = 0
    @State private var pendingCount: Int?
    @State private var migrationComplete = false

    private let migrationService = EmbeddingMigrationService()

    var body: some View {
        List {
            Section {
                if let count = pendingCount {
                    LabeledContent("Instances needing CLIP embedding", value: "\(count)")
                } else {
                    HStack {
                        Text("Checking...")
                        Spacer()
                        ProgressView()
                    }
                }
            } header: {
                Label("Status", systemImage: "info.circle")
            }

            Section {
                if isMigrating {
                    VStack(spacing: 8) {
                        ProgressView(value: migrationProgress)
                        Text(String(format: "%.0f%% complete", migrationProgress * 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if migrationComplete {
                    Label("Migration complete", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Button("Generate CLIP Embeddings") {
                        startMigration()
                    }
                    .disabled(pendingCount == nil || pendingCount == 0)
                }
            } header: {
                Label("Migration", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                Text("Generates MobileCLIP embeddings for existing objects so they can be found by text search.")
            }
        }
        .navigationTitle("CLIP Migration")
        .task {
            pendingCount = try? migrationService.pendingCount()
        }
    }

    private func startMigration() {
        isMigrating = true
        Task {
            try? await migrationService.migrateExistingInstances { progress in
                migrationProgress = progress.fraction
            }
            isMigrating = false
            migrationComplete = true
            pendingCount = try? migrationService.pendingCount()
        }
    }
}

#Preview {
    SettingsView()
}
