//
//  YOLOObjectDetector.swift
//  Vision Builder
//
//  YOLOv8 with 601-class Open Images V7 model.
//  Uses MLModel with proper pixel buffer format matching.
//

import Accelerate
import CoreML
import Foundation
import UIKit

struct DetectedObject {
    let className: String
    let confidence: Float
    let rect: CGRect          // Normalized 0-1 coordinates
    let centerPoint: CGPoint  // Normalized center for SAM2
}

class YOLOObjectDetector {

    /// Generation actually loaded; YOLO26 is NMS-free with same tensor layout.
    enum Generation { case v8, v26 }

    private var model: MLModel?
    private var classNames: [String] = []
    private var isLoaded = false
    private(set) var loadedGeneration: Generation = .v8

    private let confidenceThreshold: Float = 0.10  // was 0.25 — lower = catches more objects
    private let iouThreshold: Float = 0.45
    private let maxDetections = 20  // was 5 — handle photos with many objects
    private let inputSize: Int = 640

    /// Preferred order: YOLO26 if bundled, else YOLOv8 OIV7.
    private enum ModelNames {
        static let v26 = "yolo26n"
        static let v8 = "yolov8n_oiv7"
    }

    func ensureLoaded() async throws {
        guard !isLoaded else { return }

        let (modelName, generation) = resolvePreferredModelName()
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            throw YOLOError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: modelURL, configuration: config)
        loadedGeneration = generation

        // Load the class names file matching the loaded generation.
        // YOLOv8 OIV7 = 601 classes; YOLO26n = 80 COCO classes.
        let classFile = generation == .v26 ? "yolo26_class_names" : "yolo_class_names"
        if let url = Bundle.main.url(forResource: classFile, withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            classNames = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        } else if let url = Bundle.main.url(forResource: "yolo_class_names", withExtension: "txt"),
                  let content = try? String(contentsOf: url, encoding: .utf8) {
            // Last-resort fallback if v26 file missing.
            classNames = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        }

        // Log model input spec so we can verify format
        if let desc = model?.modelDescription.inputDescriptionsByName["image"] {
            print("YOLO model input 'image': \(desc)")
            if let imageConstraint = desc.imageConstraint {
                print("  Expected: \(imageConstraint.pixelsWide)x\(imageConstraint.pixelsHigh) format=\(imageConstraint.pixelFormatType)")
            }
        }

        isLoaded = true
        print("YOLO \(generation == .v26 ? "26" : "v8") loaded (\(classNames.count) classes)")
    }

    /// YOLO26 if bundled, else fall back to YOLOv8 OIV7.
    private func resolvePreferredModelName() -> (name: String, gen: Generation) {
        if Bundle.main.url(forResource: ModelNames.v26, withExtension: "mlmodelc") != nil {
            return (ModelNames.v26, .v26)
        }
        return (ModelNames.v8, .v8)
    }

    /// Detect objects in a UIImage.
    func detect(in image: UIImage) async throws -> [DetectedObject] {
        try await ensureLoaded()
        guard let model = model, let cgImage = image.cgImage else { return [] }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        // Get the pixel format the model expects
        let expectedFormat: OSType
        if let imageConstraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint {
            expectedFormat = imageConstraint.pixelFormatType
        } else {
            expectedFormat = kCVPixelFormatType_32BGRA
        }

        // Create 640x640 letterboxed pixel buffer in the format the model expects
        guard let buffer = createLetterboxedBuffer(from: cgImage, pixelFormat: expectedFormat) else {
            print("YOLO: failed to create pixel buffer")
            return []
        }

        let letterbox = getLetterboxInfo(width: imageWidth, height: imageHeight)

        // Run inference
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
        let output = try await model.prediction(from: input)

        // Get raw output
        guard let feature = output.featureValue(for: "var_914"),
              let rawOutput = feature.multiArrayValue else {
            // Try first available output
            for name in output.featureNames {
                if let f = output.featureValue(for: name), let a = f.multiArrayValue {
                    let detections = decodeOutput(a, imageWidth: imageWidth, imageHeight: imageHeight, letterbox: letterbox)
                    return detections
                }
            }
            print("YOLO: no output array found")
            return []
        }

        let detections = decodeOutput(rawOutput, imageWidth: imageWidth, imageHeight: imageHeight, letterbox: letterbox)
        return detections
    }

    // MARK: - Letterboxing

    private func createLetterboxedBuffer(from cgImage: CGImage, pixelFormat: OSType) -> CVPixelBuffer? {
        let origW = cgImage.width
        let origH = cgImage.height
        let scale = min(Float(inputSize) / Float(origW), Float(inputSize) / Float(origH))
        let scaledW = Int(Float(origW) * scale)
        let scaledH = Int(Float(origH) * scale)
        let padX = (inputSize - scaledW) / 2
        let padY = (inputSize - scaledH) / 2

        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, inputSize, inputSize,
                           pixelFormat, attrs as CFDictionary, &buffer)
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        // Determine bitmap info based on pixel format
        let bitmapInfo: UInt32
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case kCVPixelFormatType_32ARGB:
            bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        case kCVPixelFormatType_32RGBA:
            bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        default:
            bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: inputSize, height: inputSize,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Fill with 50% gray (standard YOLO letterbox) — value 114/255 matches ultralytics
        context.setFillColor(red: 114.0/255.0, green: 114.0/255.0, blue: 114.0/255.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: inputSize, height: inputSize))

        // Draw image centered with correct aspect ratio
        context.draw(cgImage, in: CGRect(x: padX, y: padY, width: scaledW, height: scaledH))

        return pixelBuffer
    }

    private func getLetterboxInfo(width: Int, height: Int) -> (scale: Float, padX: Int, padY: Int) {
        let scale = min(Float(inputSize) / Float(width), Float(inputSize) / Float(height))
        let scaledW = Int(Float(width) * scale)
        let scaledH = Int(Float(height) * scale)
        return (scale, (inputSize - scaledW) / 2, (inputSize - scaledH) / 2)
    }

    // MARK: - Decode (same algorithm as project 601)

    private func decodeOutput(
        _ rawOutput: MLMultiArray,
        imageWidth: Int,
        imageHeight: Int,
        letterbox: (scale: Float, padX: Int, padY: Int)
    ) -> [DetectedObject] {
        let numAnchors = 8400
        let numClasses = classNames.count
        guard numClasses > 0 else { return [] }

        // Convert to Float32 array regardless of model output type
        let count = rawOutput.count
        var floats = [Float](repeating: 0, count: count)

        if rawOutput.dataType == .float16 {
            let f16ptr = rawOutput.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<count { floats[i] = Float(f16ptr[i]) }
        } else {
            let f32ptr = rawOutput.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<count { floats[i] = f32ptr[i] }
        }
        let (scale, padX, padY) = letterbox

        // Find best class per anchor using Accelerate
        var bestClasses = [Int](repeating: 0, count: numAnchors)
        var bestScores = [Float](repeating: 0, count: numAnchors)

        floats.withUnsafeBufferPointer { buf in
            let ptr = buf.baseAddress!
            let classStart = ptr + 4 * numAnchors
            for i in 0..<numAnchors {
                var maxVal: Float = 0
                var maxIdx: vDSP_Length = 0
                vDSP_maxvi(classStart + i, vDSP_Stride(numAnchors), &maxVal, &maxIdx, vDSP_Length(numClasses))
                bestScores[i] = maxVal
                bestClasses[i] = Int(maxIdx) / numAnchors
            }
        }

        var candidates: [(className: String, score: Float, rect: CGRect)] = []

        for i in 0..<numAnchors {
            guard bestScores[i] > confidenceThreshold else { continue }

            let cx = floats[i]
            let cy = floats[numAnchors + i]
            let w = floats[2 * numAnchors + i]
            let h = floats[3 * numAnchors + i]

            // Skip padding area
            if cx < Float(padX) || cx > Float(inputSize - padX) ||
               cy < Float(padY) || cy > Float(inputSize - padY) { continue }

            // Convert from 640x640 letterboxed to original image normalized 0-1
            let origCx = (cx - Float(padX)) / scale
            let origCy = (cy - Float(padY)) / scale
            let origW = w / scale
            let origH = h / scale

            let normX = CGFloat(max(0, (origCx - origW / 2)) / Float(imageWidth))
            let normY = CGFloat(max(0, (origCy - origH / 2)) / Float(imageHeight))
            let normW = CGFloat(min(origW / Float(imageWidth), 1.0))
            let normH = CGFloat(min(origH / Float(imageHeight), 1.0))

            let rect = CGRect(x: normX, y: normY, width: normW, height: normH)

            let area = rect.width * rect.height
            guard area > 0.003 && area < 0.9 else { continue }

            let classIdx = bestClasses[i]
            let className = classIdx < classNames.count ? classNames[classIdx] : "Unknown"
            candidates.append((className, bestScores[i], rect))
        }

        candidates.sort { $0.score > $1.score }

        // NMS
        var kept: [(className: String, score: Float, rect: CGRect)] = []
        for candidate in candidates {
            let dominated = kept.contains { iou($0.rect, candidate.rect) > iouThreshold }
            if !dominated {
                kept.append(candidate)
                if kept.count >= maxDetections { break }
            }
        }

        return kept.map {
            DetectedObject(
                className: $0.className,
                confidence: $0.score,
                rect: $0.rect,
                centerPoint: CGPoint(x: $0.rect.midX, y: $0.rect.midY)
            )
        }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let interArea = Float(intersection.width * intersection.height)
        let unionArea = Float(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    // Keep float32Buffer alive for pointer safety
    private var _keepAlive: [Float]?
}

enum YOLOError: Error, LocalizedError {
    case modelNotFound
    case noDetections
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "YOLOv8 model not found in bundle"
        case .noDetections: return "YOLO model returned no output"
        }
    }
}
