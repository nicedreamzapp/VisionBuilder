import SwiftUI

@main
struct Vision_BuilderApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(DatasetManager())
                .environmentObject(ExportManager())
        }
    }
}
