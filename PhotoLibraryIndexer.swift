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
    
    var onProgress: ((String, Double, Int, Int) -> Void)?
    private let maxPhotosToProcess = 1000  // Scan up to 1000 photos for meaningful clusters
    
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

        print("✅ Image loaded: \(image.size)")

        // Pre-filter 1: Check if image is mostly text (screenshots, documents)
        let isTextHeavy = await isTextHeavyImage(image)
        if isTextHeavy {
            print("⏭️ Skipping image - text-heavy (screenshot/document)")
            return []
        }

        // Pre-filter 2: Check if image has salient objects worth detecting
        // Using relaxed threshold - only skip truly empty/uniform images
        let saliencyScore = await checkImageSaliency(image)
        print("🎯 Saliency score: \(String(format: "%.2f", saliencyScore))")

        if saliencyScore < 0.08 {
            print("⏭️ Skipping image - very low saliency (no clear objects)")
            return []
        }

        // Use SAM2 auto-detection
        print("🎯 Running SAM2 auto-detection...")
        let detectedBoxes = await detectObjectsWithSAM2(in: image)
        print("✅ Found \(detectedBoxes.count) objects with SAM2")

        guard !detectedBoxes.isEmpty else {
            return []
        }

        // Filter out boxes that are too small or too large (likely noise or full-image)
        // box.rect is already in NORMALIZED coordinates (0-1), so width * height IS the area ratio
        let filteredBoxes = detectedBoxes.filter { box in
            // Since box.rect is normalized (0-1), this directly gives us the area ratio
            let areaRatio = box.rect.width * box.rect.height

            // Keep objects between 0.5% and 85% of image area
            let passes = areaRatio >= 0.005 && areaRatio <= 0.85
            if !passes {
                print("  ⚠️ Box filtered: area ratio \(String(format: "%.1f", areaRatio * 100))% (rect: \(box.rect))")
            } else {
                print("  ✅ Box accepted: area ratio \(String(format: "%.1f", areaRatio * 100))%")
            }
            return passes
        }

        if filteredBoxes.count < detectedBoxes.count {
            print("📦 Kept \(filteredBoxes.count)/\(detectedBoxes.count) boxes after size filter")
        }

        guard !filteredBoxes.isEmpty else {
            return []
        }
        
        var instances: [ObjectInstance] = []

        for (index, box) in filteredBoxes.enumerated() {
            print("  Object \(index + 1)/\(filteredBoxes.count)")

            // Get segmented crop from contour points
            guard let normalizedContourPoints = box.contourPoints, !normalizedContourPoints.isEmpty else {
                print("  ⚠️ No contour points")
                continue
            }

            // CRITICAL: Convert normalized (0-1) contour points to pixel coordinates
            let imageWidth = image.size.width
            let imageHeight = image.size.height
            let pixelContourPoints = normalizedContourPoints.map { point in
                CGPoint(
                    x: point.x * imageWidth,
                    y: point.y * imageHeight
                )
            }

            print("  📐 Contour: \(normalizedContourPoints.count) points, pixel coords: \(pixelContourPoints.first ?? .zero)")

            // Generate tightly cropped segmented preview
            guard let segmentedCrop = SegmentedPreviewRenderer.generateSegmentedPreview(
                from: image,
                contourPoints: pixelContourPoints,
                backgroundColor: .white
            ) else {
                print("  ⚠️ Failed to generate segmented preview")
                continue
            }

            print("  🖼️ Segmented crop size: \(segmentedCrop.size.width)x\(segmentedCrop.size.height)")

            // Verify crop is not empty/tiny
            if segmentedCrop.size.width < 10 || segmentedCrop.size.height < 10 {
                print("  ⚠️ Segmented crop too small, skipping")
                continue
            }

            print("  Generating embedding...")
            let startTime = Date()
            let embedding = try await embeddingQueue.generateEmbedding(for: segmentedCrop)
            let elapsed = Date().timeIntervalSince(startTime)
            print("  ✅ Embedding done in \(String(format: "%.2f", elapsed))s")
            
            // Create bounding box from normalized rect, converted to pixel coordinates
            let pixelRect = CGRect(
                x: box.rect.origin.x * imageWidth,
                y: box.rect.origin.y * imageHeight,
                width: box.rect.width * imageWidth,
                height: box.rect.height * imageHeight
            )

            let instance = ObjectInstance(
                embedding: embedding.vector,
                boundingBox: BoundingBox(from: pixelRect),
                contourPoints: pixelContourPoints,  // Store pixel coordinates
                detectionConfidence: 0.9,
                imageQuality: 0.8
            )
            
            instance._setCropUIImage(segmentedCrop)

            // Verify crop data was saved
            if let savedData = instance.cropImageData {
                print("  💾 Crop data saved: \(savedData.count) bytes")
            } else {
                print("  ⚠️ WARNING: cropImageData is nil after saving!")
            }

            instance.sourceImagePath = saveImageToDocuments(image, assetID: asset.localIdentifier)
            print("  📁 Source saved to: \(instance.sourceImagePath ?? "nil")")

            // Insert into SwiftData immediately
            context.insert(instance)
            instances.append(instance)

            print("  ✅ Instance created: bbox=\(pixelRect), contour=\(pixelContourPoints.count) pts")
        }
        
        print("✅ Created \(instances.count) instances")
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
                
                print("  📦 Created cluster with \(clusterMembers.count) instances")
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
            print("  📦 Created singleton cluster")
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
