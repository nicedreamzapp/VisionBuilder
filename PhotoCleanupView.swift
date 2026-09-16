//
//  PhotoCleanupView.swift
//  Vision Builder
//
//  Deletes a list of photos picked on a Mac. The Mac pulls the camera roll,
//  finds the paper photos (labels, receipts, screenshots), and Matt marks which
//  to trash on a review page. That list lands in Documents/cleanup/delete.json
//  as [{"name": "IMG_1234.HEIC", "date": "2024:05:01 10:22:03"}]. This sheet
//  matches each entry to its Photos asset and hands the whole set to
//  PHAssetChangeRequest.deleteAssets, so iOS asks once and everything goes to
//  Recently Deleted, where it can still be restored for 30 days.
//

import SwiftUI
import Photos

struct CleanupEntry: Codable {
    let name: String
    let date: String
}

enum CleanupStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cleanup", isDirectory: true)
    }
    static var listFile: URL { folder.appendingPathComponent("delete.json") }
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: listFile.path) }

    static func load() -> [CleanupEntry] {
        guard let data = try? Data(contentsOf: listFile) else { return [] }
        return (try? JSONDecoder().decode([CleanupEntry].self, from: data)) ?? []
    }

    static func finish(deleted: Int, missing: [String]) {
        let report: [String: Any] = ["deleted": deleted, "missing": missing,
                                     "at": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: folder.appendingPathComponent("done.json"))
        }
        try? FileManager.default.removeItem(at: listFile)
    }
}

struct PhotoCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [CleanupEntry] = []
    @State private var matched: [PHAsset] = []
    @State private var missing: [String] = []
    @State private var phase = "Finding the photos…"
    @State private var busy = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(.red)
                Text(phase)
                    .font(.headline).multilineTextAlignment(.center)
                if !busy && !matched.isEmpty {
                    Text("They go to Recently Deleted in Photos, so you can still get them back for 30 days.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Move \(matched.count) photos to Recently Deleted") { delete() }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
                if busy { ProgressView() }
                Button("Not now") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle("Photo cleanup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await match() }
    }

    private static let exif: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    private func match() async {
        entries = CleanupStore.load()
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            phase = "Vision Builder needs full Photos access to do this."
            busy = false
            return
        }
        let wanted = Dictionary(grouping: entries, by: { $0.name.uppercased() })
        let result: ([PHAsset], [String]) = await Task.detached(priority: .userInitiated) {
            var byName: [String: [PHAsset]] = [:]
            let all = PHAsset.fetchAssets(with: .image, options: nil)
            all.enumerateObjects { asset, _, _ in
                guard let res = PHAssetResource.assetResources(for: asset).first else { return }
                let key = res.originalFilename.uppercased()
                if wanted[key] != nil { byName[key, default: []].append(asset) }
            }
            var picked: [PHAsset] = []
            var lost: [String] = []
            var used = Set<String>()
            for e in entries {
                let key = e.name.uppercased()
                let target = PhotoCleanupView.exif.date(from: e.date)
                let candidates = (byName[key] ?? []).filter { !used.contains($0.localIdentifier) }
                // Names repeat once the camera counter wraps, so the photo's own
                // timestamp decides between them. No timestamp and more than one
                // candidate means we cannot be sure, so leave it alone.
                let choice: PHAsset?
                if candidates.count == 1 {
                    choice = candidates[0]
                } else if let t = target {
                    choice = candidates.min {
                        abs(($0.creationDate ?? .distantPast).timeIntervalSince(t)) <
                        abs(($1.creationDate ?? .distantPast).timeIntervalSince(t))
                    }.flatMap { abs(($0.creationDate ?? .distantPast).timeIntervalSince(t)) < 60 ? $0 : nil }
                } else {
                    choice = nil
                }
                if let c = choice { picked.append(c); used.insert(c.localIdentifier) } else { lost.append(e.name) }
            }
            return (picked, lost)
        }.value
        matched = result.0
        missing = result.1
        phase = matched.isEmpty
            ? "None of the \(entries.count) photos on the list are still in your library."
            : "Found \(matched.count) of the \(entries.count) photos you picked to delete."
        busy = false
    }

    private func delete() {
        busy = true
        let assets = matched as NSArray
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { ok, _ in
            DispatchQueue.main.async {
                busy = false
                if ok {
                    CleanupStore.finish(deleted: matched.count, missing: missing)
                    phase = "Done. \(matched.count) photos moved to Recently Deleted."
                    matched = []
                } else {
                    phase = "Nothing was deleted."
                }
            }
        }
    }
}
