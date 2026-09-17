//
//  MainTabView.swift
//  Vision Builder
//

import SwiftUI
import SwiftData

struct MainTabView: View {
    @StateObject private var exportManager = ExportManager()
    @StateObject private var datasetManager = DatasetManager()
    // Land on the naming flow when seeded groups are waiting, else Dataset.
    @State private var showCleanup = false
    @State private var showExport = false
    @State private var showCapture = false
    @State private var selectedTab = SeededStore.unnamedCount > 0 ? 5 : 1
    @State private var recognitionEngine: ObjectRecognitionEngine?
    @State private var pendingClusterCount = 0

    // Dynamic accent color based on selected tab
    private var tabAccentColor: Color {
        switch selectedTab {
        case 1: return .appGreen     // My Things
        case 4: return .appTeal      // Live
        case 5: return .appBlue      // Name
        default: return .appBlue
        }
    }

    var body: some View {
        ZStack {
            // Three tabs, simplified 2026-09-16: what you have, what needs a name,
            // and the camera. Adding photos and Insights moved into My Things.
            TabView(selection: $selectedTab) {
            DatasetTabView(recognitionEngine: recognitionEngine)
                .tabItem {
                    Label("My Things", systemImage: "square.grid.2x2.fill")
                }
                .tag(1)
                .environmentObject(exportManager)
                .environmentObject(datasetManager)

            NameTabView(recognitionEngine: recognitionEngine)
                .tabItem {
                    Label("Name", systemImage: "tag.fill")
                }
                .tag(5)
                .badge(pendingClusterCount + SeededStore.unnamedCount)
                .modelContainer(ObjectRecognitionStorage.shared.container)

            LiveRecognitionView()
                .tabItem {
                    Label("Live", systemImage: "eye.fill")
                }
                .tag(4)
            }
            .tint(tabAccentColor)
            .onChange(of: selectedTab) { _, _ in
                if AppSettings.UI.enableHaptics {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                refreshPendingCount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .datasetDidReset)) { _ in
                refreshPendingCount()
            }
            .onAppear {
                // Custom tab bar appearance
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor.systemBackground
                UITabBar.appearance().standardAppearance = appearance
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
            .task {
                // Initialize recognition engine on main actor
                if recognitionEngine == nil {
                    recognitionEngine = ObjectRecognitionEngine()
                }
                refreshPendingCount()
                // Names typed in the Name tab before 2026-09-16 were saved but never
                // became identities; bring them in once.
                await SeededStore.adoptPendingNames()
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToLabelTab)) { _ in
                selectedTab = 1 // My Things opens the add-photos sheet itself
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToDatasetTab)) { _ in
                selectedTab = 1
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                versionFooter
            }
        }
        .withToasts()
        // A delete list picked on the Mac opens straight into the cleanup sheet.
        .sheet(isPresented: $showCleanup) { PhotoCleanupView() }
        // The Mac asked for small copies of the camera roll (no cable needed).
        .fullScreenCover(isPresented: $showExport) { PhotoExportView() }
        // The Mac asked the phone to take a few room photos.
        .fullScreenCover(isPresented: $showCapture) { RemoteCaptureView() }
        .onAppear {
            showCleanup = CleanupStore.isAvailable
            showExport = !showCleanup && ExportStore.isRequested
            showCapture = !showCleanup && !showExport && CaptureStore.isRequested
        }
    }

    // Inconspicuous build stamp so an installed build is identifiable at a glance
    private var versionFooter: some View {
        Text(Self.versionString)
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .foregroundColor(.secondary.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 1)
            .allowsHitTesting(false)
    }

    private func refreshPendingCount() {
        pendingClusterCount = (try? recognitionEngine?.getPendingClusters().count) ?? 0
    }

    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(short) (\(build))"
    }
}

/// One place for everything waiting on a name: groups computed on the Mac first,
/// then whatever the phone's own photo scan found.
struct NameTabView: View {
    let recognitionEngine: ObjectRecognitionEngine?
    @State private var showSeeded = SeededStore.unnamedCount > 0

    var body: some View {
        if showSeeded {
            SeededInboxView(onFinished: { showSeeded = false })
        } else if let engine = recognitionEngine {
            MorningInboxView(recognitionEngine: engine)
        } else {
            ProgressView()
        }
    }
}
