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
    private let maxPhotosToProcess = 1000  // Scan up to 1000 photos for meaningful clusters

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

        // Pre-compute CLIP object categories for smart filtering
        await warmUpObjectFilter()

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
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = maxPhotosToProcess
        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        print("📊 Found \(allPhotos.count) photos to process (limit: \(maxPhotosToProcess))")
        
        await MainActor.run {
            onProgress?("Starting scan...", 0, 0, allPhotos.count)
        }
        
        var assets: [PHAsset] = []
        allPhotos.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        
        print("📋 Processing \(assets.count) assets...")
        
        var processedCount = 0
        var instancesCreated = 0
        
        // Get SwiftData context
        let storage = ObjectRecognitionStorage.shared
        let context = storage.context
        
        for (index, asset) in assets.enumerated() {
            do {
                print("\n--- Photo \(index + 1)/\(assets.count) ---")
                let instances = try await processPhoto(asset: asset, context: context)
                instancesCreated += instances.count
                processedCount += 1
                
                await MainActor.run {
                    let progress = Double(processedCount) / Double(assets.count)
                    self.onProgress?(
                        "Processing photo \(processedCount) of \(assets.count)...",
                        progress,
                        processedCount,
                        assets.count
                    )
                }
                
                if processedCount % 10 == 0 {
                    print("📸 Processed \(processedCount)/\(assets.count) photos, \(instancesCreated) instances")
                    // Save every 10 photos
                    try context.save()
                    print("💾 Saved progress to database")
                }
            } catch {
                print("❌ Error processing photo: \(error)")
            }
        }
        
        // Final save
        try context.save()
        print("💾 Final save complete")

        // Verify instances were saved
        let verifyDescriptor = FetchDescriptor<ObjectInstance>()
        let savedInstances = (try? context.fetch(verifyDescriptor)) ?? []
        print("📊 DATABASE CHECK: \(savedInstances.count) total instances in database")

        let duration = Date().timeIntervalSince(startTime)
        print("✅ Indexing complete: \(processedCount) photos, \(instancesCreated) instances created in \(String(format: "%.1f", duration))s")
        
        await MainActor.run {
            onProgress?("Creating clusters...", 0.95, processedCount, processedCount)
        }
        
        try await createClusters()
        
        await MainActor.run {
            onProgress?("Complete!", 1.0, processedCount, processedCount)
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

        for (index, detection) in yoloDetections.enumerated() {
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

            // Generate embeddings
            let embedding = try await embeddingQueue.generateEmbedding(for: segmentedCrop)
            let clipEmbedding = try? await mobileCLIP.generateImageEmbedding(for: segmentedCrop)

            let instance = ObjectInstance(
                embedding: embedding.vector,
                boundingBox: BoundingBox(from: pixelRect),
                contourPoints: pixelContourPoints,
                detectionConfidence: detection.confidence,
                imageQuality: 0.8
            )
            instance.clipEmbedding = clipEmbedding
            instance._setCropUIImage(segmentedCrop)
            instance.sourceImagePath = saveImageToDocuments(image, assetID: asset.localIdentifier)

            context.insert(instance)
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
        print("🔄 Creating clusters...")
        
        let storage = ObjectRecognitionStorage.shared
        let context = storage.context
        
        // Fetch all unassigned instances
        let descriptor = FetchDescriptor<ObjectInstance>(
            predicate: #Predicate { instance in
                instance.identity == nil
            }
        )
        let instances = try context.fetch(descriptor)
        
        print("📊 Found \(instances.count) unassigned instances")
        
        guard !instances.isEmpty else {
            print("ℹ️ No instances to cluster")
            return
        }
        
        let clusters = performDBSCANClustering(on: instances)
        print("✅ Created \(clusters.count) clusters")
        
        for cluster in clusters {
            cluster.selectRepresentative()
            context.insert(cluster)
            print("  Cluster: \(cluster.instances.count) instances, representative: \(cluster.representativeInstanceID?.uuidString.prefix(8) ?? "none")")
        }

        try context.save()
        print("💾 Clusters saved to database")

        // Verify clusters were saved
        let clusterDescriptor = FetchDescriptor<UnlabeledCluster>(
            predicate: #Predicate { !$0.hasBeenPresented }
        )
        let savedClusters = (try? context.fetch(clusterDescriptor)) ?? []
        print("📊 DATABASE CHECK: \(savedClusters.count) unpresented clusters ready for labeling")
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
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        
        var resultImage: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 2048, height: 2048),
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
