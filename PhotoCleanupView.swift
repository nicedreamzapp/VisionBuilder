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
    /// "delete" (default) or "album": the second kind is not deleted, it is put
    /// in the "Maybe Trash" album for Matt to look through later.
    var action: String? = nil
    /// Original file size in bytes; decides between same-named photos when there is no timestamp.
    var size: Int64? = nil
    var isAlbum: Bool { action == "album" }
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

    static func finish(deleted: Int, missing: [String], held: Int) {
        let report: [String: Any] = ["deleted": deleted, "missing": missing, "held": held,
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
    @State private var held: [PHAsset] = []
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
                if !busy && !held.isEmpty {
                    Text("\(held.count) you weren't sure about go into a Photos album called \"\(PhotoCleanupView.albumName)\" instead.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
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

    static let albumName = "Maybe Trash"

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
        let result: ([(PHAsset, Bool)], [String]) = await Task.detached(priority: .userInitiated) {
            var byName: [String: [PHAsset]] = [:]
            var sizes: [String: Int64] = [:]
            let all = PHAsset.fetchAssets(with: .image, options: nil)
            all.enumerateObjects { asset, _, _ in
                guard let res = PHAssetResource.assetResources(for: asset).first else { return }
                let key = res.originalFilename.uppercased()
                if wanted[key] != nil {
                    byName[key, default: []].append(asset)
                    sizes[asset.localIdentifier] = (res.value(forKey: "fileSize") as? NSNumber)?.int64Value
                }
            }
            var picked: [(PHAsset, Bool)] = []
            var lost: [String] = []
            var used = Set<String>()
            for e in entries {
                let key = e.name.uppercased()
                let target = PhotoCleanupView.exif.date(from: e.date)
                var candidates = (byName[key] ?? []).filter { !used.contains($0.localIdentifier) }
                // The exact byte size is the strongest check we have: a same-named
                // photo that only lives in iCloud must never be taken by mistake.
                if let want = e.size {
                    candidates = candidates.filter { sizes[$0.localIdentifier] == nil || sizes[$0.localIdentifier] == want }
                }
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
                if let c = choice { picked.append((c, e.isAlbum)); used.insert(c.localIdentifier) } else { lost.append(e.name) }
            }
            return (picked, lost)
        }.value
        matched = result.0.filter { !$0.1 }.map(\.0)
        held = result.0.filter { $0.1 }.map(\.0)
        missing = result.1
        let wantedDelete = entries.filter { !$0.isAlbum }.count
        phase = matched.isEmpty && held.isEmpty
            ? "None of the \(entries.count) photos on the list are still in your library."
            : "Found \(matched.count) of the \(wantedDelete) photos you picked to delete."
        if matched.isEmpty && !held.isEmpty { await fileHeld(); phase = "Put \(held.count) photos in \"\(PhotoCleanupView.albumName)\"." }
        busy = false
    }

    /// Files the unsure ones into the album first; that never deletes anything.
    private func fileHeld() async {
        guard !held.isEmpty else { return }
        let assets = held
        let name = PhotoCleanupView.albumName
        try? await PHPhotoLibrary.shared().performChanges {
            let opts = PHFetchOptions()
            opts.predicate = NSPredicate(format: "title == %@", name)
            let request: PHAssetCollectionChangeRequest?
            if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject {
                request = PHAssetCollectionChangeRequest(for: existing)
            } else {
                request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            }
            request?.addAssets(assets as NSArray)
        }
    }

    private func delete() {
        busy = true
        Task { @MainActor in
            await fileHeld()
            reallyDelete()
        }
    }

    private func reallyDelete() {
        let assets = matched as NSArray
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { ok, _ in
            DispatchQueue.main.async {
                busy = false
                if ok {
                    CleanupStore.finish(deleted: matched.count, missing: missing, held: held.count)
                    phase = "Done. \(matched.count) photos moved to Recently Deleted" + (held.isEmpty ? "." : ", \(held.count) in \"\(PhotoCleanupView.albumName)\".")
                    matched = []
                } else {
                    phase = "Nothing was deleted."
                }
            }
        }
    }
}
