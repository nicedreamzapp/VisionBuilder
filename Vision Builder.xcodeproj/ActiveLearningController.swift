private func loadUnlabeledClusters() async {
    do {
        print("🔄 Loading unlabeled clusters...")
        unlabeledClusters = try recognitionEngine.getPendingClusters()
        print("✅ Loaded \(unlabeledClusters.count) clusters")
        
        // Also load all instances for similarity matching
        let storage = ObjectRecognitionStorage.shared
        let context = storage.context
        let descriptor = FetchDescriptor<ObjectInstance>()
        allInstances = try context.fetch(descriptor)
        print("✅ Loaded \(allInstances.count) total instances")
    } catch {
        print("❌ Error loading clusters: \(error)")
        unlabeledClusters = []
        allInstances = []
    }
}
