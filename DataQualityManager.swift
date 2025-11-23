import Accelerate
import Combine
import CoreImage
import Foundation
import SwiftUI
import Vision

// MARK: - Data Quality Manager (Updated to read from metadata)

@MainActor
class DataQualityManager: ObservableObject {
    @Published var isProcessing = false
    @Published var progress = 0.0
    @Published var currentOperation = ""

    private let context = CIContext()

    // MARK: - Quality Report

    struct QualityReport {
        let totalBoxes: Int
        let tinyBoxes: [QualityIssue]
        let blurryImages: [QualityIssue]
        let overlappingBoxes: [QualityIssue]
        let imageQualityScores: [ImageQualityScore]
        let excellentImages: [ImageQualityScore]

        var hasIssues: Bool {
            !tinyBoxes.isEmpty || !blurryImages.isEmpty || !overlappingBoxes.isEmpty
        }

        var totalIssues: Int {
            tinyBoxes.count + blurryImages.count + overlappingBoxes.count
        }

        var averageQualityScore: Float {
            guard !imageQualityScores.isEmpty else { return 100 }
            let total = imageQualityScores.reduce(0) { $0 + $1.overallScore }
            return total / Float(imageQualityScores.count)
        }
    }

    struct QualityIssue: Identifiable {
        let id = UUID()
        let type: IssueType
        let severity: Severity
        let description: String
        let affectedItems: [AffectedItem]

        enum IssueType {
            case tinyBox
            case blurryImage
            case overlappingBoxes

            var icon: String {
                switch self {
                case .tinyBox: return "square.dashed"
                case .blurryImage: return "camera.filters"
                case .overlappingBoxes: return "square.on.square"
                }
            }

            var color: Color {
                switch self {
                case .tinyBox: return .orange
                case .blurryImage: return .red
                case .overlappingBoxes: return .purple
                }
            }
        }

        enum Severity {
            case low, medium, high
        }

        struct AffectedItem {
            let imageId: String
            let boxId: UUID?
            let labelFolder: URL
            let objectFolder: URL?
            let metadata: Any?
        }
    }

    // MARK: - ImageQualityScore struct

    struct ImageQualityScore: Identifiable {
        let id = UUID()
        let imageId: String
        let labelFolder: String
        let objectFolder: String
        let sharpnessScore: Float
        let boxSizeScore: Float
        let compositionScore: Float

        var overallScore: Float {
            // Weighted average: sharpness matters most
            (sharpnessScore * 0.5) + (boxSizeScore * 0.3) + (compositionScore * 0.2)
        }

        var rating: QualityRating {
            switch overallScore {
            case 90 ... 100:
                return .excellent
            case 70 ..< 90:
                return .good
            case 50 ..< 70:
                return .fair
            default:
                return .poor
            }
        }

        enum QualityRating: CaseIterable {
            case excellent
            case good
            case fair
            case poor

            var label: String {
                switch self {
                case .excellent: return "Excellent"
                case .good: return "Good"
                case .fair: return "Fair"
                case .poor: return "Poor"
                }
            }

            var color: Color {
                switch self {
                case .excellent: return .green
                case .good: return .blue
                case .fair: return .orange
                case .poor: return .red
                }
            }

            var icon: String {
                switch self {
                case .excellent: return "star.fill"
                case .good: return "hand.thumbsup.fill"
                case .fair: return "exclamationmark.triangle.fill"
                case .poor: return "xmark.circle.fill"
                }
            }
        }
    }

    // MARK: - Analyze Dataset Quality (Now reads from metadata)

    func analyzeDatasetQuality() async -> QualityReport {
        isProcessing = true
        progress = 0.0
        currentOperation = "Reading dataset quality..."

        var tinyBoxes: [QualityIssue] = []
        var blurryImages: [QualityIssue] = []
        var overlappingBoxes: [QualityIssue] = []
        var totalBoxes = 0

        var allQualityScores: [ImageQualityScore] = []
        var excellentImages: [ImageQualityScore] = []

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let labelFolders = try FileManager.default.contentsOfDirectory(
                at: documentsPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return isDirectory.boolValue && !url.lastPathComponent.hasPrefix(".") && url.lastPathComponent != "Dataset"
            }

            let totalFolders = labelFolders.count
            var processedFolders = 0

            for labelFolder in labelFolders {
                currentOperation = "Checking \(labelFolder.lastPathComponent)..."

                let objectFolders = try FileManager.default.contentsOfDirectory(
                    at: labelFolder,
                    includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.hasPrefix("Object_") && $0.hasDirectoryPath }

                totalBoxes += objectFolders.count

                for objectFolder in objectFolders {
                    // Read metadata with quality scores
                    let metadataPath = objectFolder.appendingPathComponent("metadata.json")
                    guard let data = try? Data(contentsOf: metadataPath),
                          let metadata = try? JSONDecoder().decode(EnhancedObjectMetadata.self, from: data)
                    else {
                        continue
                    }

                    // If quality metrics exist, use them
                    if let qualityMetrics = metadata.qualityMetrics {
                        // Create quality score from saved metrics
                        let qualityScore = ImageQualityScore(
                            imageId: metadata.sourceImageId,
                            labelFolder: labelFolder.lastPathComponent,
                            objectFolder: objectFolder.lastPathComponent,
                            sharpnessScore: qualityMetrics.sharpnessScore,
                            boxSizeScore: qualityMetrics.boxSizeScore,
                            compositionScore: qualityMetrics.compositionScore
                        )

                        allQualityScores.append(qualityScore)

                        if qualityScore.rating == .excellent {
                            excellentImages.append(qualityScore)
                        }

                        // Check for issues based on saved metrics
                        if qualityMetrics.issues.contains("blurry") {
                            blurryImages.append(QualityIssue(
                                type: .blurryImage,
                                severity: qualityMetrics.sharpnessScore < 10 ? .high : .medium,
                                description: String(format: "Sharpness: %.0f%%", qualityMetrics.sharpnessScore),
                                affectedItems: [
                                    QualityIssue.AffectedItem(
                                        imageId: metadata.sourceImageId,
                                        boxId: nil,
                                        labelFolder: labelFolder,
                                        objectFolder: objectFolder,
                                        metadata: qualityMetrics.sharpnessScore
                                    ),
                                ]
                            ))
                        }

                        if qualityMetrics.issues.contains("small_box") {
                            tinyBoxes.append(QualityIssue(
                                type: .tinyBox,
                                severity: qualityMetrics.boxSizeScore < 10 ? .high : .medium,
                                description: String(format: "Box is only %.1f%% of image", qualityMetrics.boxSizeScore),
                                affectedItems: [
                                    QualityIssue.AffectedItem(
                                        imageId: metadata.sourceImageId,
                                        boxId: nil,
                                        labelFolder: labelFolder,
                                        objectFolder: objectFolder,
                                        metadata: nil
                                    ),
                                ]
                            ))
                        }
                    } else {
                        // Fallback: Calculate quality on the fly for older data
                        let qualityScore = await calculateQualityForLegacyData(
                            metadata: metadata,
                            labelFolder: labelFolder,
                            objectFolder: objectFolder
                        )

                        if let score = qualityScore {
                            allQualityScores.append(score)
                            if score.rating == .excellent {
                                excellentImages.append(score)
                            }
                        }
                    }
                }

                // Check for overlaps in this label folder
                if let overlapIssues = checkForOverlaps(in: objectFolders, labelFolder: labelFolder) {
                    overlappingBoxes.append(contentsOf: overlapIssues)
                }

                processedFolders += 1
                progress = Double(processedFolders) / Double(totalFolders)
            }

        } catch {
            print("Error analyzing dataset: \(error)")
        }

        isProcessing = false
        currentOperation = ""

        return QualityReport(
            totalBoxes: totalBoxes,
            tinyBoxes: tinyBoxes,
            blurryImages: blurryImages,
            overlappingBoxes: overlappingBoxes,
            imageQualityScores: allQualityScores,
            excellentImages: excellentImages
        )
    }

    // MARK: - Calculate Quality for Legacy Data (without saved metrics)

    private func calculateQualityForLegacyData(
        metadata: EnhancedObjectMetadata,
        labelFolder: URL,
        objectFolder: URL
    ) async -> ImageQualityScore? {
        let imagePath = objectFolder.appendingPathComponent("image_640.jpg")
        guard let image = UIImage(contentsOfFile: imagePath.path),
              let cgImage = image.cgImage
        else {
            return nil
        }

        // Quick sharpness calculation
        let sharpnessScore = await detectBlur(in: cgImage) * 100

        // Box size calculation
        let boxArea = metadata.boundingBox.width * metadata.boundingBox.height
        let boxSizeScore: Float
        if boxArea < 0.02 {
            boxSizeScore = Float(boxArea * 1000)
        } else if boxArea < 0.1 {
            boxSizeScore = 20 + Float((boxArea - 0.02) * 625)
        } else if boxArea < 0.5 {
            boxSizeScore = 70 + Float((boxArea - 0.1) * 75)
        } else {
            boxSizeScore = max(70, 100 - Float((boxArea - 0.5) * 60))
        }

        // Simple composition score
        let compositionScore: Float = 75.0 // Default for legacy data

        return ImageQualityScore(
            imageId: metadata.sourceImageId,
            labelFolder: labelFolder.lastPathComponent,
            objectFolder: objectFolder.lastPathComponent,
            sharpnessScore: sharpnessScore,
            boxSizeScore: boxSizeScore,
            compositionScore: compositionScore
        )
    }

    // MARK: - Check for Overlaps

    private func checkForOverlaps(in objectFolders: [URL], labelFolder: URL) -> [QualityIssue]? {
        var issuesByImage: [String: [EnhancedObjectMetadata]] = [:]
        var foldersByImage: [String: [URL]] = [:]

        for folder in objectFolders {
            let metadataPath = folder.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metadataPath),
               let metadata = try? JSONDecoder().decode(EnhancedObjectMetadata.self, from: data)
            {
                issuesByImage[metadata.sourceImageId, default: []].append(metadata)
                foldersByImage[metadata.sourceImageId, default: []].append(folder)
            }
        }

        var overlappingIssues: [QualityIssue] = []

        for (imageId, metadatas) in issuesByImage {
            guard metadatas.count > 1 else { continue }

            for i in 0 ..< metadatas.count {
                for j in (i + 1) ..< metadatas.count {
                    let box1 = metadatas[i].boundingBox
                    let box2 = metadatas[j].boundingBox

                    let intersection = box1.intersection(box2)
                    let unionArea = (box1.width * box1.height) + (box2.width * box2.height) - (intersection.width * intersection.height)
                    let iou = (intersection.width * intersection.height) / unionArea

                    if iou > 0.7 { // 70% overlap threshold
                        let folders = foldersByImage[imageId] ?? []
                        overlappingIssues.append(QualityIssue(
                            type: .overlappingBoxes,
                            severity: iou > 0.9 ? .high : .medium,
                            description: String(format: "%.0f%% overlap between '\(metadatas[i].label)' and '\(metadatas[j].label)'", iou * 100),
                            affectedItems: [
                                QualityIssue.AffectedItem(
                                    imageId: imageId,
                                    boxId: nil,
                                    labelFolder: labelFolder,
                                    objectFolder: folders[safe: i],
                                    metadata: nil
                                ),
                                QualityIssue.AffectedItem(
                                    imageId: imageId,
                                    boxId: nil,
                                    labelFolder: labelFolder,
                                    objectFolder: folders[safe: j],
                                    metadata: nil
                                ),
                            ]
                        ))
                    }
                }
            }
        }

        return overlappingIssues.isEmpty ? nil : overlappingIssues
    }

    // MARK: - Sharpness Detection (simplified for legacy data)

    private func detectBlur(in cgImage: CGImage) async -> Float {
        // Simplified sharpness detection
        let ciImage = CIImage(cgImage: cgImage)

        // Convert to grayscale
        let grayscaleFilter = CIFilter(name: "CIColorControls")!
        grayscaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        grayscaleFilter.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let grayscaleOutput = grayscaleFilter.outputImage else {
            return 0.5
        }

        // Apply edge detection
        let edgeFilter = CIFilter(name: "CIEdges")!
        edgeFilter.setValue(grayscaleOutput, forKey: kCIInputImageKey)
        edgeFilter.setValue(1.0, forKey: "inputIntensity")

        guard let edgeOutput = edgeFilter.outputImage else {
            return 0.5
        }

        // Measure edge intensity
        let extent = edgeOutput.extent
        let averageFilter = CIFilter(name: "CIAreaAverage")!
        averageFilter.setValue(edgeOutput, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height), forKey: "inputExtent")

        guard let averageOutput = averageFilter.outputImage else {
            return 0.5
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(averageOutput, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        let edgeIntensity = Float(pixel[0]) / 255.0
        return min(edgeIntensity * 2, 1.0) // Scale and cap at 1.0
    }

    // MARK: - Cleanup Operations

    func removeItems(_ issues: [QualityIssue]) async -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0

        for issue in issues {
            for item in issue.affectedItems {
                if let objectFolder = item.objectFolder {
                    do {
                        try FileManager.default.removeItem(at: objectFolder)
                        removed += 1
                    } catch {
                        failed += 1
                    }
                }
            }
        }

        return (removed, failed)
    }

    // MARK: - Get Quality Score for Label

    func getAverageQualityScore(for labelFolder: URL) async -> Int? {
        var scores: [Float] = []

        do {
            let objectFolders = try FileManager.default.contentsOfDirectory(
                at: labelFolder,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("Object_") && $0.hasDirectoryPath }

            for objectFolder in objectFolders {
                let metadataPath = objectFolder.appendingPathComponent("metadata.json")
                if let data = try? Data(contentsOf: metadataPath),
                   let metadata = try? JSONDecoder().decode(EnhancedObjectMetadata.self, from: data),
                   let qualityMetrics = metadata.qualityMetrics
                {
                    scores.append(qualityMetrics.overallScore)
                }
            }

            if !scores.isEmpty {
                let average = scores.reduce(0, +) / Float(scores.count)
                return Int(average)
            }
        } catch {
            print("Error getting quality scores: \(error)")
        }

        return nil
    }

    // MARK: - Calculate Sharpness for UIImage (Real-time indicator)

    func calculateSharpness(for image: UIImage) async -> Float {
        guard let cgImage = image.cgImage else { return 0.5 }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Downscale for performance
                let targetSize = CGSize(width: 256, height: 256)
                let width = Int(targetSize.width)
                let height = Int(targetSize.height)
                let bytesPerPixel = 4
                let bytesPerRow = width * bytesPerPixel
                let colorSpace = CGColorSpaceCreateDeviceRGB()

                var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

                guard let context = CGContext(
                    data: &pixelData,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    continuation.resume(returning: 0.5)
                    return
                }

                context.interpolationQuality = .medium
                context.draw(cgImage, in: CGRect(origin: .zero, size: targetSize))

                // Convert to grayscale luminance
                var luminance = [Float](repeating: 0, count: width * height)
                for y in 0..<height {
                    for x in 0..<width {
                        let idx = y * bytesPerRow + x * bytesPerPixel
                        let r = Float(pixelData[idx]) / 255.0
                        let g = Float(pixelData[idx + 1]) / 255.0
                        let b = Float(pixelData[idx + 2]) / 255.0
                        luminance[y * width + x] = 0.299 * r + 0.587 * g + 0.114 * b
                    }
                }

                // Calculate Laplacian variance (sharpness metric)
                var laplacianSum: Float = 0
                var count = 0

                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) {
                        let idx = y * width + x
                        // Laplacian kernel: [0,-1,0], [-1,4,-1], [0,-1,0]
                        let lap = 4 * luminance[idx]
                            - luminance[idx - 1]
                            - luminance[idx + 1]
                            - luminance[idx - width]
                            - luminance[idx + width]
                        laplacianSum += lap * lap
                        count += 1
                    }
                }

                let variance = count > 0 ? laplacianSum / Float(count) : 0

                // Normalize to 0-1 range (typical variance ranges from 0 to 0.01+)
                let normalizedScore = min(1.0, variance * 100)
                continuation.resume(returning: normalizedScore)
            }
        }
    }
}

// MARK: - Safe Array Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
