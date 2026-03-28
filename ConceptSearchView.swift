//
//  ConceptSearchView.swift
//  Vision Builder
//
//  Text-prompted object discovery UI. Type a description to find matching objects.
//

import SwiftUI

struct ConceptSearchView: View {
    var recognitionEngine: ObjectRecognitionEngine?
    @StateObject private var searchService = ConceptSearchService()
    @State private var queryText = ""
    @State private var suggestions: [String] = []
    @State private var selectedResults: Set<UUID> = []
    @State private var showingLabelSheet = false
    @State private var labelText = ""
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                searchBar

                if searchService.isSearching {
                    Spacer()
                    ProgressView("Searching...")
                    Spacer()
                } else if searchService.statusMessage != nil {
                    noResultsView
                } else if searchService.results.isEmpty && !searchService.lastQuery.isEmpty {
                    noResultsView
                } else if searchService.results.isEmpty {
                    suggestionsView
                } else {
                    resultsView
                }
            }
            .navigationTitle("Find Objects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !selectedResults.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Label (\(selectedResults.count))") {
                            labelText = queryText
                            showingLabelSheet = true
                        }
                    }
                }
            }
            .task {
                suggestions = (try? searchService.suggestedQueries()) ?? []
            }
            .sheet(isPresented: $showingLabelSheet) {
                labelSheet
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("What are you looking for?", text: $queryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { performSearch() }
            if !queryText.isEmpty {
                Button {
                    queryText = ""
                    searchService.results = []
                    searchService.lastQuery = ""
                    selectedResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Suggestions

    private var suggestionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Try searching for:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                FlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            queryText = suggestion
                            performSearch()
                        } label: {
                            Text(suggestion)
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray5))
                                .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 24)
        }
    }

    // MARK: - No Results

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: searchService.statusMessage != nil ? "exclamationmark.triangle" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            if let status = searchService.statusMessage {
                Text(status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("No matches for \"\(searchService.lastQuery)\"")
                    .font(.headline)
                Text("Try a different description or scan more photos.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Results Grid

    private var resultsView: some View {
        VStack(spacing: 8) {
            // Results count
            HStack {
                Text("\(searchService.results.count) matches")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if !selectedResults.isEmpty {
                    Button("Clear Selection") {
                        selectedResults.removeAll()
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(searchService.results) { result in
                        resultCell(result)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
    }

    private func resultCell(_ result: ConceptSearchService.SearchResult) -> some View {
        let isSelected = selectedResults.contains(result.id)

        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                if let data = result.instance.cropImageData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 90, height: 90)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 90, height: 90)
                        .cornerRadius(8)
                }

                // Similarity score
                Text(String(format: "%.0f%%", result.similarity * 100))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .background(Circle().fill(.white).padding(2))
                    .offset(x: -4, y: 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            if selectedResults.contains(result.id) {
                selectedResults.remove(result.id)
            } else {
                selectedResults.insert(result.id)
            }
        }
    }

    // MARK: - Label Sheet

    private var labelSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Label \(selectedResults.count) objects")
                    .font(.headline)

                TextField("Label name", text: $labelText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Button("Apply Label") {
                    applyLabel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(labelText.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Label Objects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { showingLabelSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func performSearch() {
        Task {
            await searchService.search(query: queryText)
            selectedResults.removeAll()
        }
    }

    private func applyLabel() {
        let label = labelText.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        let count = selectedResults.count
        let ids = Array(selectedResults)

        Task {
            let engine = recognitionEngine ?? ObjectRecognitionEngine()
            try? await engine.applyLabel(label: label, to: ids)
            showingLabelSheet = false
            selectedResults.removeAll()
            ToastManager.shared.showSuccess("Labeled \(count) objects as '\(label)'")
        }
    }
}

// MARK: - Flow Layout for Suggestion Chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
