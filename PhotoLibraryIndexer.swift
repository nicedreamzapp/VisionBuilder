//
//  PhotoLibraryIndexer.swift
//  Vision Builder
//

import UIKit
import Photos
import Vision
import SwiftData

actor EmbeddingQueue {
    private let service: EmbeddingService
    
    init(service: EmbeddingService) {
        self.service = service
    }
    
    func generateEmbedding(for image: UIImage) async throws -> ObjectEmbedding {
        try await service.generateEmbedding(for: image)
    }
}

class PhotoLibraryIndexer {
    private let sam2Processor: SAM2CoreMLProcessor
    private let embeddingService: EmbeddingService
    private let recognitionEngine: ObjectRecognitionEngine
    private let embeddingQueue: EmbeddingQueue
    private let mobileCLIP = MobileCLIPService()
    private let yoloDetector = YOLOObjectDetector()
    private var objectFilterLabels: [(String, [Float])] = []

    var onProgress: ((String, Double, Int, Int) -> Void)?
    var onPhotoProcessing: ((UIImage) -> Void)?
    var onObjectFound: ((UIImage, String?) -> Void)?
    private var _isCancelled = false
    private let cancelLock = NSLock()
    var isCancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _isCancelled }
        set { cancelLock.lock(); _isCancelled = newValue; cancelLock.unlock() }
    }
    private let maxPhotosToProcess = 200

    /// Key for storing processed photo IDs so we skip them on re-scan
    private static let processedPhotosKey = "processedPhotoAssetIDs"

    private static func getProcessedPhotoIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: processedPhotosKey) ?? [])
    }

    private static func markPhotoProcessed(_ assetID: String) {
        var ids = UserDefaults.standard.stringArray(forKey: processedPhotosKey) ?? []
        ids.append(assetID)
        UserDefaults.standard.set(ids, forKey: processedPhotosKey)
    }

    static func resetProcessedPhotos() {
        UserDefaults.standard.removeObject(forKey: processedPhotosKey)
    }

    /// Minimum CLIP similarity to any known object category to keep a detection.
    /// 0.20 = only keep things CLIP confidently recognizes as a real object.
    private let clipObjectThreshold: Float = 0.20

    init(
        sam2Processor: SAM2CoreMLProcessor,
        embeddingService: EmbeddingService,
        recognitionEngine: ObjectRecognitionEngine
    ) {
        self.sam2Processor = sam2Processor
        self.embeddingService = embeddingService
        self.recognitionEngine = recognitionEngine
        self.embeddingQueue = EmbeddingQueue(service: embeddingService)
    }
    
    func indexPhotoLibrary() async throws {
        print("🚀 Starting photo library indexing...")
        let startTime = Date()

        // YOLO handles object detection — no CLIP filter needed during scan

        // Check photo library permission
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("📱 Photo library permission status: \(status.rawValue)")

        if status == .notDetermined {
            print("📱 Requesting photo library permission...")
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            print("📱 Permission result: \(newStatus.rawValue)")
            if newStatus != .authorized && newStatus != .limited {
                print("❌ Photo library access denied")
                throw IndexerError.imageLoadFailed
            }
        } else if status != .authorized && status != .limited {
            print("❌ Photo library access not granted (status: \(status.rawValue))")
            throw IndexerError.imageLoadFailed
        }

        await MainActor.run {
            onProgress?("Loading photos...", 0, 0, maxPhotosToProcess)
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.fetchLimit = maxPhotosToProcess
        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        print("📊 Found \(allPhotos.count) photos to process (limit: \(maxPhotosToProcess))")
        
        await MainActor.run {
            onProgress?("Starting scan...", 0, 0, allPhotos.count)
        }
        
        // Filter out already-processed photos
        let alreadyProcessed = Self.getProcessedPhotoIDs()
        var assets: [PHAsset] = []
        allPhotos.enumerateObjects { asset, _, _ in
            if !alreadyProcessed.contains(asset.localIdentifier) {
                assets.append(asset)
            }
        }

        let skipped = allPhotos.count - assets.count
        if skipped > 0 {
            print("Skipping \(skipped) already-processed photos")
        }
        print("Processing \(assets.count) new photos...")

        if assets.isEmpty {
            await MainActor.run {
                onProgress?("All photos already scanned!", 1.0, 0, 0)
            }
            // Still run clustering in case previous scan was cancelled before clustering
            try await createClusters()
            return
        }

        var processedCount = 0
        var instancesCreated = 0
        isCancelled = false

        let storage = ObjectRecognitionStorage.shared
        let context = storage.context

        let batchSize = 20
        for (index, asset) in assets.enumerated() {
            if isCancelled {
                print("Scan cancelled. Saving \(instancesCreated) objects...")
                try await MainActor.run { try context.save() }
                break
            }

            do {
                let instances = try await processPhoto(asset: asset, context: context)
                instancesCreated += instances.count
                processedCount += 1
                Self.markPhotoProcessed(asset.localIdentifier)

                await MainActor.run {
                    let progress = Double(processedCount) / Double(assets.count)
                    self.onProgress?(
                        "Photo \(processedCount)/\(assets.count) — \(instancesCreated) objects",
                        progress,
                        processedCount,
                        assets.count
                    )
                }

                // Save every batch on main actor
                if processedCount % batchSize == 0 {
                    try await MainActor.run { try context.save() }
                    print("Batch saved: \(processedCount) photos, \(instancesCreated) objects")
                }
            } catch {
                print("Error processing photo: \(error)")
                Self.markPhotoProcessed(asset.localIdentifier)
            }
        }

        // Final save on main actor
        try await MainActor.run { try context.save() }
        let duration = Date().timeIntervalSince(startTime)
        print("Indexing \(isCancelled ? "stopped" : "complete"): \(processedCount) photos, \(instancesCreated) instances in \(String(format: "%.1f", duration))s")

        if isCancelled {
            // On cancel: save is done, skip clustering — instant stop
            await MainActor.run {
                onProgress?("Saved \(instancesCreated) objects", 1.0, processedCount, processedCount)
            }
            return
        }

        // Only cluster on full completion
        if instancesCreated > 0 {
            await MainActor.run {
                onProgress?("Grouping similar objects...", 0.95, processedCount, processedCount)
            }
            try await createClusters()
        }

        await MainActor.run {
            onProgress?("Done!", 1.0, processedCount, processedCount)
        }
    }
    
    private func processPhoto(asset: PHAsset, context: ModelContext) async throws -> [ObjectInstance] {
        print("🔍 Loading image...")

        guard let image = loadImage(from: asset) else {
            throw IndexerError.imageLoadFailed
        }

        // Show the photo being scanned in real-time
        await MainActor.run {
            onPhotoProcessing?(image)
        }

        print("✅ Image loaded: \(image.size)")

        // Pre-filter 1: Check if image is mostly text (screenshots, documents)
        let isTextHeavy = await isTextHeavyImage(image)
        if isTextHeavy {
            print("⏭️ Skipping image - text-heavy (screenshot/document)")
            return []
        }

        // Step 1: YOLO detects real objects (601 classes)
        print("Running YOLO 601-class detection...")
        let yoloDetections: [DetectedObject]
        do {
            yoloDetections = try await yoloDetector.detect(in: image)
        } catch {
            print("YOLO failed: \(error.localizedDescription), falling back to saliency")
            // Fallback to old saliency method
            let saliencyBoxes = await detectObjectsWithSAM2(in: image)
            guard !saliencyBoxes.isEmpty else { return [] }
            // Use old path for fallback
            return try await processWithLabeledBoxes(saliencyBoxes, image: image, asset: asset, context: context)
        }

        print("YOLO found \(yoloDetections.count) objects: \(yoloDetections.map { "\($0.className) \(String(format: "%.0f%%", $0.confidence * 100))" }.joined(separator: ", "))")

        guard !yoloDetections.isEmpty else {
            return []
        }

        let imageWidth = image.size.width
        let imageHeight = image.size.height
        var instances: [ObjectInstance] = []

        // Free depth: Portrait/depth-tagged photos carry a depth map we can sample
        // per object. Returns nil fast for ordinary photos (no extra fetch).
        let depthData = await PhotoDepthExtractor.loadDepthData(for: asset)

        for (index, detection) in yoloDetections.enumerated() {
            if isCancelled { break }
            print("  [\(index + 1)/\(yoloDetections.count)] \(detection.className) (\(String(format: "%.0f%%", detection.confidence * 100)))")

            // Crop directly from YOLO bounding box — clean, tight, fast
            let pixelRect = CGRect(
                x: detection.rect.origin.x * imageWidth,
                y: detection.rect.origin.y * imageHeight,
                width: detection.rect.width * imageWidth,
                height: detection.rect.height * imageHeight
            )

            // Add small padding (5%) for context
            let padW = pixelRect.width * 0.05
            let padH = pixelRect.height * 0.05
            let paddedRect = pixelRect.insetBy(dx: -padW, dy: -padH).intersection(
                CGRect(origin: .zero, size: image.size)
            )

            guard paddedRect.width >= 20, paddedRect.height >= 20,
                  let cgImage = image.cgImage,
                  let croppedCG = cgImage.cropping(to: paddedRect) else {
                print("    Crop failed, skipping")
                continue
            }

            let segmentedCrop = UIImage(cgImage: croppedCG)

            // Use YOLO box as contour points (for display consistency)
            let pixelContourPoints = [
                CGPoint(x: pixelRect.minX, y: pixelRect.minY),
                CGPoint(x: pixelRect.maxX, y: pixelRect.minY),
                CGPoint(x: pixelRect.maxX, y: pixelRect.maxY),
                CGPoint(x: pixelRect.minX, y: pixelRect.maxY)
            ]

            // Generate VNFeaturePrint embedding only — skip MobileCLIP during scan to save memory
            // CLIP embeddings can be added later via Settings → CLIP Migration
            let embedding = try await embeddingQueue.generateEmbedding(for: segmentedCrop)

            let instance = ObjectInstance(
                embedding: embedding.vector,
                boundingBox: BoundingBox(from: pixelRect),
                contourPoints: pixelContourPoints,
                detectionConfidence: detection.confidence,
                imageQuality: 0.8
            )
            instance._setCropUIImage(segmentedCrop)
            instance.sourceImagePath = saveImageToDocuments(image, assetID: asset.localIdentifier)

            // Sample depth at the object's center (normalized YOLO coords).
            if let depthData {
                instance.depthMeters = PhotoDepthExtractor.depthMeters(
                    atNormalizedPoint: CGPoint(x: detection.rect.midX, y: detection.rect.midY),
                    in: depthData
                )
            }

            await MainActor.run {
                context.insert(instance)
            }
            instances.append(instance)

            // Notify UI with YOLO class name
            await MainActor.run {
                onObjectFound?(segmentedCrop, detection.className)
            }

            print("    Saved: \(detection.className)")
        }

        print("Created \(instances.count) instances from \(yoloDetections.count) YOLO detections")
        return instances
    }

    /// Run SAM2 on a single point to get precise segmentation contours.
    private func runSAM2AtPoint(_ point: CGPoint, in image: UIImage) async -> LabeledBox? {
        let manager = SAM2DetectionManager()
        await MainActor.run { sam2Processor.manager = manager }

        await sam2Processor.performSAM2TapDetection(
            at: point,
            in: image,
            imageViewBounds: CGRect(origin: .zero, size: image.size)
        )

        // Wait briefly for SAM2 to finish
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let boxes = await manager.getDetectedBoxes()
            if !boxes.isEmpty { return boxes.first }
            if !(await manager.isStillProcessing()) { break }
        }
        return await manager.getDetectedBoxes().first
    }

    /// Fallback: process using old LabeledBox method (saliency-based)
    private func processWithLabeledBoxes(_ boxes: [LabeledBox], image: UIImage, asset: PHAsset, context: ModelContext) async throws -> [ObjectInstance] {
        let imageWidth = image.size.width
        let imageHeight = image.size.height
        var instances: [ObjectInstance] = []

        for box in boxes {
            guard let normalizedContourPoints = box.contourPoints, !normalizedContourPoints.isEmpty else { continue }
            let pixelContourPoints = normalizedContourPoints.map { CGPoint(x: $0.x * imageWidth, y: $0.y * imageHeight) }
            guard let segmentedCrop = SegmentedPreviewRenderer.generateSegmentedPreview(from: image, contourPoints: pixelContourPoints, backgroundColor: .white),
                  segmentedCrop.size.width >= 10, segmentedCrop.size.height >= 10 else { continue }

            let embedding = try await embeddingQueue.generateEmbedding(for: segmentedCrop)
            let clipEmbedding = try? await mobileCLIP.generateImageEmbedding(for: segmentedCrop)
            let pixelRect = CGRect(x: box.rect.origin.x * imageWidth, y: box.rect.origin.y * imageHeight, width: box.rect.width * imageWidth, height: box.rect.height * imageHeight)

            let instance = ObjectInstance(embedding: embedding.vector, boundingBox: BoundingBox(from: pixelRect), contourPoints: pixelContourPoints, detectionConfidence: 0.9, imageQuality: 0.8)
            instance.clipEmbedding = clipEmbedding
            instance._setCropUIImage(segmentedCrop)
            instance.sourceImagePath = saveImageToDocuments(image, assetID: asset.localIdentifier)
            context.insert(instance)
            instances.append(instance)
        }
        return instances
    }
    
    private func detectObjectsWithSAM2(in image: UIImage) async -> [LabeledBox] {
        // Create a temporary manager to capture results
        let manager = SAM2DetectionManager()

        await MainActor.run {
            sam2Processor.manager = manager
        }

        // Run auto-detection (this is async and updates manager when done)
        await sam2Processor.performAutoEverythingDetection(in: image)

        // Wait for processing to complete - check periodically
        var waitCount = 0
        let maxWaits = 20 // 10 seconds max
        while await manager.isStillProcessing() && waitCount < maxWaits {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            waitCount += 1
        }

        // Get the detected boxes
        let boxes = await manager.getDetectedBoxes()
        print("📦 SAM2 returned \(boxes.count) boxes after \(waitCount * 500)ms wait")

        return boxes
    }
    
    private func saveImageToDocuments(_ image: UIImage, assetID: String) -> String? {
        let fileManager = FileManager.default
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let cleanID = assetID.replacingOccurrences(of: "/", with: "_")
        let filename = "\(cleanID).jpg"
        let filepath = documentsPath.appendingPathComponent(filename)
        
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: filepath)
            return filepath.path
        }
        return nil
    }
    
    private func createClusters() async throws {
        print("Creating clusters...")

        let instances: [ObjectInstance] = try await MainActor.run {
            let storage = ObjectRecognitionStorage.shared
            let context = storage.context
            let descriptor = FetchDescriptor<ObjectInstance>(
                predicate: #Predicate { instance in
                    instance.identity == nil
                }
            )
            return try context.fetch(descriptor)
        }

        guard !instances.isEmpty else {
            print("No instances to cluster")
            return
        }

        print("Clustering \(instances.count) instances...")
        let clusters = performDBSCANClustering(on: instances)
        print("Created \(clusters.count) clusters")

        try await MainActor.run {
            let context = ObjectRecognitionStorage.shared.context
            for cluster in clusters {
                cluster.selectRepresentative()
                context.insert(cluster)
            }
            try context.save()
        }
        print("Clusters saved")
    }
    
    private func performDBSCANClustering(on instances: [ObjectInstance]) -> [UnlabeledCluster] {
        print("🔍 Starting DBSCAN clustering on \(instances.count) instances...")
        
        // ADJUSTED PARAMETERS for better separation
        let epsilon: Float = 0.15  // Reduced from 0.25 - stricter similarity requirement
        let minPoints = 2
        
        var clusters: [UnlabeledCluster] = []
        var visited = Set<UUID>()
        var clusteredInstances = Set<UUID>()
        
        for instance in instances {
            if visited.contains(instance.id) {
                continue
            }
            visited.insert(instance.id)
            
            let neighbors = findNeighbors(of: instance, in: instances, epsilon: epsilon)
            
            if neighbors.count >= minPoints {
                var clusterMembers = [instance]
                clusteredInstances.insert(instance.id)
                var neighborQueue = neighbors
                
                while !neighborQueue.isEmpty {
                    let neighbor = neighborQueue.removeFirst()
                    
                    if !visited.contains(neighbor.id) {
                        visited.insert(neighbor.id)
                        let neighborNeighbors = findNeighbors(of: neighbor, in: instances, epsilon: epsilon)
                        if neighborNeighbors.count >= minPoints {
                            neighborQueue.append(contentsOf: neighborNeighbors)
                        }
                    }
                    
                    if !clusteredInstances.contains(neighbor.id) {
                        clusterMembers.append(neighbor)
                        clusteredInstances.insert(neighbor.id)
                    }
                }
                
                let centroid = calculateCentroid(of: clusterMembers)
                let cluster = UnlabeledCluster(
                    instances: clusterMembers,
                    centroidEmbedding: centroid
                )
                cluster.clipCentroidEmbedding = calculateClipCentroid(of: clusterMembers)

                print("  Created cluster with \(clusterMembers.count) instances")
                clusters.append(cluster)
            }
        }
        
        // Add singleton clusters for unclustered instances
        let unclusteredInstances = instances.filter { !clusteredInstances.contains($0.id) }
        print("  🔸 Found \(unclusteredInstances.count) unclustered instances (singletons)")
        
        for instance in unclusteredInstances {
            let cluster = UnlabeledCluster(
                instances: [instance],
                centroidEmbedding: instance.embedding
            )
            cluster.clipCentroidEmbedding = instance.clipEmbedding
            clusters.append(cluster)
        }
        
        print("✅ DBSCAN complete: \(clusters.count) total clusters")
        print("  - Multi-instance clusters: \(clusters.filter { $0.instances.count > 1 }.count)")
        print("  - Singleton clusters: \(clusters.filter { $0.instances.count == 1 }.count)")
        
        return clusters
    }
    
    private func findNeighbors(
        of instance: ObjectInstance,
        in instances: [ObjectInstance],
        epsilon: Float
    ) -> [ObjectInstance] {
        let embedding = instance.embedding
        var neighbors: [ObjectInstance] = []
        
        for candidate in instances {
            if candidate.id == instance.id {
                continue
            }
            let distance = euclideanDistance(embedding, candidate.embedding)
            if distance <= epsilon {
                neighbors.append(candidate)
            }
        }
        return neighbors
    }
    
    private func calculateCentroid(of instances: [ObjectInstance]) -> [Float] {
        guard !instances.isEmpty else { return [] }
        
        let embeddings = instances.map { $0.embedding }
        guard let firstEmbedding = embeddings.first else {
            return []
        }
        
        let dimension = firstEmbedding.count
        var centroid = [Float](repeating: 0.0, count: dimension)
        
        for embedding in embeddings {
            for i in 0..<dimension {
                centroid[i] += embedding[i]
            }
        }
        
        let count = Float(embeddings.count)
        for i in 0..<dimension {
            centroid[i] /= count
        }
        
        let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<dimension {
                centroid[i] /= norm
            }
        }
        
        return centroid
    }
    
    /// Pre-compute text embeddings for common object categories.
    /// Used to filter out garbage detections during scanning.
    private func warmUpObjectFilter() async {
        guard objectFilterLabels.isEmpty else { return }
        let labels = [
            "shoe", "car", "phone", "cup", "bottle", "bag", "book", "laptop",
            "watch", "glasses", "plant", "food", "clothing", "furniture", "animal",
            "person", "face", "toy", "tool", "key", "pen", "ball", "hat",
            "camera", "guitar", "bicycle", "chair", "table", "dog", "cat",
            "bird", "fish", "flower", "fruit", "vegetable", "drink", "box",
            "sign", "building", "vehicle", "electronics", "jewelry", "makeup",
            "art", "decoration", "kitchen item", "bathroom item", "sports equipment"
        ]
        do {
            try await mobileCLIP.ensureModelsLoaded()
            for label in labels {
                if let emb = try? await mobileCLIP.generateTextEmbedding(for: label) {
                    objectFilterLabels.append((label, emb))
                }
            }
            print("Object filter warmed up: \(objectFilterLabels.count) categories")
        } catch {
            print("Object filter warmup failed: \(error.localizedDescription)")
        }
    }

    /// Check if a CLIP embedding matches any known object category.
    /// Returns the best matching label and score, or nil if it's garbage.
    private func identifyObject(clipEmbedding: [Float]) -> (label: String, score: Float)? {
        guard !objectFilterLabels.isEmpty else { return nil }
        var bestLabel = ""
        var bestScore: Float = 0
        for (label, textEmb) in objectFilterLabels {
            let sim = MobileCLIPService.cosineSimilarity(clipEmbedding, textEmb)
            if sim > bestScore {
                bestScore = sim
                bestLabel = label
            }
        }
        return bestScore >= clipObjectThreshold ? (bestLabel, bestScore) : nil
    }

    private func calculateClipCentroid(of instances: [ObjectInstance]) -> [Float]? {
        let clipEmbeddings = instances.compactMap { $0.clipEmbedding }
        guard let first = clipEmbeddings.first, !first.isEmpty else { return nil }
        let dim = first.count
        var centroid = [Float](repeating: 0, count: dim)
        for emb in clipEmbeddings {
            for i in 0..<dim { centroid[i] += emb[i] }
        }
        let count = Float(clipEmbeddings.count)
        centroid = centroid.map { $0 / count }
        let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { centroid = centroid.map { $0 / norm } }
        return centroid
    }

    private func loadImage(from asset: PHAsset) -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = true
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false  // Skip iCloud photos to avoid hangs

        var resultImage: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 640, height: 640),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            resultImage = image
        }

        return resultImage
    }
    
    private func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return Float.infinity }
        var sum: Float = 0.0
        for i in 0..<a.count {
            let diff = a[i] - b[i]
            sum += diff * diff
        }
        return sqrt(sum)
    }
}

// Add helper extension for SAM2DetectionManager
extension SAM2DetectionManager {
    func getDetectedBoxes() async -> [LabeledBox] {
        await MainActor.run {
            return self.detectedBoxes
        }
    }

    func isStillProcessing() async -> Bool {
        await MainActor.run {
            return self.isProcessing
        }
    }
}

// MARK: - Vision Saliency Detection

extension PhotoLibraryIndexer {
    /// Check image saliency using Vision framework
    /// Returns a score from 0-1 indicating how much salient content the image has
    func checkImageSaliency(_ image: UIImage) async -> Float {
        guard let cgImage = image.cgImage else {
            return 0
        }

        return await withCheckedContinuation { continuation in
            let request = VNGenerateAttentionBasedSaliencyImageRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNSaliencyImageObservation],
                      let observation = results.first else {
                    continuation.resume(returning: 0)
                    return
                }

                // Get salient objects - check if there are any distinct salient regions
                guard let salientObjects = observation.salientObjects, !salientObjects.isEmpty else {
                    // No distinct objects found - image might be uniform or abstract
                    continuation.resume(returning: 0.1)
                    return
                }

                // Calculate score based on:
                // 1. Number of salient objects (more distinct objects = better)
                // 2. Total area covered by salient regions
                // 3. Confidence of detections

                var totalArea: Float = 0
                var maxConfidence: Float = 0

                for obj in salientObjects {
                    let area = Float(obj.boundingBox.width * obj.boundingBox.height)
                    totalArea += area
                    maxConfidence = max(maxConfidence, obj.confidence)
                }

                // Penalize images where saliency covers too much (likely just a gradient or texture)
                let areaPenalty: Float = totalArea > 0.8 ? 0.5 : 1.0

                // Score based on having distinct objects with good coverage
                let objectScore = min(1.0, Float(salientObjects.count) * 0.2) // Up to 5 objects = full score
                let coverageScore = min(1.0, totalArea * 2.0) // 50% coverage = full score
                let confidenceScore = maxConfidence

                let finalScore = (objectScore * 0.3 + coverageScore * 0.4 + confidenceScore * 0.3) * areaPenalty

                continuation.resume(returning: finalScore)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("⚠️ Saliency detection error: \(error)")
                continuation.resume(returning: 0.5) // Default to processing on error
            }
        }
    }

    /// Additional filter: Check if image is mostly text (screenshots, documents)
    func isTextHeavyImage(_ image: UIImage) async -> Bool {
        guard let cgImage = image.cgImage else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: false)
                    return
                }

                // If more than 15 text regions, it's likely a text-heavy image (screenshot/document)
                // This helps filter out screenshots, documents, receipts etc.
                // while allowing photos that happen to have some text (signs, labels)
                let textRegionCount = results.count
                let isTextHeavy = textRegionCount > 15

                if isTextHeavy {
                    print("📝 Skipping: \(textRegionCount) text regions detected (screenshot/document)")
                }

                continuation.resume(returning: isTextHeavy)
            }

            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

enum IndexerError: Error {
    case imageLoadFailed
    case sam2ProcessingFailed
    case embeddingGenerationFailed
    case clusteringFailed
}
