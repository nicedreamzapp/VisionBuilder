//
//  LiveRecognitionView.swift
//  Vision Builder
//
//  Live camera recognition of YOUR labeled objects. Deliberately not a
//  generic detector camera (that's RealTime AI Cam's job): generic YOLOE
//  detections render as faint hints; objects matching a learned identity
//  (MobileCLIP prototype cosine >= match threshold) get bold named boxes.
//

import AVFoundation
import Combine
import SwiftUI
import UIKit

// MARK: - Detection result for overlay

struct LiveDetection: Identifiable {
    let id = UUID()
    let rect: CGRect          // normalized 0-1, image space
    let genericLabel: String  // YOLOE class name
    let confidence: Float
    let identityLabel: String?    // learned identity name if matched
    let identitySimilarity: Float?
    let maskImage: CGImage?       // instance segmentation (luminance bitmap)
    let maskRect: CGRect?         // the mask's own normalized region
}

// MARK: - Camera session provider

final class LiveCameraProvider: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "live.camera.frames")

    /// Most recent frame, replaced continuously; recognition loop samples it.
    private let latestFrameLock = NSLock()
    private var latestFrame: UIImage?

    @Published var authorized = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async { self?.authorized = granted }
            guard granted, let self else { return }
            self.queue.async { self.configureAndRun() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndRun() {
        guard !session.isRunning else { return }
        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            if let conn = output.connection(with: .video) {
                conn.videoRotationAngle = 90 // portrait
            }
            session.commitConfiguration()
        }
        session.startRunning()
    }

    func captureOutput(_ _: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cg)
        latestFrameLock.lock()
        latestFrame = image
        latestFrameLock.unlock()
    }

    func grabFrame() -> UIImage? {
        latestFrameLock.lock()
        defer { latestFrameLock.unlock() }
        return latestFrame
    }
}

// MARK: - Preview layer wrapper

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context _: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_: PreviewView, context _: Context) {}
}

// MARK: - Live recognition screen

struct LiveRecognitionView: View {
    @StateObject private var camera = LiveCameraProvider()
    @State private var detections: [LiveDetection] = []
    @State private var identityCount = 0
    @State private var frameSize: CGSize = .zero
    @State private var recognitionTask: Task<Void, Never>? = nil
    @State private var lastInferenceMs: Int = 0

    private let detector = YOLOObjectDetector()
    private let embeddingService = EmbeddingService()

    var body: some View {
        ZStack {
            if camera.authorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                GeometryReader { geo in
                    ForEach(detections) { det in
                        detectionBox(det, in: geo.size)
                    }
                }
                .ignoresSafeArea()

                VStack {
                    statusBar
                    Spacer()
                    hintBar
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Camera access needed")
                        .font(.headline)
                    Text("Live recognition runs entirely on this device.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            camera.start()
            startRecognitionLoop()
        }
        .onDisappear {
            recognitionTask?.cancel()
            recognitionTask = nil
            camera.stop()
        }
    }

    private var statusBar: some View {
        HStack {
            Label("\(identityCount) learned", systemImage: "brain")
            Spacer()
            if lastInferenceMs > 0 {
                Text("\(lastInferenceMs) ms")
                    .monospacedDigit()
            }
        }
        .font(.caption.bold())
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.55)))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var hintBar: some View {
        Group {
            if identityCount == 0 {
                Text("Label objects in the Inbox first — then point the camera at them")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func detectionBox(_ det: LiveDetection, in size: CGSize) -> some View {
        // Preview is aspect-fill; map normalized image coords to view coords.
        // Frame and view are both portrait; fill crops the overflow dimension.
        let frame = boxFrame(det.rect, in: size)
        let isMine = det.identityLabel != nil

        // Segmentation silhouette drawn at the mask's OWN rect (cell-aligned,
        // slightly larger than the box) so the shape isn't squeezed or offset.
        // .luminanceToAlpha() is essential: the mask bitmap is grayscale, and
        // SwiftUI's .mask() reads alpha — without it the mask is a solid box.
        if let mask = det.maskImage {
            let maskFrame = boxFrame(det.maskRect ?? det.rect, in: size)
            (isMine ? Color.green : Color.white)
                .opacity(isMine ? 0.5 : 0.16)
                .mask(
                    Image(decorative: mask, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .luminanceToAlpha()
                )
                .frame(width: maskFrame.width, height: maskFrame.height)
                .position(x: maskFrame.midX, y: maskFrame.midY)
        } else if isMine {
            // Fallback if a mask is unavailable for a matched object
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green, lineWidth: 3)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }

        Group {
            if isMine {
                Text("\(det.identityLabel!) \(Int((det.identitySimilarity ?? 0) * 100))%")
                    .font(.caption.bold())
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green))
            } else {
                Text(det.genericLabel)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.35)))
            }
        }
        .position(x: frame.midX, y: max(12, frame.minY - 14))
    }

    private func boxFrame(_ norm: CGRect, in viewSize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else {
            return CGRect(x: norm.minX * viewSize.width, y: norm.minY * viewSize.height,
                          width: norm.width * viewSize.width, height: norm.height * viewSize.height)
        }
        // aspect-fill mapping: scale = max ratio, content centered, overflow cropped
        let scale = max(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        let scaledW = frameSize.width * scale
        let scaledH = frameSize.height * scale
        let offsetX = (viewSize.width - scaledW) / 2
        let offsetY = (viewSize.height - scaledH) / 2
        return CGRect(
            x: norm.minX * scaledW + offsetX,
            y: norm.minY * scaledH + offsetY,
            width: norm.width * scaledW,
            height: norm.height * scaledH
        )
    }

    private func startRecognitionLoop() {
        guard recognitionTask == nil else { return }
        recognitionTask = Task { @MainActor in
            let engine = ObjectRecognitionEngine()
            while !Task.isCancelled {
                if let frame = camera.grabFrame() {
                    frameSize = frame.size
                    let t0 = Date()
                    if let results = try? await recognize(frame: frame, engine: engine) {
                        detections = results
                        lastInferenceMs = Int(Date().timeIntervalSince(t0) * 1000)
                    }
                }
                // ~2 passes/sec keeps the phone cool; the preview itself stays 30fps
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    @MainActor
    private func recognize(frame: UIImage, engine: ObjectRecognitionEngine) async throws -> [LiveDetection] {
        let identities = (try? engine.getAllIdentities()) ?? []
        identityCount = identities.count

        let dets = try await detector.detect(in: frame)

        // De-duplicate: the open-vocab head often fires several labels on one
        // object ("bus" + "police van" + "tour bus"). Keep the highest-confidence
        // detection when another is mostly the same region.
        var unique: [DetectedObject] = []
        for det in dets.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = unique.contains { kept in
                let inter = kept.rect.intersection(det.rect)
                guard !inter.isNull else { return false }
                let interArea = inter.width * inter.height
                let minArea = min(kept.rect.width * kept.rect.height,
                                  det.rect.width * det.rect.height)
                return minArea > 0 && interArea / minArea > 0.75
            }
            if !duplicate { unique.append(det) }
        }

        var results: [LiveDetection] = []

        for det in unique.prefix(8) {
            var identityLabel: String? = nil
            var identitySim: Float? = nil

            if !identities.isEmpty {
                let pixelRect = CGRect(
                    x: det.rect.minX * frame.size.width,
                    y: det.rect.minY * frame.size.height,
                    width: det.rect.width * frame.size.width,
                    height: det.rect.height * frame.size.height
                )
                if let emb = try? await embeddingService.generateEmbedding(from: frame, boundingBox: pixelRect) {
                    var best: (label: String, sim: Float)? = nil
                    for identity in identities where !identity.prototypeEmbedding.isEmpty {
                        let sim = EmbeddingService.cosineSimilarity(emb.vector, identity.prototypeEmbedding)
                        if sim > (best?.sim ?? 0) { best = (identity.label, sim) }
                    }
                    if let best, best.sim >= ObjectRecognitionEngine.RecognitionConfig.default.matchThreshold {
                        identityLabel = best.label
                        identitySim = best.sim
                    }
                }
            }

            results.append(LiveDetection(
                rect: det.rect,
                genericLabel: det.className,
                confidence: det.confidence,
                identityLabel: identityLabel,
                identitySimilarity: identitySim,
                maskImage: det.maskImage,
                maskRect: det.maskRect
            ))
        }
        return results
    }
}

#Preview {
    LiveRecognitionView()
}
