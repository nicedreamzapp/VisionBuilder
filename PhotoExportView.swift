//
//  PhotoExportView.swift
//  Vision Builder
//
//  Sends small copies of the camera roll to the Mac without a cable. The Mac
//  drops Documents/export/request.json; on launch this sheet writes every photo
//  as a 768px JPEG into pack files (Documents/export/pack_N.bin), which the Mac
//  copies over Wi-Fi with devicectl. Pack record: UInt32 big-endian length +
//  JSON {id, name, date, lat, lon}, then UInt32 length + JPEG bytes.
//  Written 2026-09-16 for the room-recognition test when no cable was handy.
//

import SwiftUI
import Photos

enum ExportStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("export", isDirectory: true)
    }
    static var request: URL { folder.appendingPathComponent("request.json") }
    static var isRequested: Bool { FileManager.default.fileExists(atPath: request.path) }
}

struct PhotoExportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var done = 0
    @State private var total = 0
    @State private var finished = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 50)).foregroundStyle(Color.appBlue)
            Text(finished ? "Ready for the Mac" : "Getting photos ready for the Mac…")
                .font(.headline)
            ProgressView(value: total == 0 ? 0 : Double(done), total: Double(max(total, 1)))
                .padding(.horizontal, 30)
            Text("\(done) of \(total) photos. Keep the app open.")
                .font(.subheadline).foregroundStyle(.secondary)
            if finished { Button("Close") { dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(24)
        .interactiveDismissDisabled(!finished)
        .task { await run() }
    }

    private func run() async {
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // {"since": "<ISO date>"} sends only photos taken after that moment
        // (a quick room test), instead of the whole library.
        if let data = try? Data(contentsOf: ExportStore.request),
           let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let since = (req["since"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            opts.predicate = NSPredicate(format: "creationDate > %@", since as NSDate)
        }
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        total = assets.count
        let manager = PHImageManager.default()
        let req = PHImageRequestOptions()
        req.isSynchronous = true
        req.deliveryMode = .highQualityFormat
        req.resizeMode = .fast
        req.isNetworkAccessAllowed = false
        let iso = ISO8601DateFormatter()
        let folder = ExportStore.folder
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("pack_") || old.lastPathComponent == "done.txt" {
            try? FileManager.default.removeItem(at: old)
        }
        let list = (0..<assets.count).map { assets.object(at: $0) }

        await Task.detached(priority: .userInitiated) {
            var packIndex = 0
            var handle: FileHandle?
            var packBytes = 0
            func openPack() {
                try? handle?.close()
                let url = folder.appendingPathComponent("pack_\(packIndex).bin.part")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try? FileHandle(forWritingTo: url)
                packBytes = 0
            }
            func closePack() {
                try? handle?.close(); handle = nil
                let part = folder.appendingPathComponent("pack_\(packIndex).bin.part")
                try? FileManager.default.moveItem(at: part, to: folder.appendingPathComponent("pack_\(packIndex).bin"))
                packIndex += 1
            }
            func u32(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) } }
            openPack()
            for (i, asset) in list.enumerated() {
                autoreleasepool {
                    var jpeg: Data?
                    manager.requestImage(for: asset, targetSize: CGSize(width: 768, height: 768),
                                         contentMode: .aspectFit, options: req) { img, _ in
                        jpeg = img?.jpegData(compressionQuality: 0.8)
                    }
                    guard let jpeg else { return }
                    var meta: [String: Any] = ["id": asset.localIdentifier,
                                               "name": PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "",
                                               "date": asset.creationDate.map { iso.string(from: $0) } ?? ""]
                    if let loc = asset.location { meta["lat"] = loc.coordinate.latitude; meta["lon"] = loc.coordinate.longitude }
                    let json = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data()
                    var rec = u32(json.count); rec.append(json); rec.append(u32(jpeg.count)); rec.append(jpeg)
                    handle?.write(rec)
                    packBytes += rec.count
                    if packBytes > 150_000_000 { closePack(); openPack() }
                }
                if i % 25 == 0 { let n = i + 1; Task { @MainActor in done = n } }
            }
            closePack()
            try? FileManager.default.removeItem(at: ExportStore.request)
            try? Data("\(packIndex)".utf8).write(to: folder.appendingPathComponent("done.txt"))
        }.value
        done = total
        finished = true
    }
}
