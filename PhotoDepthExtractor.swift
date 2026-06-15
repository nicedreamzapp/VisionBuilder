//
//  PhotoDepthExtractor.swift
//  Vision Builder
//
//  Pulls the depth/disparity map that iPhone Portrait (and other depth-tagged)
//  photos already carry, so every detected object can get a distance-in-meters
//  hint for free — no live LiDAR capture needed. Ordinary photos have no depth
//  map and return nil, which is expected and harmless.
//
//  Depth-sampling math (5x5-median around a normalized point) mirrors the
//  approach proven in RealTime AI Camera's LiDARManager.
//

import AVFoundation
import CoreVideo
import ImageIO
import Photos

enum PhotoDepthExtractor {

    /// Load and orient the depth map embedded in a photo, normalized to
    /// 32-bit float DEPTH (meters). Returns nil when the photo carries no depth.
    static func loadDepthData(for asset: PHAsset) async -> AVDepthData? {
        // Cheap pre-check: only Portrait/depth-effect photos carry a depth map.
        // (Skipping this would still work but would fetch full data for every
        // ordinary photo during a scan.)
        guard asset.mediaSubtypes.contains(.photoDepthEffect) else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat

        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }

        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        // The depth map is stored in the photo's native orientation; the rest of
        // the pipeline works in the EXIF-corrected image space, so re-orient the
        // depth map to match before anyone samples it.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        // Prefer disparity (denser on iPhones); fall back to depth.
        for auxType in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxType) as? [AnyHashable: Any],
                  var depth = try? AVDepthData(fromDictionaryRepresentation: info) else {
                continue
            }
            if depth.depthDataType != kCVPixelFormatType_DepthFloat32 {
                depth = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            }
            return depth.applyingExifOrientation(orientation)
        }
        return nil
    }

    /// Median depth (meters) in a small window around a normalized (0–1) point.
    /// Mirrors LiDARManager: a 5x5 grid, discard implausible samples, take median.
    static func depthMeters(atNormalizedPoint pt: CGPoint, in depthData: AVDepthData) -> Double? {
        let depthMap = depthData.depthDataMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }

        var samples: [Double] = []
        for yOffset in stride(from: -0.04, through: 0.04, by: 0.02) {
            for xOffset in stride(from: -0.04, through: 0.04, by: 0.02) {
                let p = CGPoint(x: min(max(pt.x + xOffset, 0), 1),
                                y: min(max(pt.y + yOffset, 0), 1))
                if let d = sample(p, from: depthMap), d > 0.1, d < 15.0, d.isFinite {
                    samples.append(d)
                }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    // MARK: - Private

    private static func sample(_ pt: CGPoint, from depthMap: CVPixelBuffer) -> Double? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        let x = Int((pt.x * CGFloat(width)).rounded())
        let y = Int((pt.y * CGFloat(height)).rounded())
        guard x >= 0, x < width, y >= 0, y < height else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let row = base + y * rowBytes
        let value = row.assumingMemoryBound(to: Float32.self)[x]
        guard value > 0, value.isFinite else { return nil }
        return Double(value)
    }
}
