import SwiftUI

@main
struct Vision_BuilderApp: App {
    @State private var showUpgradePrompt = UpgradePromptView.shouldShow

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(DatasetManager())
                .environmentObject(ExportManager())
                .fullScreenCover(isPresented: $showUpgradePrompt) {
                    UpgradePromptView(
                        isPresented: $showUpgradePrompt,
                        onFreshStart: {
                            ObjectRecognitionStorage.resetDatabase()
                        },
                        onKeepData: {
                            // Keep existing data — user can migrate later from Settings
                        }
                    )
                }
        }
    }
}
