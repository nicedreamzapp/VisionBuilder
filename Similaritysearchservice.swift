//
//  SimilaritySearchService.swift
//  Vision Builder
//

import Foundation

struct SimilarInstance: Identifiable {
    let instance: ObjectInstance
    let similarity: Float
    var id: UUID { instance.id }
}

struct ConfirmationResult {
    let acceptedInstances: [ObjectInstance]
    let rejectedInstances: [ObjectInstance]
    let autoAcceptedInstances: [ObjectInstance]
    var totalAccepted: Int {
        acceptedInstances.count + autoAcceptedInstances.count
    }
}

class SimilaritySearchService {
    struct Config {
        var minSimilarity: Float = 0.85
        var maxCandidates: Int = 50
        var highConfidenceThreshold: Float = 0.92
    }
    
    private var config: Config
    
    init(config: Config = Config()) {
        self.config = config
    }
    
    func findSimilarInstances(
        to seedInstance: ObjectInstance,
        in allInstances: [ObjectInstance],
        excluding excludeIDs: Set<UUID> = []
    ) -> [SimilarInstance] {
        guard !seedInstance.embedding.isEmpty else { return [] }
        
        var results: [SimilarInstance] = []
        
        for candidate in allInstances {
            if candidate.id == seedInstance.id || excludeIDs.contains(candidate.id) {
                continue
            }
            if candidate.identity != nil { continue }
            guard !candidate.embedding.isEmpty else { continue }
            
            let similarity = cosineSimilarity(seedInstance.embedding, candidate.embedding)
            if similarity >= config.minSimilarity {
                results.append(SimilarInstance(instance: candidate, similarity: similarity))
            }
        }
        
        results.sort { $0.similarity > $1.similarity }
        if results.count > config.maxCandidates {
            results = Array(results.prefix(config.maxCandidates))
        }
        return results
    }
    
    func findSimilarInstances(
        toCluster cluster: UnlabeledCluster,
        in allInstances: [ObjectInstance],
        excluding excludeIDs: Set<UUID> = []
    ) -> [SimilarInstance] {
        guard let representative = cluster.representativeInstance else { return [] }
        var exclusions = excludeIDs
        for instance in cluster.instances {
            exclusions.insert(instance.id)
        }
        return findSimilarInstances(to: representative, in: allInstances, excluding: exclusions)
    }
    
    func splitCandidatesForAutoAccept(
        candidates: [SimilarInstance],
        confirmedCount: Int,
        autoAcceptThreshold: Int = 3
    ) -> (remaining: [SimilarInstance], autoAccepted: [SimilarInstance]) {
        if confirmedCount < autoAcceptThreshold {
            return (remaining: candidates, autoAccepted: [])
        }
        let autoAccepted = candidates.filter { $0.similarity >= config.highConfidenceThreshold }
        let remaining = candidates.filter { $0.similarity < config.highConfidenceThreshold }
        return (remaining: remaining, autoAccepted: autoAccepted)
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dotProduct: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = sqrt(normA) * sqrt(normB)
        return denominator == 0 ? 0.0 : dotProduct / denominator
    }
}
