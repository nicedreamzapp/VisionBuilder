//
//  ActiveLearningController.swift
//  Vision Builder
//

import Foundation
import SwiftUI

@Observable
class ActiveLearningController {
    private let similarityService: SimilaritySearchService
    private let recognitionEngine: ObjectRecognitionEngine
    
    var unlabeledClusters: [UnlabeledCluster] = []
    var currentCluster: UnlabeledCluster?
    var state: WorkflowState = .idle
    var currentSuggestions: [AutoLabelService.LabelSuggestion] = []
    private var allInstances: [ObjectInstance] = []
    private let autoLabelService = AutoLabelService()
    
    init(
        recognitionEngine: ObjectRecognitionEngine,
        similarityService: SimilaritySearchService = SimilaritySearchService()
    ) {
        self.recognitionEngine = recognitionEngine
        self.similarityService = similarityService
    }
    
    enum WorkflowState: Equatable {
        case idle
        case labelingObject(UUID)  // Store cluster ID instead of cluster
        case confirmingMatches(String, [UUID])  // Store instance IDs
        case applyingLabels
        case complete
        
        static func == (lhs: WorkflowState, rhs: WorkflowState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.labelingObject(let id1), .labelingObject(let id2)):
                return id1 == id2
            case (.confirmingMatches(let label1, let ids1), .confirmingMatches(let label2, let ids2)):
                return label1 == label2 && ids1 == ids2
            case (.applyingLabels, .applyingLabels):
                return true
            case (.complete, .complete):
                return true
            default:
                return false
            }
        }
    }
    
    func startWorkflow() async {
        await autoLabelService.warmUp()
        await loadUnlabeledClusters()
        await moveToNextCluster()
    }
    
    private func loadUnlabeledClusters() async {
        do {
            unlabeledClusters = try await recognitionEngine.getUnlabeledClusters(onlyNotPresented: true)
            allInstances = try await recognitionEngine.getAllInstances()
        } catch {
            unlabeledClusters = []
            allInstances = []
        }
    }
    
    func moveToNextCluster() async {
        currentSuggestions = []
        if let nextCluster = unlabeledClusters.first(where: { !$0.hasBeenPresented }) {
            currentCluster = nextCluster
            currentSuggestions = autoLabelService.suggestLabels(for: nextCluster)
            state = .labelingObject(nextCluster.id)
        } else {
            currentCluster = nil
            currentSuggestions = []
            state = .complete
        }
    }
    
    func objectLabeled(with label: String) async {
        guard let cluster = currentCluster else { return }
        
        let candidates = similarityService.findSimilarInstances(toCluster: cluster, in: allInstances)
        
        if candidates.isEmpty {
            await applyLabelToInstances(label: label, instances: cluster.instances, cluster: cluster)
            await moveToNextCluster()
        } else {
            state = .confirmingMatches(label, candidates.map { $0.instance.id })
        }
    }
    
    func confirmationCompleted(label: String, result: ConfirmationResult) async {
        guard let cluster = currentCluster else { return }
        state = .applyingLabels
        
        var allInstancesToLabel = cluster.instances
        allInstancesToLabel.append(contentsOf: result.acceptedInstances)
        allInstancesToLabel.append(contentsOf: result.autoAcceptedInstances)
        
        await applyLabelToInstances(label: label, instances: allInstancesToLabel, cluster: cluster)
        await moveToNextCluster()
    }
    
    func cancelWorkflow() {
        state = .idle
        currentCluster = nil
    }
    
    private func applyLabelToInstances(label: String, instances: [ObjectInstance], cluster: UnlabeledCluster) async {
        do {
            try await recognitionEngine.applyLabel(label: label, to: instances.map { $0.id })
            try await recognitionEngine.markClusterAsPresented(clusterID: cluster.id, label: label)
            
            if let index = unlabeledClusters.firstIndex(where: { $0.id == cluster.id }) {
                unlabeledClusters[index].hasBeenPresented = true
                unlabeledClusters[index].userLabel = label
                unlabeledClusters[index].labeledAt = Date()
            }
        } catch {}
    }
    
    func getCurrentRepresentativeInstance() -> ObjectInstance? {
        currentCluster?.representativeInstance
    }
    
    func skipCurrentCluster() async {
        guard let cluster = currentCluster else { return }
        do {
            try await recognitionEngine.markClusterAsPresented(clusterID: cluster.id, label: nil)
        } catch {}
        await moveToNextCluster()
    }
    
    func getProgress() -> (labeled: Int, remaining: Int, total: Int) {
        let total = unlabeledClusters.count
        let labeled = unlabeledClusters.filter { $0.hasBeenPresented }.count
        return (labeled: labeled, remaining: total - labeled, total: total)
    }
    
    // Helper to get candidates for current confirmation state
    func getCurrentConfirmationCandidates() -> [SimilarInstance] {
        guard case .confirmingMatches(_, let instanceIDs) = state else { return [] }
        return instanceIDs.compactMap { id in
            guard let instance = allInstances.first(where: { $0.id == id }) else { return nil }
            let similarity = similarityService.calculateSimilarity(
                instance.embedding,
                currentCluster?.representativeInstance?.embedding ?? []
            )
            return SimilarInstance(instance: instance, similarity: similarity)
        }
    }
}

// NOTE: Real implementations are in ObjectRecognitionEngine.swift
// - getUnlabeledClusters() -> calls getPendingClusters()
// - getAllInstances() -> fetches from storage
// - applyLabel() -> updates instances in storage
// - markClusterAsPresented() -> updates cluster in storage

extension SimilaritySearchService {
    func calculateSimilarity(_ a: [Float], _ b: [Float]) -> Float {
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
