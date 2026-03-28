//
//  ConceptSearchService.swift
//  Vision Builder
//
//  Text-prompted object discovery using MobileCLIP embeddings.
//  Type "shoes" and find all shoes across your photo library.
//

import Combine
import Foundation
import SwiftData
import UIKit

@MainActor
class ConceptSearchService: ObservableObject {
    private let mobileCLIP = MobileCLIPService()
    private let storage = ObjectRecognitionStorage.shared

    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published var lastQuery = ""
    @Published var statusMessage: String?

    struct SearchResult: Identifiable {
        let instance: ObjectInstance
        let similarity: Float
        let identityLabel: String?
        var id: UUID { instance.id }
    }

    /// Search all instances by text query.
    func search(query: String, minSimilarity: Float = 0.15, maxResults: Int = 100) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            lastQuery = ""
            return
        }

        isSearching = true
        lastQuery = query
        statusMessage = nil

        do {
            let allInstances = try storage.context.fetch(FetchDescriptor<ObjectInstance>())

            guard !allInstances.isEmpty else {
                statusMessage = "No objects scanned yet. Scan your photo library first."
                results = []
                isSearching = false
                return
            }

            let withClip = allInstances.filter { $0.clipEmbedding != nil }

            if withClip.isEmpty {
                statusMessage = "Objects need CLIP embeddings. Go to Settings → CLIP Embedding Migration."
                results = []
                isSearching = false
                return
            }

            let textEmbedding = try await mobileCLIP.generateTextEmbedding(for: query)

            var scored: [SearchResult] = []
            for instance in withClip {
                guard let clipEmb = instance.clipEmbedding else { continue }
                let sim = MobileCLIPService.cosineSimilarity(textEmbedding, clipEmb)
                if sim >= minSimilarity {
                    scored.append(SearchResult(
                        instance: instance,
                        similarity: sim,
                        identityLabel: instance.identity?.label
                    ))
                }
            }

            scored.sort { $0.similarity > $1.similarity }
            results = Array(scored.prefix(maxResults))
        } catch {
            print("Concept search failed: \(error.localizedDescription)")
            statusMessage = "Search failed: \(error.localizedDescription)"
            results = []
        }

        isSearching = false
    }

    /// Get suggested search queries based on existing labels and common objects.
    func suggestedQueries() throws -> [String] {
        let identities = try storage.context.fetch(FetchDescriptor<ObjectIdentity>())
        let existingLabels = identities.map { $0.label }

        let commonObjects = [
            "shoe", "car", "phone", "cup", "bottle", "bag", "book",
            "laptop", "watch", "glasses", "plant", "food", "clothing",
            "furniture", "animal", "person", "toy", "tool"
        ]

        // Existing labels first, then common objects not already covered
        var suggestions = existingLabels
        for obj in commonObjects {
            if !suggestions.contains(where: { $0.localizedCaseInsensitiveContains(obj) }) {
                suggestions.append(obj)
            }
        }
        return Array(suggestions.prefix(20))
    }
}
