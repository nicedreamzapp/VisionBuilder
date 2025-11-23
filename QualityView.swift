// QualityView.swift
// Detailed quality analysis and issue management
import SwiftUI

struct QualityView: View {
    @StateObject private var dataQualityManager = DataQualityManager()
    @State private var qualityReport: DataQualityManager.QualityReport?
    @State private var isLoading = true
    @State private var selectedIssueType: IssueFilter = .all
    @State private var showingDeleteConfirmation = false
    @State private var issuesToDelete: [DataQualityManager.QualityIssue] = []

    enum IssueFilter: String, CaseIterable {
        case all = "All Issues"
        case blurry = "Blurry"
        case small = "Small Objects"
        case overlapping = "Overlapping"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    loadingView
                } else if let report = qualityReport {
                    qualityContent(report: report)
                } else {
                    emptyStateView
                }
            }
            .background(AppBackgroundGradient().ignoresSafeArea())
            .navigationTitle("Quality Analysis")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await analyzeQuality() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .alert("Delete Issues?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    Task { await deleteSelectedIssues() }
                }
            } message: {
                Text("This will permanently remove \(issuesToDelete.count) object(s) from your dataset.")
            }
        }
        .task {
            await analyzeQuality()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text("Analyzing Quality...")
                    .font(.headline)

                if dataQualityManager.isProcessing {
                    Text(dataQualityManager.currentOperation)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ProgressView(value: dataQualityManager.progress)
                        .frame(width: 200)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("No Quality Data")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Export some labeled objects to\nanalyze their quality")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Quality Content

    private func qualityContent(report: DataQualityManager.QualityReport) -> some View {
        LazyVStack(spacing: 20) {
            // Quality Score Overview
            qualityScoreCard(report: report)

            // Quality Breakdown
            qualityBreakdownCard(report: report)

            // Issue Filter
            if report.hasIssues {
                issueFilterPicker

                // Issues List
                issuesList(report: report)
            } else {
                noIssuesCard
            }

            // Excellent Images Section
            if !report.excellentImages.isEmpty {
                excellentImagesCard(images: report.excellentImages)
            }
        }
        .padding()
    }

    // MARK: - Quality Score Card

    private func qualityScoreCard(report: DataQualityManager.QualityReport) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Overall Quality Score")
                    .font(.headline)
                Spacer()
            }

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 12)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: CGFloat(report.averageQualityScore) / 100)
                    .stroke(
                        qualityGradient(for: report.averageQualityScore),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text(String(format: "%.0f", report.averageQualityScore))
                        .font(.system(size: 36, weight: .bold))

                    Text("/ 100")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(qualityDescription(for: report.averageQualityScore))
                .font(.subheadline)
                .foregroundColor(qualityColor(for: report.averageQualityScore))
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Quality Breakdown Card

    private func qualityBreakdownCard(report: DataQualityManager.QualityReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quality Breakdown")
                .font(.headline)

            HStack(spacing: 16) {
                QualityMetricView(
                    title: "Total Objects",
                    value: "\(report.totalBoxes)",
                    icon: "square.grid.2x2",
                    color: .blue
                )

                QualityMetricView(
                    title: "Excellent",
                    value: "\(report.excellentImages.count)",
                    icon: "star.fill",
                    color: .green
                )

                QualityMetricView(
                    title: "Issues",
                    value: "\(report.totalIssues)",
                    icon: "exclamationmark.triangle",
                    color: report.totalIssues > 0 ? .orange : .green
                )
            }

            if report.totalBoxes > 0 {
                // Quality distribution bar
                VStack(alignment: .leading, spacing: 8) {
                    Text("Distribution")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            let total = Float(report.imageQualityScores.count)
                            let excellent = Float(report.imageQualityScores.filter { $0.rating == .excellent }.count)
                            let good = Float(report.imageQualityScores.filter { $0.rating == .good }.count)
                            let fair = Float(report.imageQualityScores.filter { $0.rating == .fair }.count)
                            let poor = Float(report.imageQualityScores.filter { $0.rating == .poor }.count)

                            if total > 0 {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.green)
                                    .frame(width: geometry.size.width * CGFloat(excellent / total))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.blue)
                                    .frame(width: geometry.size.width * CGFloat(good / total))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.orange)
                                    .frame(width: geometry.size.width * CGFloat(fair / total))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.red)
                                    .frame(width: geometry.size.width * CGFloat(poor / total))
                            }
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Label("Excellent", systemImage: "circle.fill").font(.caption2).foregroundColor(.green)
                        Label("Good", systemImage: "circle.fill").font(.caption2).foregroundColor(.blue)
                        Label("Fair", systemImage: "circle.fill").font(.caption2).foregroundColor(.orange)
                        Label("Poor", systemImage: "circle.fill").font(.caption2).foregroundColor(.red)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Issue Filter

    private var issueFilterPicker: some View {
        Picker("Filter", selection: $selectedIssueType) {
            ForEach(IssueFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Issues List

    private func issuesList(report: DataQualityManager.QualityReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Issues Found")
                    .font(.headline)

                Spacer()

                if !filteredIssues(report: report).isEmpty {
                    Button("Delete All") {
                        issuesToDelete = filteredIssues(report: report)
                        showingDeleteConfirmation = true
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }

            ForEach(filteredIssues(report: report)) { issue in
                IssueCard(issue: issue) {
                    issuesToDelete = [issue]
                    showingDeleteConfirmation = true
                }
            }

            if filteredIssues(report: report).isEmpty {
                Text("No issues of this type")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - No Issues Card

    private var noIssuesCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)

            Text("No Quality Issues!")
                .font(.headline)

            Text("Your dataset is looking great")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Excellent Images Card

    private func excellentImagesCard(images: [DataQualityManager.ImageQualityScore]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("Top Quality Images")
                    .font(.headline)
                Spacer()
                Text("\(images.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(images.prefix(5)) { score in
                HStack {
                    VStack(alignment: .leading) {
                        Text(score.labelFolder)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(score.objectFolder)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(String(format: "%.0f%%", score.overallScore))
                        .font(.headline)
                        .foregroundColor(.green)
                }
                .padding(.vertical, 4)
            }

            if images.count > 5 {
                Text("+ \(images.count - 5) more excellent images")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    // MARK: - Helper Methods

    private func analyzeQuality() async {
        isLoading = true
        qualityReport = await dataQualityManager.analyzeDatasetQuality()
        isLoading = false
    }

    private func deleteSelectedIssues() async {
        let result = await dataQualityManager.removeItems(issuesToDelete)
        print("Deleted \(result.removed) items, \(result.failed) failed")
        issuesToDelete = []
        await analyzeQuality()
    }

    private func filteredIssues(report: DataQualityManager.QualityReport) -> [DataQualityManager.QualityIssue] {
        switch selectedIssueType {
        case .all:
            return report.blurryImages + report.tinyBoxes + report.overlappingBoxes
        case .blurry:
            return report.blurryImages
        case .small:
            return report.tinyBoxes
        case .overlapping:
            return report.overlappingBoxes
        }
    }

    private func qualityGradient(for score: Float) -> LinearGradient {
        let color = qualityColor(for: score)
        return LinearGradient(
            colors: [color.opacity(0.8), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func qualityColor(for score: Float) -> Color {
        switch score {
        case 90...100: return .green
        case 70..<90: return .blue
        case 50..<70: return .orange
        default: return .red
        }
    }

    private func qualityDescription(for score: Float) -> String {
        switch score {
        case 90...100: return "Excellent Quality"
        case 70..<90: return "Good Quality"
        case 50..<70: return "Fair Quality"
        default: return "Needs Improvement"
        }
    }
}

// MARK: - Supporting Views

struct QualityMetricView: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct IssueCard: View {
    let issue: DataQualityManager.QualityIssue
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: issue.type.icon)
                .foregroundColor(issue.type.color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(issueTypeLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(issue.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let firstItem = issue.affectedItems.first {
                    Text(firstItem.labelFolder.lastPathComponent)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }

            Spacer()

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(issue.type.color.opacity(0.05))
        .cornerRadius(8)
    }

    private var issueTypeLabel: String {
        switch issue.type {
        case .blurryImage: return "Blurry Image"
        case .tinyBox: return "Small Object"
        case .overlappingBoxes: return "Overlapping Boxes"
        }
    }
}

#Preview {
    QualityView()
}
