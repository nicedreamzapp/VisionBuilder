//
//  ObjectRecognitionEngine.swift
//  Vision Builder
//

import Foundation
import SwiftData
import UIKit

/// Manages object recognition, learning, and identity matching
@MainActor
class ObjectRecognitionEngine {
    
    private let embeddingService = EmbeddingService()
    private let storage = ObjectRecognitionStorage.shared
    
    // MARK: - Configuration
    
    struct RecognitionConfig {
        let matchThreshold: Float        // Cosine similarity threshold for positive match
        let uncertaintyThreshold: Float  // Below this, definitely unknown
        let clusteringThreshold: Float   // Max distance for clustering unknowns
        
        static let `default` = RecognitionConfig(
            matchThreshold: 0.85,        // 85% similarity = match
            uncertaintyThreshold: 0.70,  // Below 70% = definitely unknown
            clusteringThreshold: 0.25    // Distance threshold for clustering
        )
    }
    
    // MARK: - Recognition
    
    /// Recognize an object and return matched identity or nil if unknown
    func recognizeObject(
        embedding: [Float],
        config: RecognitionConfig? = nil
    ) throws -> RecognitionResult {
        let config = config ?? RecognitionConfig.default
        let context = storage.context
        
        // Fetch all known identities
        let descriptor = FetchDescriptor<ObjectIdentity>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        let identities = try context.fetch(descriptor)
        
        guard !identities.isEmpty else {
            return .unknown(confidence: 0)
        }
        
        // Find best match
        var bestMatch: ObjectIdentity?
        var bestSimilarity: Float = 0
        
        for identity in identities {
            let similarity = EmbeddingService.cosineSimilarity(
                embedding,
                identity.prototypeEmbedding
            )
            
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestMatch = identity
            }
        }
        
        // Determine result based on thresholds
        if bestSimilarity >= config.matchThreshold {
            return .matched(identity: bestMatch!, confidence: bestSimilarity)
        } else if bestSimilarity >= config.uncertaintyThreshold {
            return .uncertain(possibleIdentity: bestMatch, confidence: bestSimilarity)
        } else {
            return .unknown(confidence: bestSimilarity)
        }
    }
    
    /// Process a detected object: generate embedding and try to recognize it
    func processDetectedObject(
        image: UIImage,
        boundingBox: CGRect,
        detectionConfidence: Float = 1.0
    ) async throws -> ProcessedObject {
        // Generate embedding
        let objectEmbedding = try await embeddingService.generateEmbedding(
            from: image,
            boundingBox: boundingBox
        )
        
        // Try to recognize
        let recognition = try recognizeObject(embedding: objectEmbedding.vector)
        
        // Create instance
        let instance = ObjectInstance(
            embedding: objectEmbedding.vector,
            boundingBox: BoundingBox(from: boundingBox),
            detectionConfidence: detectionConfidence,
            imageQuality: calculateImageQuality(image: image, box: boundingBox)
        )
        
        // Extract and store crop
        if let crop = extractCrop(from: image, boundingBox: boundingBox) {
            instance._setCropUIImage(crop)
        }
        
        return ProcessedObject(
            instance: instance,
            recognition: recognition,
            needsLabeling: recognition.isUnknown
        )
    }
    
    // MARK: - Learning
    
    /// Create a new identity from user input
    func learnNewIdentity(
        label: String,
        instance: ObjectInstance
    ) throws -> ObjectIdentity {
        let context = storage.context
        
        // Create new identity
        let identity = ObjectIdentity(
            label: label,
            prototypeEmbedding: instance.embedding,
            representativeImageData: instance.cropImageData
        )
        
        // Add instance to identity
        identity.addInstance(instance)
        
        // Save to database
        context.insert(identity)
        try context.save()
        
        print("✅ Learned new identity: '\(label)' with embedding dim=\(instance.embedding.count)")
        
        return identity
    }
    
    /// Add an instance to an existing identity
    func addInstanceToIdentity(
        instance: ObjectInstance,
        identity: ObjectIdentity
    ) throws {
        let context = storage.context
        
        // Link instance to identity
        identity.addInstance(instance)
        
        // Save
        context.insert(instance)
        try context.save()
        
        print("✅ Added instance to '\(identity.label)' (now \(identity.instanceCount) instances)")
    }
    
    // MARK: - Clustering Unknown Objects
    
    func clusterUnknownInstances(
        instances: [ObjectInstance],
        config: RecognitionConfig? = nil
    ) throws -> [UnlabeledCluster] {
        let config = config ?? RecognitionConfig.default
        guard !instances.isEmpty else { return [] }
        
        var clusters: [UnlabeledCluster] = []
        var unassigned = instances
        
        while !unassigned.isEmpty {
            // Start new cluster with first unassigned instance
            let seed = unassigned.removeFirst()
            var clusterMembers = [seed]
            
            // Find all instances similar to seed
            unassigned = unassigned.filter { instance in
                let distance = EmbeddingService.euclideanDistance(
                    seed.embedding,
                    instance.embedding
                )
                
                if distance < config.clusteringThreshold {
                    clusterMembers.append(instance)
                    return false // Remove from unassigned
                }
                return true // Keep in unassigned
            }
            
            // Calculate cluster centroid
            let centroid = calculateCentroid(embeddings: clusterMembers.map { $0.embedding })
            
            // Create cluster
            let cluster = UnlabeledCluster(
                instances: clusterMembers,
                centroidEmbedding: centroid
            )
            cluster.selectRepresentative()
            
            clusters.append(cluster)
        }
        
        print("✅ Clustered \(instances.count) instances into \(clusters.count) clusters")
        
        return clusters
    }
    
    private func calculateCentroid(embeddings: [[Float]]) -> [Float] {
        // Compute element-wise mean of a list of embeddings
        guard let first = embeddings.first, !first.isEmpty else { return [] }
        let dimension = first.count
        var centroid = [Float](repeating: 0, count: dimension)
        var validCount: Float = 0

        for vector in embeddings {
            if vector.count != dimension {
                print("⚠️ calculateCentroid: skipping vector with mismatched dimension \(vector.count) (expected \(dimension))")
                continue
            }
            for i in 0..<dimension {
                centroid[i] += vector[i]
            }
            validCount += 1
        }

        guard validCount > 0 else { return [Float](repeating: 0, count: dimension) }
        let inv: Float = 1.0 / validCount
        for i in 0..<dimension {
            centroid[i] *= inv
        }
        return centroid
    }

    /// Save clusters to database for morning review
    func saveUnlabeledClusters(_ clusters: [UnlabeledCluster]) throws {
        let context = storage.context
        
        for cluster in clusters {
            context.insert(cluster)
            for instance in cluster.instances {
                context.insert(instance)
            }
        }
        
        try context.save()
        print("✅ Saved \(clusters.count) unlabeled clusters")
    }
    
    /// Get clusters waiting for user labeling
    func getPendingClusters() throws -> [UnlabeledCluster] {
        let context = storage.context
        
        let descriptor = FetchDescriptor<UnlabeledCluster>(
            predicate: #Predicate { cluster in
                cluster.hasBeenPresented == false && cluster.userLabel == nil
            },
            sortBy: [] // We'll sort manually by instance count
        )
        
        var clusters = try context.fetch(descriptor)
        
        print("📊 Raw fetch found \(clusters.count) clusters")
        for (i, cluster) in clusters.prefix(10).enumerated() {
            print("  \(i+1). Cluster: \(cluster.instances.count) instances, presented: \(cluster.hasBeenPresented)")
        }
        
        // SORT BY INSTANCE COUNT (HIGHEST FIRST)
        clusters.sort { $0.instances.count > $1.instances.count }
        
        print("Found \(clusters.count) pending clusters, sorted by size")
        for (index, cluster) in clusters.prefix(5).enumerated() {
            print("  \(index + 1). Cluster with \(cluster.instances.count) instances")
        }
        
        return clusters
    }
    
    /// Mark cluster as labeled and create identity
    func labelCluster(
        cluster: UnlabeledCluster,
        label: String
    ) throws -> ObjectIdentity {
        let context = storage.context
        
        // Create identity with cluster centroid
        let identity = ObjectIdentity(
            label: label,
            prototypeEmbedding: cluster.centroidEmbedding
        )
        
        // Add all instances from cluster
        for instance in cluster.instances {
            identity.addInstance(instance)
        }
        
        // Mark cluster as processed
        cluster.hasBeenPresented = true
        cluster.userLabel = label
        cluster.labeledAt = Date()
        
        // Save to database
        context.insert(identity)
        try context.save()
        
        // AUTO-CREATE DATASET FOLDER if 3+ instances
        if cluster.instances.count >= 3 {
            try createDatasetFolder(for: identity, instances: cluster.instances)
            print("✅ Created dataset folder '\(label)' with \(cluster.instances.count) images")
        } else {
            print("ℹ️ Cluster '\(label)' only has \(cluster.instances.count) instances (need 3+ for folder)")
        }
        
        return identity
    }
    
    // MARK: - Deletion Methods
    
    /// Delete a specific cluster and its instances
    func deleteCluster(_ cluster: UnlabeledCluster) async throws {
        let context = storage.context
        
        // Delete all instances in the cluster
        for instance in cluster.instances {
            context.delete(instance)
        }
        
        // Delete the cluster itself
        context.delete(cluster)
        
        try context.save()
        print("🗑️ Deleted cluster with \(cluster.instances.count) instances")
    }
    
    /// Delete all unlabeled clusters
    func deleteAllUnlabeledClusters() async throws {
        let context = storage.context
        
        // Fetch all unlabeled clusters
        let clusterDescriptor = FetchDescriptor<UnlabeledCluster>()
        let clusters = try context.fetch(clusterDescriptor)
        
        // Fetch all unassigned instances
        let instanceDescriptor = FetchDescriptor<ObjectInstance>(
            predicate: #Predicate { instance in
                instance.identity == nil
            }
        )
        let instances = try context.fetch(instanceDescriptor)
        
        // Delete all instances
        for instance in instances {
            context.delete(instance)
        }
        
        // Delete all clusters
        for cluster in clusters {
            context.delete(cluster)
        }
        
        try context.save()
        print("🗑️ Deleted \(clusters.count) clusters and \(instances.count) instances")
    }
    
    // MARK: - Dataset Folder Creation
    
    private func createDatasetFolder(for identity: ObjectIdentity, instances: [ObjectInstance]) throws {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Clean label for folder name (replace spaces and illegal chars)
        let folderName = identity.label
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        
        let datasetPath = documentsPath.appendingPathComponent(folderName)
        
        // Create main folder
        try fileManager.createDirectory(at: datasetPath, withIntermediateDirectories: true)
        
        // Save each instance as Object_1, Object_2, etc.
        for (index, instance) in instances.enumerated() {
            guard let cropImage = instance._cropUIImage else {
                print("⚠️ Instance \(index + 1) has no crop image")
                continue
            }
            
            let objectFolderName = "Object_\(index + 1)"
            let objectPath = datasetPath.appendingPathComponent(objectFolderName)
            
            // Create object subfolder
            try fileManager.createDirectory(at: objectPath, withIntermediateDirectories: true)
            
            // Save segmented image
            let imagePath = objectPath.appendingPathComponent("image.jpg")
            if let imageData = cropImage.jpegData(compressionQuality: 0.95) {
                try imageData.write(to: imagePath)
            }
            
            // Save bounding box metadata
            let bbox = instance.boundingBox
            let metadata = """
            {
                \"label\": \"\(identity.label)\",
                \"bbox\": {
                    \"x\": \(bbox.x),
                    \"y\": \(bbox.y),
                    \"width\": \(bbox.width),
                    \"height\": \(bbox.height)
                },
                \"has_contours\": \(instance.contourPoints != nil),
                \"contour_points\": \(instance.contourPoints?.count ?? 0),
                \"detected_at\": \"\(instance.detectedAt)\",
                \"confidence\": \(instance.detectionConfidence)
            }
            """
            
            let metadataPath = objectPath.appendingPathComponent("metadata.json")
            try metadata.write(to: metadataPath, atomically: true, encoding: .utf8)
        }
        
        print("📁 Created dataset folder: \(datasetPath.path)")
        print("   - \(instances.count) segmented images saved")
    }
    
    // MARK: - Image Utilities
    
    private func calculateImageQuality(image: UIImage, box: CGRect) -> Float {
        // Clamp box to image bounds (point space)
        let imageBounds = CGRect(origin: .zero, size: image.size)
        let rect = box.integral.intersection(imageBounds)
        guard !rect.isEmpty else { return 0 }
        let areaFraction = max(0, min(1, (rect.width * rect.height) / max(1, imageBounds.width * imageBounds.height)))
        
        // Try to get a cropped image of the region
        guard let crop = extractCrop(from: image, boundingBox: rect), let cgImage = crop.cgImage else {
            // Fallback: use area as a weak proxy for quality
            return Float(min(1.0, max(0.05, sqrt(areaFraction))))
        }
        
        // Downscale target
        let targetSize = CGSize(width: 48, height: 48)
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = Data(count: height * bytesPerRow)
        
        let quality: Float = buffer.withUnsafeMutableBytes { ptr -> Float in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return Float(min(1.0, max(0.05, sqrt(areaFraction))))
            }
            
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: targetSize))
            
            let p = ptr.bindMemory(to: UInt8.self)
            let pixelCount = width * height
            var lumas = [Double](repeating: 0, count: pixelCount)
            var sum: Double = 0
            var sumSq: Double = 0
            
            // Compute luminance per pixel and accumulate stats
            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * bytesPerRow + x * bytesPerPixel
                    // For premultipliedLast + byteOrder32Big, channels are R, G, B, A
                    let r = Double(p[idx + 0])
                    let g = Double(p[idx + 1])
                    let b = Double(p[idx + 2])
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    lumas[y * width + x] = l
                    sum += l
                    sumSq += l * l
                }
            }
            
            let mean = sum / Double(pixelCount)
            let variance = max(0, sumSq / Double(pixelCount) - mean * mean)
            let stdDev = sqrt(variance)
            let brightnessScore = max(0.0, min(1.0, 1.0 - abs(mean - 128.0) / 128.0))
            let contrastScore = min(1.0, stdDev / 64.0) // heuristic normalization
            
            // Edge/Sharpness via simple gradient magnitude on luminance
            var gradSum: Double = 0
            if width > 1 && height > 1 {
                for y in 0..<(height - 1) {
                    for x in 0..<(width - 1) {
                        let i = y * width + x
                        let dx = lumas[i + 1] - lumas[i]
                        let dy = lumas[i + width] - lumas[i]
                        gradSum += abs(dx) + abs(dy)
                    }
                }
            }
            let denom = max(1, (width - 1) * (height - 1))
            let edgeAvg = (gradSum / Double(denom)) / 255.0
            
            let baseQuality = max(0.0, min(1.0, 0.6 * edgeAvg + 0.3 * contrastScore + 0.1 * brightnessScore))
            let areaScore = max(0.0, min(1.0, sqrt(Double(areaFraction))))
            let finalQ = max(0.0, min(1.0, 0.5 * baseQuality + 0.5 * areaScore))
            return Float(finalQ)
        }
        
        return quality
    }
    
    private func extractCrop(from image: UIImage, boundingBox: CGRect) -> UIImage? {
        let imageBounds = CGRect(origin: .zero, size: image.size)
        let rect = boundingBox.intersection(imageBounds)
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return nil }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        let cropped = renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
        return cropped
    }
    
    // MARK: - Query Methods
    
    /// Get all learned identities
    func getAllIdentities() throws -> [ObjectIdentity] {
        let descriptor = FetchDescriptor<ObjectIdentity>(
            sortBy: [SortDescriptor(\.label)]
        )
        return try storage.context.fetch(descriptor)
    }
    
    /// Search identities by label
    func searchIdentities(query: String) throws -> [ObjectIdentity] {
        let descriptor = FetchDescriptor<ObjectIdentity>(
            predicate: #Predicate { identity in
                identity.label.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        return try storage.context.fetch(descriptor)
    }

    // MARK: - Active Learning Support Methods

    /// Get unlabeled clusters for active learning workflow
    /// This is the method called by ActiveLearningController
    func getUnlabeledClusters(onlyNotPresented: Bool = false) async throws -> [UnlabeledCluster] {
        let context = storage.context

        if onlyNotPresented {
            // Only return clusters that haven't been shown to the user yet
            let descriptor = FetchDescriptor<UnlabeledCluster>(
                predicate: #Predicate { cluster in
                    cluster.hasBeenPresented == false && cluster.userLabel == nil
                }
            )
            var clusters = try context.fetch(descriptor)
            clusters.sort { $0.instances.count > $1.instances.count }
            print("📊 getUnlabeledClusters: Found \(clusters.count) unpresented clusters")
            return clusters
        } else {
            // Return all unlabeled clusters
            let descriptor = FetchDescriptor<UnlabeledCluster>(
                predicate: #Predicate { cluster in
                    cluster.userLabel == nil
                }
            )
            var clusters = try context.fetch(descriptor)
            clusters.sort { $0.instances.count > $1.instances.count }
            print("📊 getUnlabeledClusters: Found \(clusters.count) total unlabeled clusters")
            return clusters
        }
    }

    /// Get all object instances from database
    func getAllInstances() async throws -> [ObjectInstance] {
        let context = storage.context
        let descriptor = FetchDescriptor<ObjectInstance>()
        let instances = try context.fetch(descriptor)
        print("📊 getAllInstances: Found \(instances.count) total instances")
        return instances
    }

    /// Apply a label to multiple instances by ID
    func applyLabel(label: String, to instanceIDs: [UUID]) async throws {
        let context = storage.context

        // Find or create the identity for this label
        let identityDescriptor = FetchDescriptor<ObjectIdentity>(
            predicate: #Predicate { identity in
                identity.label == label
            }
        )

        var identity: ObjectIdentity
        if let existingIdentity = try context.fetch(identityDescriptor).first {
            identity = existingIdentity
        } else {
            // Create new identity - we'll use first instance's embedding as prototype
            identity = ObjectIdentity(label: label, prototypeEmbedding: [])
            context.insert(identity)
        }

        // Fetch all instances matching the IDs
        let instanceDescriptor = FetchDescriptor<ObjectInstance>()
        let allInstances = try context.fetch(instanceDescriptor)

        var addedCount = 0
        for instance in allInstances where instanceIDs.contains(instance.id) {
            // Update prototype embedding if not set
            if identity.prototypeEmbedding.isEmpty && !instance.embedding.isEmpty {
                identity.prototypeEmbedding = instance.embedding
            }

            identity.addInstance(instance)
            addedCount += 1
        }

        try context.save()
        print("✅ Applied label '\(label)' to \(addedCount) instances")
    }

    /// Mark a cluster as presented to the user
    func markClusterAsPresented(clusterID: UUID, label: String?) async throws {
        let context = storage.context

        let descriptor = FetchDescriptor<UnlabeledCluster>()
        let clusters = try context.fetch(descriptor)

        if let cluster = clusters.first(where: { $0.id == clusterID }) {
            cluster.hasBeenPresented = true
            cluster.userLabel = label
            cluster.labeledAt = Date()
            try context.save()
            print("✅ Marked cluster \(clusterID) as presented (label: \(label ?? "skipped"))")
        }
    }
    
    /// Get statistics
    func getStatistics() throws -> RecognitionStatistics {
        let identities = try getAllIdentities()
        let totalInstances = identities.reduce(0) { $0 + $1.instanceCount }
        let pendingClusters = try getPendingClusters()
        
        return RecognitionStatistics(
            totalIdentities: identities.count,
            totalInstances: totalInstances,
            pendingClusters: pendingClusters.count
        )
    }
}

// MARK: - Result Types

enum RecognitionResult {
    case matched(identity: ObjectIdentity, confidence: Float)
    case uncertain(possibleIdentity: ObjectIdentity?, confidence: Float)
    case unknown(confidence: Float)
    
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
    
    var matchedIdentity: ObjectIdentity? {
        if case .matched(let identity, _) = self { return identity }
        return nil
    }
    
    var confidence: Float {
        switch self {
        case .matched(_, let conf): return conf
        case .uncertain(_, let conf): return conf
        case .unknown(let conf): return conf
        }
    }
}

struct ProcessedObject {
    let instance: ObjectInstance
    let recognition: RecognitionResult
    let needsLabeling: Bool
}

struct RecognitionStatistics {
    let totalIdentities: Int
    let totalInstances: Int
    let pendingClusters: Int
}
