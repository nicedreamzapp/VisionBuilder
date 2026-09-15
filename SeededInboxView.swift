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
        .onAppear { if groups.isEmpty { groups = SeededStore.load() } }
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
            names[g.id] = value.trimmingCharacters(in: .whitespaces)
            SeededStore.save(names: names)
        }
        name = ""
        fieldFocused = false
        index += 1
    }
}
