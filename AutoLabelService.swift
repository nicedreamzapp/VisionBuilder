//
//  AutoLabelService.swift
//  Vision Builder
//
//  Suggests labels for unlabeled clusters using MobileCLIP text-image matching.
//

import Foundation
import SwiftData
import UIKit

@MainActor
class AutoLabelService {
    private let mobileCLIP = MobileCLIPService()
    private let storage = ObjectRecognitionStorage.shared

    /// Pre-computed text embeddings for common labels
    private var labelEmbeddingCache: [(label: String, embedding: [Float])] = []
    private var isWarmedUp = false

    struct LabelSuggestion: Identifiable {
        let label: String
        let confidence: Float
        var id: String { label }
    }

    static let commonLabels: [String] = [
        "shoe", "sneaker", "boot", "sandal",
        "car", "truck", "bicycle", "motorcycle",
        "phone", "laptop", "keyboard", "headphones",
        "cup", "bottle", "glass", "plate", "bowl",
        "bag", "backpack", "purse", "suitcase",
        "book", "pen", "notebook",
        "watch", "glasses", "sunglasses", "hat",
        "plant", "flower", "tree",
        "food", "fruit", "pizza", "cake",
        "clothing", "shirt", "pants", "dress", "jacket",
        "furniture", "chair", "table", "sofa", "bed",
        "toy", "ball", "stuffed animal",
        "tool", "scissors", "key",
        "animal", "dog", "cat", "bird",
        "person", "face", "hand"
    ]

    /// Pre-compute text embeddings for all labels. Call once at startup.
    func warmUp() async {
        guard !isWarmedUp else { return }
        do {
            try await mobileCLIP.ensureModelsLoaded()

            // Compute embeddings for common labels
            var cache: [(String, [Float])] = []
            for label in Self.commonLabels {
                do {
                    let emb = try await mobileCLIP.generateTextEmbedding(for: label)
                    cache.append((label, emb))
                } catch {
                    continue
                }
            }

            // Also compute for existing user labels
            let identities = try storage.context.fetch(FetchDescriptor<ObjectIdentity>())
            for identity in identities {
                let label = identity.label
                if !cache.contains(where: { $0.0.lowercased() == label.lowercased() }) {
                    if let emb = try? await mobileCLIP.generateTextEmbedding(for: label) {
                        cache.append((label, emb))
                    }
                }
            }

            labelEmbeddingCache = cache
            isWarmedUp = true
            print("AutoLabelService warmed up: \(cache.count) label embeddings cached")
        } catch {
            print("AutoLabelService warmup failed: \(error.localizedDescription)")
        }
    }

    /// Suggest labels for a cluster based on its representative image's CLIP embedding.
    func suggestLabels(for cluster: UnlabeledCluster, topK: Int = 3) -> [LabelSuggestion] {
        guard isWarmedUp else { return [] }

        // Use CLIP centroid if available, otherwise try representative instance
        guard let clipEmbedding = cluster.clipCentroidEmbedding
            ?? cluster.representativeInstance?.clipEmbedding else {
            return []
        }

        return suggestLabels(forEmbedding: clipEmbedding, topK: topK)
    }

    /// Suggest labels for a given CLIP embedding.
    func suggestLabels(forEmbedding clipEmbedding: [Float], topK: Int = 3) -> [LabelSuggestion] {
        var scores: [(String, Float)] = []
        for (label, textEmb) in labelEmbeddingCache {
            let sim = MobileCLIPService.cosineSimilarity(clipEmbedding, textEmb)
            scores.append((label, sim))
        }
        scores.sort { $0.1 > $1.1 }

        // Normalize: map the top similarity to 100% for more intuitive display
        guard let topScore = scores.first?.1, topScore > 0 else { return [] }

        return scores.prefix(topK).map { label, sim in
            let normalizedConfidence = sim / topScore
            return LabelSuggestion(label: label, confidence: normalizedConfidence)
        }
    }
}
