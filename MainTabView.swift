//
//  MainTabView.swift
//  Vision Builder
//

import SwiftUI
import SwiftData

struct MainTabView: View {
    @StateObject private var exportManager = ExportManager()
    @StateObject private var datasetManager = DatasetManager()
    @State private var selectedTab = 1 // Start on Dataset tab
    @State private var recognitionEngine: ObjectRecognitionEngine?

    // Dynamic accent color based on selected tab
    private var tabAccentColor: Color {
        switch selectedTab {
        case 0: return .appBlue      // Label tab
        case 1: return .appGreen     // Dataset tab
        case 2: return .appOrange    // Inbox tab
        case 3: return .appPurple    // Insights tab
        default: return .appBlue
        }
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
            // Label Tab
            LabelNavigationView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Label", systemImage: "camera.fill")
                }
                .tag(0)
                .environmentObject(datasetManager)

            // Dataset Tab
            DatasetTabView(recognitionEngine: recognitionEngine)
                .tabItem {
                    Label("Dataset", systemImage: "folder.fill")
                }
                .tag(1)
                .environmentObject(exportManager)
                .environmentObject(datasetManager)

            // Morning Inbox Tab
            if let engine = recognitionEngine {
                MorningInboxView(recognitionEngine: engine)
                    .tabItem {
                        Label("Inbox", systemImage: "tray.fill")
                    }
                    .tag(2)
                    .modelContainer(ObjectRecognitionStorage.shared.container)
            } else {
                ProgressView()
                    .tabItem {
                        Label("Inbox", systemImage: "tray.fill")
                    }
                    .tag(2)
            }

            // Insights Tab
            InsightsView()
                .tabItem {
                    Label("Insights", systemImage: "chart.bar.fill")
                }
                .tag(3)
            }
            .tint(tabAccentColor)
            .onChange(of: selectedTab) { _, _ in
                if AppSettings.UI.enableHaptics {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToLabelTab)) { _ in
                selectedTab = 0
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToDatasetTab)) { _ in
                selectedTab = 1
            }
        }
        .withToasts()
    }
}

