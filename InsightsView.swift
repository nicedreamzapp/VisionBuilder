// InsightsView.swift
// Dataset insights and analytics dashboard
import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    @StateObject private var dataQualityManager = DataQualityManager()
    @State private var qualityReport: DataQualityManager.QualityReport?
    @State private var recognitionStats: RecognitionStatistics?
    @State private var labelFolders: [LabelFolderStats] = []
    @State private var isLoading = true
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    loadingView
                } else if hasData {
                    insightsContent
                } else {
                    emptyStateView
                }
            }
            .background(
                LinearGradient(
                    colors: [Color.blue.opacity(0.05), Color.purple.opacity(0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Insights")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refreshData() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .task {
            await refreshData()
        }
    }

    private var hasData: Bool {
        !labelFolders.isEmpty || (qualityReport?.totalBoxes ?? 0) > 0
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Analyzing dataset...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Data Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start labeling objects to see insights\nabout your dataset quality and progress")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                NotificationCenter.default.post(name: .switchToDatasetTab, object: nil)
            } label: {
                Label("Go to Dataset", systemImage: "folder.fill")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Insights Content

    private var insightsContent: some View {
        LazyVStack(spacing: 20) {
            // Summary Cards
            summaryCardsSection

            // Quality Distribution Chart
            if let report = qualityReport, !report.imageQualityScores.isEmpty {
                qualityDistributionSection(report: report)
            }

            // Labels Breakdown
            if !labelFolders.isEmpty {
                labelsBreakdownSection
            }

            // Issues Summary
            if let report = qualityReport, report.hasIssues {
                issuesSummarySection(report: report)
            }

            // Recognition Stats
            if let stats = recognitionStats {
                recognitionStatsSection(stats: stats)
            }
        }
        .padding()
    }

    // MARK: - Summary Cards

    private var summaryCardsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            SummaryCard(
                title: "Total Objects",
                value: "\(qualityReport?.totalBoxes ?? 0)",
                icon: "square.on.square",
                color: .blue
            )

            SummaryCard(
                title: "Labels",
                value: "\(labelFolders.count)",
                icon: "tag.fill",
                color: .green
            )

            SummaryCard(
                title: "Avg Quality",
                value: String(format: "%.0f%%", qualityReport?.averageQualityScore ?? 0),
                icon: "star.fill",
                color: qualityColor(for: qualityReport?.averageQualityScore ?? 0)
            )

            SummaryCard(
                title: "Issues",
                value: "\(qualityReport?.totalIssues ?? 0)",
                icon: "exclamationmark.triangle.fill",
                color: (qualityReport?.totalIssues ?? 0) > 0 ? .orange : .green
            )
        }
    }

    // MARK: - Quality Distribution

    private func qualityDistributionSection(report: DataQualityManager.QualityReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quality Distribution")
                .font(.headline)

            let distribution = calculateQualityDistribution(report.imageQualityScores)

            if #available(iOS 16.0, *) {
                Chart(distribution, id: \.rating) { item in
                    BarMark(
                        x: .value("Rating", item.rating),
                        y: .value("Count", item.count)
                    )
                    .foregroundStyle(item.color.gradient)
                    .cornerRadius(4)
                }
                .frame(height: 200)
                .chartYAxisLabel("Objects")
            } else {
                // Fallback for iOS 15
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(distribution, id: \.rating) { item in
                        VStack {
                            Text("\(item.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(item.color)
                                .frame(width: 50, height: CGFloat(item.count) * 10)

                            Text(item.rating)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Labels Breakdown

    private var labelsBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Labels Breakdown")
                    .font(.headline)
                Spacer()
                Text("\(labelFolders.reduce(0) { $0 + $1.objectCount }) total")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(labelFolders.sorted { $0.objectCount > $1.objectCount }.prefix(10), id: \.name) { folder in
                HStack {
                    Text(folder.name)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    Text("\(folder.objectCount)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    // Progress bar
                    let maxCount = labelFolders.map(\.objectCount).max() ?? 1
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.3))
                            .frame(width: geo.size.width * CGFloat(folder.objectCount) / CGFloat(maxCount))
                    }
                    .frame(width: 80, height: 8)
                }
            }

            if labelFolders.count > 10 {
                Text("+ \(labelFolders.count - 10) more labels")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Issues Summary

    private func issuesSummarySection(report: DataQualityManager.QualityReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quality Issues")
                .font(.headline)

            if !report.blurryImages.isEmpty {
                IssueRow(
                    icon: "camera.filters",
                    title: "Blurry Images",
                    count: report.blurryImages.count,
                    color: .red
                )
            }

            if !report.tinyBoxes.isEmpty {
                IssueRow(
                    icon: "square.dashed",
                    title: "Small Objects",
                    count: report.tinyBoxes.count,
                    color: .orange
                )
            }

            if !report.overlappingBoxes.isEmpty {
                IssueRow(
                    icon: "square.on.square",
                    title: "Overlapping Boxes",
                    count: report.overlappingBoxes.count,
                    color: .purple
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Recognition Stats

    private func recognitionStatsSection(stats: RecognitionStatistics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recognition Engine")
                .font(.headline)

            HStack(spacing: 20) {
                StatItem(title: "Unique Objects", value: "\(stats.totalIdentities)", icon: "brain")
                StatItem(title: "Total Sightings", value: "\(stats.totalInstances)", icon: "photo.stack")
                StatItem(title: "Pending", value: "\(stats.pendingClusters)", icon: "tray.full")
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Helper Methods

    private func refreshData() async {
        isLoading = true

        // Fetch quality report
        qualityReport = await dataQualityManager.analyzeDatasetQuality()

        // Fetch label folders
        labelFolders = await fetchLabelFolders()

        // Fetch recognition stats
        do {
            let engine = ObjectRecognitionEngine()
            recognitionStats = try engine.getStatistics()
        } catch {
            print("Failed to get recognition stats: \(error)")
        }

        isLoading = false
    }

    private func fetchLabelFolders() async -> [LabelFolderStats] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var folders: [LabelFolderStats] = []

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: documentsPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for url in contents {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      !url.lastPathComponent.hasPrefix("."),
                      url.lastPathComponent != "Dataset",
                      url.lastPathComponent != "SAM2.1_Small_Models" else {
                    continue
                }

                let objectFolders = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("Object_") }

                if !objectFolders.isEmpty {
                    folders.append(LabelFolderStats(
                        name: url.lastPathComponent,
                        objectCount: objectFolders.count
                    ))
                }
            }
        } catch {
            print("Error fetching label folders: \(error)")
        }

        return folders
    }

    private func calculateQualityDistribution(_ scores: [DataQualityManager.ImageQualityScore]) -> [QualityBucket] {
        var excellent = 0, good = 0, fair = 0, poor = 0

        for score in scores {
            switch score.rating {
            case .excellent: excellent += 1
            case .good: good += 1
            case .fair: fair += 1
            case .poor: poor += 1
            }
        }

        return [
            QualityBucket(rating: "Excellent", count: excellent, color: .green),
            QualityBucket(rating: "Good", count: good, color: .blue),
            QualityBucket(rating: "Fair", count: fair, color: .orange),
            QualityBucket(rating: "Poor", count: poor, color: .red)
        ]
    }

    private func qualityColor(for score: Float) -> Color {
        switch score {
        case 90...100: return .green
        case 70..<90: return .blue
        case 50..<70: return .orange
        default: return .red
        }
    }
}

// MARK: - Supporting Types

struct LabelFolderStats: Identifiable {
    let id = UUID()
    let name: String
    let objectCount: Int
}

struct QualityBucket {
    let rating: String
    let count: Int
    let color: Color
}

// MARK: - Subviews

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
            }

            Text(value)
                .font(.title)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

struct IssueRow: View {
    let icon: String
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)

            Text(title)
                .font(.subheadline)

            Spacer()

            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.1))
                .cornerRadius(8)
        }
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)

            Text(value)
                .font(.headline)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    InsightsView()
}
