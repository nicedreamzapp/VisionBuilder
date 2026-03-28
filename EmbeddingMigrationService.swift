//
//  EmbeddingMigrationService.swift
//  Vision Builder
//
//  Background service to generate MobileCLIP embeddings for existing instances
//  that only have VNFeaturePrint embeddings.
//

import Foundation
import SwiftData
import UIKit

@MainActor
class EmbeddingMigrationService {
    private let mobileCLIP = MobileCLIPService()
    private let storage = ObjectRecognitionStorage.shared

    struct MigrationProgress {
        let completed: Int
        let total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 1.0 }
        var isComplete: Bool { completed >= total }
    }

    /// Count how many instances still need CLIP embeddings.
    func pendingCount() throws -> Int {
        let all = try storage.context.fetch(FetchDescriptor<ObjectInstance>())
        return all.filter { $0.clipEmbedding == nil && $0.cropImageData != nil }.count
    }

    /// Migrate existing instances in batches. Calls `onProgress` after each batch.
    func migrateExistingInstances(
        batchSize: Int = 50,
        onProgress: ((MigrationProgress) -> Void)? = nil
    ) async throws {
        try await mobileCLIP.ensureModelsLoaded()

        let context = storage.context
        let all = try context.fetch(FetchDescriptor<ObjectInstance>())
        let needsMigration = all.filter { $0.clipEmbedding == nil && $0.cropImageData != nil }
        let total = needsMigration.count

        guard total > 0 else {
            onProgress?(MigrationProgress(completed: 0, total: 0))
            return
        }

        print("Starting CLIP embedding migration: \(total) instances")
        var completed = 0

        for batch in stride(from: 0, to: total, by: batchSize) {
            let end = min(batch + batchSize, total)
            let slice = needsMigration[batch..<end]

            for instance in slice {
                guard let imageData = instance.cropImageData,
                      let image = UIImage(data: imageData) else {
                    completed += 1
                    continue
                }

                do {
                    let embedding = try await mobileCLIP.generateImageEmbedding(for: image)
                    instance.clipEmbedding = embedding
                } catch {
                    print("Migration: failed for instance \(instance.id): \(error.localizedDescription)")
                }
                completed += 1
            }

            try context.save()
            onProgress?(MigrationProgress(completed: completed, total: total))
        }

        // Update cluster centroids with new CLIP embeddings
        let clusters = try context.fetch(FetchDescriptor<UnlabeledCluster>())
        for cluster in clusters where cluster.clipCentroidEmbedding == nil {
            let clipEmbeddings = cluster.instances.compactMap { $0.clipEmbedding }
            guard let first = clipEmbeddings.first else { continue }
            let dim = first.count
            var centroid = [Float](repeating: 0, count: dim)
            for emb in clipEmbeddings {
                for i in 0..<dim { centroid[i] += emb[i] }
            }
            let c = Float(clipEmbeddings.count)
            centroid = centroid.map { $0 / c }
            let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { centroid = centroid.map { $0 / norm } }
            cluster.clipCentroidEmbedding = centroid
        }

        // Update identity prototypes
        let identities = try context.fetch(FetchDescriptor<ObjectIdentity>())
        for identity in identities where identity.clipPrototypeEmbedding == nil {
            identity.updatePrototype()
        }

        try context.save()
        print("CLIP embedding migration complete: \(completed)/\(total)")
    }
}
