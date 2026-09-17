//
//  RemoteCaptureView.swift
//  Vision Builder
//
//  Lets the Mac take pictures with the phone for a room test. The Mac drops
//  Documents/capture/request.json ({"count": 3}); on launch this screen opens the
//  back camera, says what it is doing, takes the photos a couple of seconds apart
//  and writes capture/shot_N.jpg plus done.txt for devicectl to copy. Photos are
//  not added to the camera roll. 2026-09-16.
//

import SwiftUI
import AVFoundation

enum CaptureStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("capture", isDirectory: true)
    }
    static var request: URL { folder.appendingPathComponent("request.json") }
    static var isRequested: Bool { FileManager.default.fileExists(atPath: request.path) }
}

final class RemoteCamera: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var pending: CheckedContinuation<Data?, Never>?
    var log: [String] = []

    func start() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        log.append("device \(device.localizedName)")
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) } else { log.append("cannot add output") }
        session.commitConfiguration()
        session.startRunning() // synchronous on purpose: capture must not start before this returns
        log.append("running \(session.isRunning)")
        return true
    }

    func shoot() async -> Data? {
        await withCheckedContinuation { cont in
            pending = cont
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { log.append("capture error \(error.localizedDescription)") }
        pending?.resume(returning: photo.fileDataRepresentation())
        pending = nil
    }

    func stop() { session.stopRunning() }
}

struct RemoteCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Getting the camera ready…"
    @State private var camera = RemoteCamera()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 50)).foregroundStyle(Color.appBlue)
            Text("Room test").font(.title2.bold())
            Text(status).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(30)
        .task { await run() }
    }

    private func run() async {
        let count = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: CaptureStore.request))) as? [String: Any])?["count"] as? Int ?? 3
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        let cam = camera
        let started = granted ? await Task.detached { cam.start() }.value : false
        guard granted, started else {
            status = "The camera isn't available."; return
        }
        try? await Task.sleep(for: .seconds(2)) // exposure settles
        for i in 1...count {
            status = "Taking photo \(i) of \(count)…"
            if let data = await camera.shoot() {
                do { try data.write(to: CaptureStore.folder.appendingPathComponent("shot_\(i).jpg")) }
                catch { camera.log.append("write \(error.localizedDescription)") }
            } else {
                camera.log.append("photo \(i): no data")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        camera.stop()
        try? Data(camera.log.joined(separator: "\n").utf8).write(to: CaptureStore.folder.appendingPathComponent("log.txt"))
        try? FileManager.default.removeItem(at: CaptureStore.request)
        try? Data("\(count)".utf8).write(to: CaptureStore.folder.appendingPathComponent("done.txt"))
        status = "Done. The Mac is checking which room this is."
        try? await Task.sleep(for: .seconds(3))
        dismiss()
    }
}
