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
                            // Mark for reset — will take effect on next launch
                            ObjectRecognitionStorage.resetDatabase()
                            // Force restart by exiting
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                exit(0)
                            }
                        },
                        onKeepData: {
                            // Keep existing data
                        }
                    )
                }
        }
    }
}
