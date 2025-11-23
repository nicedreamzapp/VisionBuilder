import Foundation
import SwiftData
import UIKit
import Combine

/// Manages active learning workflow - finding and labeling similar instances
@MainActor
class ActiveLearningManager: ObservableObject {
    
    @Published var isProcessing = false
    @Published var currentOperation = ""
    @Published var progress = 0.0
    
    // Active learning state
    @Published var activeLearningSession: ActiveLearningSession?
    @Published var currentSuggestions: [SimilarInstance] = []
    @Published var selectedForLabeling: Set<UUID> = []
    
    private let recognitionEngine = ObjectRecognitionEngine()
    private let embeddingService = EmbeddingService()
    
    // MARK: - Types
    
    struct ActiveLearningSession {
        let sourceInstance: ObjectInstance
        let proposedLabel: String
        let createdAt: Date
        var labeledCount: Int = 0
        var skippedCount: Int = 0
    }
    
    struct SimilarInstance: Identifiable {
        let id: UUID
        let instance: ObjectInstance
        let similarity: Float
        var isSelected: Bool = false
        var userAction: UserAction?
        
        enum UserAction {
            case accepted
            case rejected
            case deferred
        }
    }
    
    // MARK: - Start Active Learning Session
    
    /// Start active learning from a newly labeled cluster
    func startSessionFromCluster(_ cluster: UnlabeledCluster, label: String) async throws {
        guard let representative = cluster.representativeInstance else {
            throw ActiveLearningError.noRepresentativeInstance
        }
        
        isProcessing = true
        currentOperation = "Finding similar objects..."
        progress = 0.3
        
        // Create session
        let session = ActiveLearningSession(
            sourceInstance: representative,
            proposedLabel: label,
            createdAt: Date()
        )
        activeLearningSession = session
        
        // Find similar instances
        let similar = try findSimilarInstances(to: representative.embedding, limit: 20)
        
        currentSuggestions = similar.map { instance, similarity in
            SimilarInstance(
                id: instance.id,
                instance: instance,
                similarity: similarity
            )
        }
        
        progress = 1.0
        currentOperation = "Found \(currentSuggestions.count) similar objects"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isProcessing = false
            self.currentOperation = ""
        }
    }
    
    /// Start active learning from an existing identity
    func startSessionFromIdentity(_ identity: ObjectIdentity) async throws {
        isProcessing = true
        currentOperation = "Analyzing \(identity.label)..."
        progress = 0.3
        
        // Use the identity's prototype embedding
        let session = ActiveLearningSession(
            sourceInstance: identity.instances.first!,
            proposedLabel: identity.label,
            createdAt: Date()
        )
        activeLearningSession = session
        
        // Find similar unlabeled instances
        let similar = try findSimilarInstances(to: identity.prototypeEmbedding, limit: 20)
        
        currentSuggestions = similar.map { instance, similarity in
            SimilarInstance(
                id: instance.id,
                instance: instance,
                similarity: similarity
            )
        }
        
        progress = 1.0
        currentOperation = "Found \(currentSuggestions.count) candidates"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isProcessing = false
            self.currentOperation = ""
        }
    }
    
    // MARK: - User Actions
    
    func toggleSelection(for instanceID: UUID) {
        if selectedForLabeling.contains(instanceID) {
            selectedForLabeling.remove(instanceID)
        } else {
            selectedForLabeling.insert(instanceID)
        }
    }
    
    func selectAll() {
        selectedForLabeling = Set(currentSuggestions.map { $0.id })
    }
    
    func deselectAll() {
        selectedForLabeling.removeAll()
    }
    
    // MARK: - Batch Labeling
    
    /// Label all selected instances with the proposed label
    func labelSelectedInstances() async throws {
        guard let session = activeLearningSession else {
            throw ActiveLearningError.noActiveSession
        }
        
        guard !selectedForLabeling.isEmpty else {
            throw ActiveLearningError.noInstancesSelected
        }
        
        isProcessing = true
        currentOperation = "Labeling \(selectedForLabeling.count) objects..."
        
        // Get or create identity
        let identity = try getOrCreateIdentity(label: session.proposedLabel, sourceInstance: session.sourceInstance)
        
        var labeled = 0
        let total = selectedForLabeling.count
        
        // Label each selected instance
        for instanceID in selectedForLabeling {
            guard let suggestion = currentSuggestions.first(where: { $0.id == instanceID }) else {
                continue
            }
            
            // Add instance to identity
            try recognitionEngine.addInstanceToIdentity(
                instance: suggestion.instance,
                identity: identity
            )
            
            labeled += 1
            progress = Double(labeled) / Double(total)
            currentOperation = "Labeled \(labeled)/\(total)..."
            
            // Small delay for UI feedback
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        
        // Update session stats
        var updatedSession = session
        updatedSession.labeledCount += labeled
        activeLearningSession = updatedSession
        
        // Remove labeled instances from suggestions
        currentSuggestions.removeAll { selectedForLabeling.contains($0.id) }
        selectedForLabeling.removeAll()
        
        currentOperation = "✅ Labeled \(labeled) objects as '\(session.proposedLabel)'"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.isProcessing = false
            self.currentOperation = ""
        }
    }
    
    /// Skip selected instances (mark as reviewed but not labeled)
    func skipSelectedInstances() async {
        guard var session = activeLearningSession else { return }
        
        let skipCount = selectedForLabeling.count
        session.skippedCount += skipCount
        activeLearningSession = session
        
        // Remove from suggestions
        currentSuggestions.removeAll { selectedForLabeling.contains($0.id) }
        selectedForLabeling.removeAll()
    }
    
    /// End the active learning session
    func endSession() {
        activeLearningSession = nil
        currentSuggestions.removeAll()
        selectedForLabeling.removeAll()
    }
    
    // MARK: - Helper Methods
    
    private func findSimilarInstances(to embedding: [Float], limit: Int) throws -> [(ObjectInstance, Float)] {
        let context = ObjectRecognitionStorage.shared.context
        
        // Fetch all unlabeled instances
        let descriptor = FetchDescriptor<ObjectInstance>(
            predicate: #Predicate<ObjectInstance> { instance in
                instance.identity == nil && instance.embedding.count > 0
            }
        )
        
        let unlabeledInstances = try context.fetch(descriptor)
        
        var results: [(ObjectInstance, Float)] = []
        
        for instance in unlabeledInstances {
            let similarity = EmbeddingService.cosineSimilarity(embedding, instance.embedding)
            
            // Only include high-confidence matches (>70% similarity)
            if similarity >= 0.70 {
                results.append((instance, similarity))
            }
        }
        
        // Sort by similarity and take top N
        return results
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }
    
    private func getOrCreateIdentity(label: String, sourceInstance: ObjectInstance) throws -> ObjectIdentity {
        // Try to find existing identity with this label
        let existing = try recognitionEngine.searchIdentities(query: label)
        if let match = existing.first(where: { $0.label.lowercased() == label.lowercased() }) {
            return match
        }
        
        // Create new identity
        return try recognitionEngine.learnNewIdentity(label: label, instance: sourceInstance)
    }
}

// MARK: - Errors

enum ActiveLearningError: Error, LocalizedError {
    case noRepresentativeInstance
    case noActiveSession
    case noInstancesSelected
    
    var errorDescription: String? {
        switch self {
        case .noRepresentativeInstance:
            return "Cluster has no representative instance"
        case .noActiveSession:
            return "No active learning session in progress"
        case .noInstancesSelected:
            return "No instances selected for labeling"
        }
    }
}

// MARK: - Statistics

extension ActiveLearningManager {
    func getSessionStats() -> SessionStatistics? {
        guard let session = activeLearningSession else { return nil }
        
        return SessionStatistics(
            label: session.proposedLabel,
            candidatesFound: currentSuggestions.count + session.labeledCount + session.skippedCount,
            labeledCount: session.labeledCount,
            skippedCount: session.skippedCount,
            remainingCount: currentSuggestions.count,
            startedAt: session.createdAt,
            averageSimilarity: calculateAverageSimilarity()
        )
    }
    
    private func calculateAverageSimilarity() -> Float {
        guard !currentSuggestions.isEmpty else { return 0 }
        
        let sum = currentSuggestions.reduce(0) { $0 + $1.similarity }
        return sum / Float(currentSuggestions.count)
    }
}

struct SessionStatistics {
    let label: String
    let candidatesFound: Int
    let labeledCount: Int
    let skippedCount: Int
    let remainingCount: Int
    let startedAt: Date
    let averageSimilarity: Float
}
