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

        /// Maximum number of auto-detected objects
        static var maxAutoDetections: Int = 5

        /// Minimum detection area as fraction of image (0.005 = 0.5%)
        static var minDetectionArea: Float = 0.005

        /// Maximum detection area as fraction of image (0.95 = 95%)
        static var maxDetectionArea: Float = 0.95

        /// Overlap threshold for filtering duplicate detections (IoU)
        static var overlapThreshold: Float = 0.3
    }

    // MARK: - Active Learning Settings
    
    struct ActiveLearning {
        /// Number of "Yes" confirmations required before auto-accepting remaining candidates
        static var autoAcceptThreshold: Int = 3
        
        /// Maximum number of candidates to show in confirmation flow
        static var maxCandidatesToShow: Int = 20
        
        /// Whether to automatically accept very high confidence matches
        static var enableAutoAccept: Bool = true
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
    
    // MARK: - Clustering Settings
    
    struct Clustering {
        /// Minimum cluster size to show in Morning Inbox
        /// Smaller clusters may be noise
        static var minClusterSize: Int = 1
        
        /// Maximum cluster size before splitting
        static var maxClusterSize: Int = 100
        
        /// Distance threshold for DBSCAN clustering
        static var dbscanEpsilon: Float = 0.15
        
        /// Minimum points for DBSCAN core
        static var dbscanMinPoints: Int = 2
    }
    
    // MARK: - UI Settings
    
    struct UI {
        /// Show similarity percentage in confirmation view
        static var showSimilarityScore: Bool = true
        
        /// Enable haptic feedback on button presses
        static var enableHaptics: Bool = true
        
        /// Animation duration for transitions (seconds)
        static var transitionDuration: Double = 0.3
        
        /// Show debug information in UI
        static var showDebugInfo: Bool = false
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

        Clustering.minClusterSize = 1
        Clustering.maxClusterSize = 100
        Clustering.dbscanEpsilon = 0.15
        Clustering.dbscanMinPoints = 2

        UI.showSimilarityScore = true
        UI.enableHaptics = true
        UI.transitionDuration = 0.3
        UI.showDebugInfo = false

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

                // Detection Settings
                Section {
                    Stepper("Max Objects: \(AppSettings.SAM2.maxAutoDetections)",
                            value: Binding(
                                get: { AppSettings.SAM2.maxAutoDetections },
                                set: { AppSettings.SAM2.maxAutoDetections = $0 }
                            ),
                            in: 1...10)
                } header: {
                    Label("Detection", systemImage: "viewfinder")
                }

                // Active Learning Settings
                Section {
                    Toggle("Auto-Accept High Confidence",
                           isOn: Binding(
                               get: { AppSettings.ActiveLearning.enableAutoAccept },
                               set: { AppSettings.ActiveLearning.enableAutoAccept = $0 }
                           ))

                    if AppSettings.ActiveLearning.enableAutoAccept {
                        Stepper("After \(AppSettings.ActiveLearning.autoAcceptThreshold) confirmations",
                                value: Binding(
                                    get: { AppSettings.ActiveLearning.autoAcceptThreshold },
                                    set: { AppSettings.ActiveLearning.autoAcceptThreshold = $0 }
                                ),
                                in: 1...10)
                    }
                } header: {
                    Label("Active Learning", systemImage: "brain")
                } footer: {
                    Text("When enabled, very similar objects will be auto-labeled after you confirm a few matches.")
                }

                // UI Settings
                Section {
                    Toggle("Show Similarity Scores",
                           isOn: Binding(
                               get: { AppSettings.UI.showSimilarityScore },
                               set: { AppSettings.UI.showSimilarityScore = $0 }
                           ))

                    Toggle("Haptic Feedback",
                           isOn: Binding(
                               get: { AppSettings.UI.enableHaptics },
                               set: { AppSettings.UI.enableHaptics = $0 }
                           ))

                    Toggle("Debug Mode",
                           isOn: Binding(
                               get: { AppSettings.UI.showDebugInfo },
                               set: { AppSettings.UI.showDebugInfo = $0 }
                           ))
                } header: {
                    Label("Interface", systemImage: "paintbrush")
                }

                // Performance Settings
                Section {
                    Toggle("Background Processing",
                           isOn: Binding(
                               get: { AppSettings.Performance.enableBackgroundProcessing },
                               set: { AppSettings.Performance.enableBackgroundProcessing = $0 }
                           ))

                    Stepper("Parallel Tasks: \(AppSettings.Performance.indexingConcurrency)",
                            value: Binding(
                                get: { AppSettings.Performance.indexingConcurrency },
                                set: { AppSettings.Performance.indexingConcurrency = $0 }
                            ),
                            in: 1...8)
                } header: {
                    Label("Performance", systemImage: "gauge.with.needle")
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
                    LabeledContent("Version", value: "1.0.0")
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

#Preview {
    SettingsView()
}
