import SwiftUI

@main
struct Vision_BuilderApp: App {
    @State private var showUpgradePrompt = UpgradePromptView.shouldShow

    init() {
        // Perform any pending database reset BEFORE storage singleton initializes
        ObjectRecognitionStorage.performPendingResetIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(DatasetManager())
                .environmentObject(ExportManager())
                .fullScreenCover(isPresented: $showUpgradePrompt) {
                    UpgradePromptView(
                        isPresented: $showUpgradePrompt,
                        onFreshStart: {
                            // Wipe data in place — no relaunch. (The old code called
                            // exit(0), which looks like a crash to the user and is an
                            // App Store rejection.)
                            ObjectRecognitionStorage.resetDatabaseNow()
                            NotificationCenter.default.post(name: .datasetDidReset, object: nil)
                        },
                        onKeepData: {
                            // Keep existing data
                        }
                    )
                }
        }
    }
}
