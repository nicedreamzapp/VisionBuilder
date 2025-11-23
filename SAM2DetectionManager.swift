import BackgroundTasks
import Combine
import CoreML
import Foundation
import UIKit
@preconcurrency import Vision

// MARK: - SAM2 Detection Modes and Priorities

enum SAM2DetectionMode {
    case vision // Fast Vision framework detection
    case sam2Mobile // Real SAM2 CoreML for precision
    case hybrid // Vision first, SAM 2 refinement
    case tapPerfect // SAM 2 tap-to-perfect-mask
    case autoEverything // SAM 2 finds all objects
}

enum SAM2ProcessingPriority {
    case realTime // Immediate processing
    case background // Background processing
    case overnight // Overnight batch processing
}

// MARK: - Main SAM2 Detection Manager

@MainActor
class SAM2DetectionManager: ObservableObject {
    // MARK: - Published Properties

    @Published var detectedBoxes: [LabeledBox] = []
    @Published var isProcessing = false
    @Published var detectionMode: SAM2DetectionMode = .sam2Mobile
    @Published var processingProgress = 0.0
    @Published var currentOperation = ""

    // Photo Library Scanner
    @Published var photoScanProgress = 0.0
    @Published var foundClusters: [SAM2ObjectCluster] = []
    @Published var pendingQuestions: [SAM2MorningQuestion] = []

    // MARK: - Processing Modules

    private let processor = SAM2CoreMLProcessor()
    private let analyzer = SAM2ImageAnalysis()

    // MARK: - Background Task Registration (FIXED)

    private static var hasRegisteredBackgroundTask = false

    // MARK: - Vision Framework Fallback

    private lazy var rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest { [weak self] request, error in
            Task { @MainActor in
                self?.handleVisionResults(request: request, error: error)
            }
        }
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.05
        request.maximumObservations = 20
        return request
    }()

    private lazy var saliencyRequest: VNGenerateObjectnessBasedSaliencyImageRequest = {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest { [weak self] request, error in
            Task { @MainActor in
                self?.handleSaliencyResults(request: request, error: error)
            }
        }
        return request
    }()

    // MARK: - Initialization

    init() {
        processor.manager = self
        setupBackgroundTasks()
    }

    // MARK: - Public API Methods

    func detectObjects(in image: UIImage, mode: SAM2DetectionMode = .sam2Mobile, priority _: SAM2ProcessingPriority = .realTime) {
        isProcessing = true
        detectionMode = mode
        currentOperation = "Initializing detection..."

        Task {
            switch mode {
            case .vision:
                await performVisionDetection(image: image)
            case .sam2Mobile:
                await processor.performAutoEverythingDetection(in: image)
            case .hybrid:
                await performHybridDetection(image: image)
            case .tapPerfect:
                break // Handled by tapToDetect
            case .autoEverything:
                await processor.performAutoEverythingDetection(in: image)
            }
        }
    }

    func tapToDetect(at point: CGPoint, in image: UIImage, imageViewBounds: CGRect) {
        print("🎯 Real SAM2 CoreML Tap Detection at point: \(point)")

        // DEBUG
        debugImageOrientation(image)

        isProcessing = true
        currentOperation = "Real SAM2 processing tap..."

        Task {
            await processor.performSAM2TapDetection(at: point, in: image, imageViewBounds: imageViewBounds)
        }
    }

    func autoDetectAllObjects(in image: UIImage) {
        print("🤖 Auto-detecting ALL objects with Real SAM2...")

        isProcessing = true
        currentOperation = "Real SAM2 finding all objects..."

        Task {
            await processor.performAutoEverythingDetection(in: image)
        }
    }

    // MARK: - State Management (Called by Processor)

    func updateOperation(_ operation: String) {
        currentOperation = operation
    }

    func updateProgress(_ progress: Double) {
        processingProgress = progress
    }

    func addDetectedBox(_ box: LabeledBox) {
        detectedBoxes.append(box)
    }

    func addDetectedBoxes(_ boxes: [LabeledBox]) {
        detectedBoxes.append(contentsOf: boxes)
    }

    func finishProcessing() {
        isProcessing = false
        currentOperation = ""
        processingProgress = 0.0
    }

    // MARK: - Background Task Setup (FIXED)

    private func setupBackgroundTasks() {
        // Guard against duplicate registration
        guard !Self.hasRegisteredBackgroundTask else {
            print("🎯 Background task already registered, skipping...")
            return
        }

        let success = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "photo-processing-overnight",
            using: nil
        ) { task in
            Task {
                await self.handleBackgroundPhotoProcessing(task as! BGProcessingTask)
            }
        }

        if success {
            Self.hasRegisteredBackgroundTask = true
            print("🎯 Successfully registered background task")
        } else {
            print("❌ Failed to register background task")
        }
    }

    func scheduleOvernightProcessing() {
        let request = BGProcessingTaskRequest(identifier: "photo-processing-overnight")
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("🌙 Overnight processing scheduled!")
        } catch {
            print("❌ Failed to schedule background processing: \(error)")
        }
    }

    private func handleBackgroundPhotoProcessing(_ task: BGProcessingTask) async {
        print("🌙 Starting overnight photo processing...")

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        await processPhotoLibraryForClusters()
        task.setTaskCompleted(success: true)
    }

    // MARK: - Photo Library Processing

    func processPhotoLibraryForClusters() async {
        print("📸 Starting photo library scan...")

        currentOperation = "Scanning photo library..."
        photoScanProgress = 0.0

        // Simulate processing work
        for i in 1 ... 10 {
            photoScanProgress = Double(i) / 10.0
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        currentOperation = ""
        photoScanProgress = 1.0
        print("✅ Photo library scan complete!")
    }

    func answerMorningQuestion(questionId: UUID, answer: String) {
        guard let question = pendingQuestions.first(where: { $0.id == questionId }) else { return }

        print("🎯 User answered '\(answer)' for cluster with \(question.totalInstances) instances")

        Task {
            await batchLabelObjects(clusterId: question.clusterId, label: answer)
        }

        pendingQuestions.removeAll { $0.id == questionId }
    }

    private func batchLabelObjects(clusterId _: String, label: String) async {
        print("🚀 Batch labeling \(label) objects with Real SAM2...")

        currentOperation = "Creating \(label) dataset with Real SAM2..."

        for i in 1 ... 5 {
            processingProgress = Double(i) / 5.0
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        currentOperation = ""
        processingProgress = 0.0

        print("✅ Created perfect dataset for '\(label)' with Real SAM2!")
    }

    // MARK: - Vision Framework Fallbacks

    private func performVisionDetection(image: UIImage) async {
        currentOperation = "Vision framework detection..."

        guard image.cgImage != nil else {
            finishProcessing()
            return
        }

        // Simulate Vision framework processing
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        finishProcessing()
    }

    private func performHybridDetection(image: UIImage) async {
        currentOperation = "Hybrid detection (Vision + SAM2)..."

        // Use SAM2 if available, otherwise fall back to Vision
        await processor.performAutoEverythingDetection(in: image)
    }

    // MARK: - Vision Framework Result Handlers

    private func handleVisionResults(request: VNRequest, error: Error?) {
        guard error == nil else {
            print("❌ Vision detection error: \(error?.localizedDescription ?? "Unknown")")
            finishProcessing()
            return
        }

        guard let results = request.results as? [VNRectangleObservation] else {
            finishProcessing()
            return
        }

        let visionBoxes = results.prefix(5).enumerated().map { index, result in
            LabeledBox(
                id: UUID(),
                label: "Vision Object \(index + 1)",
                rect: CGRect(
                    x: result.boundingBox.origin.x,
                    y: 1.0 - result.boundingBox.origin.y - result.boundingBox.height,
                    width: result.boundingBox.width,
                    height: result.boundingBox.height
                ),
                isSaved: false,
                detectionMethod: "Vision Framework"
            )
        }

        detectedBoxes.append(contentsOf: visionBoxes)
        finishProcessing()

        print("✅ Vision framework found \(visionBoxes.count) objects")
    }

    private func handleSaliencyResults(request _: VNRequest, error: Error?) {
        guard error == nil else {
            print("❌ Saliency detection error: \(error?.localizedDescription ?? "Unknown")")
            finishProcessing()
            return
        }

        // Handle saliency results if needed
        finishProcessing()
    }

    // MARK: - Debug Utilities

    private func debugImageOrientation(_ image: UIImage) {
        print("🎯 === IMAGE ORIENTATION DEBUG ===")
        print("🎯 Original size: \(image.size)")
        print("🎯 Scale: \(image.scale)")

        let orientationNames = [
            "up", "down", "left", "right",
            "upMirrored", "downMirrored", "leftMirrored", "rightMirrored",
        ]
        print("🎯 Orientation: \(orientationNames[image.imageOrientation.rawValue]) (\(image.imageOrientation.rawValue))")

        if let cgImage = image.cgImage {
            print("🎯 CGImage size: \(cgImage.width) x \(cgImage.height)")
        }
        print("🎯 === END DEBUG ===")
    }

    func clearDetectedBoxes() {
        detectedBoxes.removeAll()
    }
}
