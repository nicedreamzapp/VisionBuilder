//
//  SeededInboxView.swift
//  Vision Builder
//
//  Shows pre-computed groups exactly as the on-device pipeline would present them,
//  so the naming flow can be exercised on real photos without waiting for the phone
//  to scan the whole library. Groups are produced on a Mac by the same models the
//  app bundles (DINOv2-small identity embeddings, cosine distance 0.75) and copied
//  into Documents/seeded/.
//
//  This tab only exists when Documents/seeded/groups.json is present.
//

import SwiftUI

struct SeededGroup: Codable, Identifiable {
    let id: Int
    let kind: String
    let total: Int
    let photos: [String]
}

enum SeededStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("seeded", isDirectory: true)
    }
    static var manifest: URL { folder.appendingPathComponent("groups.json") }
    static var namesFile: URL { folder.appendingPathComponent("names.json") }

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: manifest.path) }

    static func load() -> [SeededGroup] {
        guard let data = try? Data(contentsOf: manifest),
              let groups = try? JSONDecoder().decode([SeededGroup].self, from: data) else { return [] }
        return groups
    }

    static func loadNames() -> [Int: String] {
        guard let data = try? Data(contentsOf: namesFile),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [Int: String] = [:]
        for r in rows { if let id = r["id"] as? Int, let n = r["name"] as? String { out[id] = n } }
        return out
    }

    static var adoptedFile: URL { folder.appendingPathComponent("adopted.json") }

    /// "Theo1", "Theo3", "Chicken1": the Name tab could not reuse a name, so extra
    /// groups of the same animal got a number. Fold those back into one identity.
    static func baseLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = trimmed.replacingOccurrences(of: "\\s*\\d+$", with: "", options: .regularExpression)
        return base.isEmpty ? trimmed : base
    }

    @MainActor
    static func adoptPendingNames() async {
        guard isAvailable else { return }
        let names = loadNames()
        var adopted = Set((try? JSONDecoder().decode([Int].self, from: Data(contentsOf: adoptedFile))) ?? [])
        let groups = Dictionary(uniqueKeysWithValues: load().map { ($0.id, $0) })
        let engine = ObjectRecognitionEngine()
        for (id, name) in names.sorted(by: { $0.key < $1.key }) where !name.isEmpty && !adopted.contains(id) {
            guard let g = groups[id] else { continue }
            let images = g.photos.compactMap { UIImage(contentsOfFile: folder.appendingPathComponent($0).path) }
            do {
                _ = try await engine.adoptSeededGroup(label: baseLabel(name), images: images)
                adopted.insert(id)
                if let data = try? JSONEncoder().encode(Array(adopted)) { try? data.write(to: adoptedFile) }
            } catch {
                print("⚠️ Could not add '\(name)': \(error)")
            }
        }
    }

    static func save(names: [Int: String]) {
        let payload = names.map { ["id": $0.key, "name": $0.value] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: namesFile)
        }
    }
}

struct SeededInboxView: View {
    @State private var groups: [SeededGroup] = []
    @State private var index = 0
    @State private var name = ""
    @State private var names: [Int: String] = [:]
    @FocusState private var fieldFocused: Bool

    private var current: SeededGroup? { index < groups.count ? groups[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let g = current {
                    card(for: g)
                } else {
                    finished
                }
            }
            .navigationTitle("What is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !groups.isEmpty && current != nil {
                        Text("\(index + 1) of \(groups.count)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            guard groups.isEmpty else { return }
            groups = SeededStore.load()
            names = SeededStore.loadNames()
            // Pick up where the last session stopped instead of at group 1.
            index = groups.firstIndex { names[$0.id] == nil } ?? groups.count
        }
    }

    private func card(for g: SeededGroup) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(g.kind.uppercased())
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(Color.appBlue)
                Text("· \(g.total) photos")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal).padding(.top, 6)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(Array(g.photos.prefix(12).enumerated()), id: \.offset) { _, rel in
                        if let img = UIImage(contentsOfFile: SeededStore.folder.appendingPathComponent(rel).path) {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(height: 110).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 8)

                if g.total > 12 {
                    Text("+ \(g.total - 12) more in this group")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.top, 6)
                }
            }

            VStack(spacing: 10) {
                TextField("name it — Theo, my truck, the shop…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { advance(with: name) }

                HStack(spacing: 8) {
                    Button("Not one thing") { advance(with: "") }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    Button("Save") { advance(with: name) }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    private var finished: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Color.appGreen)
            Text("Done").font(.title2).fontWeight(.semibold)
            Text("\(names.values.filter { !$0.isEmpty }.count) named, \(groups.count - names.values.filter { !$0.isEmpty }.count) skipped")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Start over") { index = 0; name = "" }
                .buttonStyle(.bordered).padding(.top, 4)
        }
        .padding()
    }

    private func advance(with value: String) {
        if let g = current {
            let label = value.trimmingCharacters(in: .whitespaces)
            names[g.id] = label
            SeededStore.save(names: names)
            if !label.isEmpty {
                Task { @MainActor in await SeededStore.adoptPendingNames() }
            }
        }
        name = ""
        fieldFocused = false
        index += 1
    }
}
