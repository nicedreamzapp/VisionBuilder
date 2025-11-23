import Combine
import CoreImage
import SwiftUI
import UIKit
import Vision

// MARK: - Enhanced Object Metadata with Quality

struct EnhancedObjectMetadata: Codable {
    let sourceImageId: String
    let label: String
    let boundingBox: CGRect
    let scaledBoundingBox: CGRect
    let detectionMethod: String?
    let timestamp: Date
    let deviceInfo: String
    let allBoxesInImage: [BoxInfo]
    let qualityMetrics: QualityMetrics? // New field

    struct BoxInfo: Codable {
        let label: String
        let rect: CGRect
    }

    struct QualityMetrics: Codable {
        let overallScore: Float
        let sharpnessScore: Float
        let boxSizeScore: Float
        let compositionScore: Float
        let rating: String // "excellent", "good", "fair", "poor"
        let scoredAt: Date
        let issues: [String] // e.g., ["blurry", "small_box"]
    }
}

// MARK: - Enhanced Export Manager

@MainActor
class ExportManager: ObservableObject {
    @Published var isExporting = false
    @Published var exportComplete = false
    @Published var exportedCount = 0
    @Published var shareItems: [Any] = []
    @Published var pendingBoxes: [LabeledBox] = []
    @Published var exportOptions = ExportOptions()
    @Published var lastError: String? = nil

    weak var datasetManager: DatasetManager?

    private let context = CIContext()

    struct ExportOptions {
        var format: ExportFormat = .visionBuilder
        var selectedLabels: Set<String> = []
        var includeMetadata: Bool = true
        var imageScale: ImageScale = .high
    }

    // MARK: - Quick Save with Auto Quality Scoring

    func quickSave(image: UIImage, labeledBoxes: [LabeledBox]) {
        print("DEBUG: Starting export with \(labeledBoxes.count) boxes")
        for box in labeledBoxes {
            print("DEBUG: Box label='\(box.label)' isSaved=\(box.isSaved)")
        }

        print("🟦 ExportManager: Starting quickSave")
        print("🟦 Boxes to save: \(labeledBoxes.count)")

        let savedBoxes = labeledBoxes.filter { !$0.label.isEmpty && $0.label != "Object" }
        print("DEBUG: After filtering: \(savedBoxes.count) boxes to export")

        guard !savedBoxes.isEmpty else {
            print("⚠️ No saved boxes to export")
            print("DEBUG: No boxes to export - stopping")
            return
        }

        isExporting = true
        exportedCount = 0

        Task {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            // Group boxes by label
            let boxesByLabel = Dictionary(grouping: savedBoxes) { $0.label }

            for (label, boxes) in boxesByLabel {
                let trimmedLabel = sanitizedLabel(label)
                let labelFolder = documentsPath.appendingPathComponent(trimmedLabel)

                do {
                    try FileManager.default.createDirectory(at: labelFolder, withIntermediateDirectories: true)
                    print("✅ Created/Found directory for label '\(label)' at \(labelFolder.path)")
                } catch {
                    let errMsg = "❌ Failed to create directory for label '\(label)': \(error)"
                    print(errMsg)
                    lastError = errMsg
                    continue
                }

                for box in boxes {
                    // Calculate quality score for this box
                    let qualityMetrics = await calculateQualityMetrics(
                        for: image,
                        box: box
                    )

                    // Save with quality metrics, pass labelFolder
                    do {
                        try await saveObject(
                            image: image,
                            box: box,
                            allBoxes: savedBoxes,
                            qualityMetrics: qualityMetrics,
                            labelFolder: labelFolder
                        )
                        exportedCount += 1
                        print("✅ Saved box \(exportedCount) with quality score: \(qualityMetrics.overallScore)")
                    } catch {
                        let errMsg = "❌ Error saving box for label '\(box.label)' in label folder '\(labelFolder.path)': \(error)"
                        print(errMsg)
                        lastError = errMsg
                    }
                }
            }

            await MainActor.run {
                self.isExporting = false
                self.exportComplete = true

                // Auto-dismiss after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.exportComplete = false
                }

                // Automatically refresh the dataset browser
                Task {
                    await self.datasetManager?.loadDataset()
                }
            }

            print("✅ Export completed: \(exportedCount) objects")
        }
    }

    // MARK: - Quality Calculation

    private func calculateQualityMetrics(for image: UIImage, box: LabeledBox) async -> EnhancedObjectMetadata.QualityMetrics {
        // 1. Calculate sharpness
        let sharpnessScore = await calculateSharpness(image: image, box: box)

        // 2. Calculate box size score
        let boxSizeScore = calculateBoxSizeScore(box: box)

        // 3. Calculate composition score
        let compositionScore = calculateCompositionScore(box: box)

        // 4. Calculate overall score
        let overallScore = (sharpnessScore * 0.5) + (boxSizeScore * 0.3) + (compositionScore * 0.2)

        // 5. Determine rating
        let rating: String
        switch overallScore {
        case 90 ... 100: rating = "excellent"
        case 70 ..< 90: rating = "good"
        case 50 ..< 70: rating = "fair"
        default: rating = "poor"
        }

        // 6. Identify issues
        var issues: [String] = []
        if sharpnessScore < 30 {
            issues.append("blurry")
        }
        if boxSizeScore < 20 {
            issues.append("small_box")
        }
        if compositionScore < 50 {
            issues.append("poor_framing")
        }

        return EnhancedObjectMetadata.QualityMetrics(
            overallScore: overallScore,
            sharpnessScore: sharpnessScore,
            boxSizeScore: boxSizeScore,
            compositionScore: compositionScore,
            rating: rating,
            scoredAt: Date(),
            issues: issues
        )
    }

    // MARK: - Sharpness Detection

    private func calculateSharpness(image: UIImage, box: LabeledBox) async -> Float {
        guard let cgImage = image.cgImage else { return 50.0 }

        // Crop to box area
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: box.rect.origin.x * imageWidth,
            y: box.rect.origin.y * imageHeight,
            width: box.rect.width * imageWidth,
            height: box.rect.height * imageHeight
        )

        guard let croppedImage = cgImage.cropping(to: cropRect) else { return 50.0 }

        // Calculate Laplacian variance
        let ciImage = CIImage(cgImage: croppedImage)

        // Convert to grayscale
        let grayscaleFilter = CIFilter(name: "CIColorControls")!
        grayscaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        grayscaleFilter.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let grayscaleOutput = grayscaleFilter.outputImage,
              let grayscaleCGImage = context.createCGImage(grayscaleOutput, from: grayscaleOutput.extent)
        else {
            return 50.0
        }

        // Apply Laplacian filter
        let laplacianFilter = CIFilter(name: "CIConvolution3X3")!
        laplacianFilter.setValue(CIImage(cgImage: grayscaleCGImage), forKey: kCIInputImageKey)
        laplacianFilter.setValue(CIVector(values: [
            0, -1, 0,
            -1, 4, -1,
            0, -1, 0,
        ], count: 9), forKey: "inputWeights")
        laplacianFilter.setValue(0.0, forKey: "inputBias")

        guard let laplacianOutput = laplacianFilter.outputImage else {
            return 50.0
        }

        // Calculate variance
        let extent = laplacianOutput.extent
        let histogramFilter = CIFilter(name: "CIAreaHistogram")!
        histogramFilter.setValue(laplacianOutput, forKey: kCIInputImageKey)
        histogramFilter.setValue(CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height), forKey: "inputExtent")
        histogramFilter.setValue(256, forKey: "inputCount")
        histogramFilter.setValue(1.0, forKey: "inputScale")

        guard let histogramOutput = histogramFilter.outputImage else {
            return 50.0
        }

        var histogramBitmap = [Float](repeating: 0, count: 256)
        context.render(histogramOutput,
                       toBitmap: &histogramBitmap,
                       rowBytes: 256 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
                       format: .Rf,
                       colorSpace: nil)

        var sum: Float = 0
        var sumSquares: Float = 0
        var totalPixels: Float = 0

        for (i, count) in histogramBitmap.enumerated() {
            let value = Float(i) / 255.0
            sum += value * count
            sumSquares += value * value * count
            totalPixels += count
        }

        if totalPixels > 0 {
            let mean = sum / totalPixels
            let variance = (sumSquares / totalPixels) - (mean * mean)
            let normalizedSharpness = min(sqrt(variance) * 100, 100.0)
            return normalizedSharpness
        }

        return 50.0
    }

    // MARK: - Box Size Score

    private func calculateBoxSizeScore(box: LabeledBox) -> Float {
        let boxArea = box.rect.width * box.rect.height
        if boxArea < 0.02 {
            return Float(boxArea * 1000)
        } else if boxArea < 0.1 {
            return Float(20 + (boxArea - 0.02) * 625)
        } else if boxArea < 0.5 {
            return Float(70 + (boxArea - 0.1) * 75)
        } else {
            return Float(max(70, 100 - (boxArea - 0.5) * 60))
        }
    }

    // MARK: - Composition Score

    private func calculateCompositionScore(box: LabeledBox) -> Float {
        let centerX = box.rect.midX
        let centerY = box.rect.midY
        let thirdPoints: [(x: CGFloat, y: CGFloat)] = [
            (0.333, 0.333), (0.667, 0.333),
            (0.333, 0.667), (0.667, 0.667),
            (0.5, 0.5),
        ]
        let minDistance = thirdPoints.map { point in
            sqrt(pow(centerX - point.x, 2) + pow(centerY - point.y, 2))
        }.min() ?? 0.5
        let distanceScore = Float((1 - min(minDistance * 2, 1)) * 70)
        let edgeDistance = min(
            min(box.rect.minX, 1 - box.rect.maxX),
            min(box.rect.minY, 1 - box.rect.maxY)
        )
        let edgeScore = Float(min(edgeDistance * 100, 30))
        return distanceScore + edgeScore
    }

    // MARK: - Save Object with Quality

    private func saveObject(
        image: UIImage,
        box: LabeledBox,
        allBoxes: [LabeledBox],
        qualityMetrics: EnhancedObjectMetadata.QualityMetrics,
        labelFolder: URL? = nil
    ) async throws {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folderToUse: URL
        if let labelFolder = labelFolder {
            folderToUse = labelFolder
        } else {
            folderToUse = documentsPath.appendingPathComponent(sanitizedLabel(box.label))
            do {
                try FileManager.default.createDirectory(at: folderToUse, withIntermediateDirectories: true)
                print("✅ Created/Found label folder at \(folderToUse.path)")
            } catch {
                let errMsg = "❌ Failed to create label folder: \(error)"
                print(errMsg)
                lastError = errMsg
                throw error
            }
        }

        // Create unique object folder inside label folder
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let trimmedLabel = sanitizedLabel(box.label)
        let objectFolder = folderToUse.appendingPathComponent("Object_\(trimmedLabel)_\(timestamp)")

        do {
            try FileManager.default.createDirectory(at: objectFolder, withIntermediateDirectories: true)
            print("✅ Created object folder at \(objectFolder.path)")
        } catch {
            let errMsg = "❌ Failed to create object folder at \(objectFolder.path): \(error)"
            print(errMsg)
            lastError = errMsg
            throw error
        }

        // Folder Structure:
        // Documents/
        //   <Label>/
        //     Object_<label>_<timestamp>/
        //       image_640.jpg
        //       image_1280.jpg
        //       image_full.jpg
        //       metadata.json

        // Save images at different scales inside object folder
        let scales: [(name: String, size: CGFloat)] = [
            ("image_640.jpg", 640),
            ("image_1280.jpg", 1280),
            ("image_full.jpg", max(image.size.width, image.size.height)),
        ]

        var savedImageFiles: [String] = []

        for (filename, maxSize) in scales {
            if let resized = resizeImage(image, maxDimension: maxSize),
               let data = resized.jpegData(compressionQuality: 0.9)
            {
                let imagePath = objectFolder.appendingPathComponent(filename)
                do {
                    // If file exists, remove it first to avoid conflicts
                    if FileManager.default.fileExists(atPath: imagePath.path) {
                        try FileManager.default.removeItem(at: imagePath)
                        print("ℹ️ Removed existing image file at \(imagePath.path)")
                    }
                    try data.write(to: imagePath)
                    print("✅ Saved image '\(filename)' at path \(imagePath.path)")
                    savedImageFiles.append(filename)
                } catch {
                    let errMsg = "❌ Failed to write image '\(filename)' at path \(imagePath.path): \(error)"
                    print(errMsg)
                    lastError = errMsg
                    throw error
                }
            } else {
                let warnMsg = "⚠️ Could not resize or encode image for \(filename), skipping this scale."
                print(warnMsg)
            }
        }

        // Save metadata with quality scores as metadata.json inside object folder
        let metadata = EnhancedObjectMetadata(
            sourceImageId: "img_\(timestamp)",
            label: box.label,
            boundingBox: box.rect,
            scaledBoundingBox: CGRect(
                x: box.rect.origin.x * image.size.width,
                y: box.rect.origin.y * image.size.height,
                width: box.rect.width * image.size.width,
                height: box.rect.height * image.size.height
            ),
            detectionMethod: box.detectionMethod,
            timestamp: Date(),
            deviceInfo: getDeviceInfo(),
            allBoxesInImage: allBoxes.map { b in
                EnhancedObjectMetadata.BoxInfo(label: b.label, rect: b.rect)
            },
            qualityMetrics: qualityMetrics
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let metadataData = try encoder.encode(metadata)
        let metadataPath = objectFolder.appendingPathComponent("metadata.json")

        do {
            // Remove existing metadata file if present to avoid conflicts
            if FileManager.default.fileExists(atPath: metadataPath.path) {
                try FileManager.default.removeItem(at: metadataPath)
                print("ℹ️ Removed existing metadata.json at \(metadataPath.path)")
            }
            try metadataData.write(to: metadataPath)
            print("✅ Saved metadata.json at path \(metadataPath.path)")
        } catch {
            let errMsg = "❌ Failed to write metadata.json at path \(metadataPath.path): \(error)"
            print(errMsg)
            lastError = errMsg
            throw error
        }

        print("✅ Saved object for label '\(box.label)' at folder '\(objectFolder.path)' with files: \(savedImageFiles.joined(separator: ", ")) and metadata.json")
    }

    // MARK: - Helper Methods

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        let ratio = min(maxDimension / size.width, maxDimension / size.height)

        if ratio >= 1.0 {
            return image
        }

        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resized
    }

    private func getDeviceInfo() -> String {
        let device = UIDevice.current
        return "\(device.model) - iOS \(device.systemVersion)"
    }

    /// Sanitizes a label string by trimming whitespace and replacing all non-alphanumeric characters with underscores.
    private func sanitizedLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "[^A-Za-z0-9_]"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        let sanitized = regex?.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_") ?? trimmed
        return sanitized
    }

    // MARK: - Export from Dataset

    func prepareExportFromDataset() {
        // This gathers all boxes from the dataset for export
        pendingBoxes.removeAll()

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

            for labelFolder in labelFolders {
                let objectFolders = try FileManager.default.contentsOfDirectory(
                    at: labelFolder,
                    includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.hasPrefix("Object_") }

                for objectFolder in objectFolders {
                    let metadataPath = objectFolder.appendingPathComponent("metadata.json")
                    if let data = try? Data(contentsOf: metadataPath),
                       let metadata = try? JSONDecoder().decode(EnhancedObjectMetadata.self, from: data)
                    {
                        let box = LabeledBox(
                            id: UUID(),
                            label: metadata.label,
                            rect: metadata.boundingBox,
                            isSaved: true,
                            detectionMethod: metadata.detectionMethod
                        )
                        pendingBoxes.append(box)
                    }
                }
            }

            // Initialize selected labels with all labels
            exportOptions.selectedLabels = Set(pendingBoxes.map { $0.label })

        } catch {
            print("Error preparing export: \(error)")
        }
    }

    // MARK: - Execute Export

    func executeExportForSharing() {
        guard !pendingBoxes.isEmpty else { return }

        isExporting = true
        shareItems.removeAll()

        Task {
            do {
                let exportURL = try await createExportPackage()

                await MainActor.run {
                    self.shareItems = [exportURL]
                    self.isExporting = false
                }

            } catch {
                print("Export error: \(error)")
                await MainActor.run {
                    self.isExporting = false
                }
            }
        }
    }

    private func createExportPackage() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let exportFolder = tempDir.appendingPathComponent("VisionBuilder_Export_\(Date().timeIntervalSince1970)")
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)

        // Create format-specific export
        switch exportOptions.format {
        case .visionBuilder:
            try await exportVisionBuilderFormat(to: exportFolder)
        case .createML:
            try await exportCreateMLFormat(to: exportFolder)
        case .yolo:
            try await exportYOLOFormat(to: exportFolder)
        }

        // Create zip
        let zipURL = tempDir.appendingPathComponent("VisionBuilder_Export.zip")
        try FileManager.default.zipItem(at: exportFolder, to: zipURL)

        return zipURL
    }

    private func exportVisionBuilderFormat(to _: URL) async throws {
        // Implementation specific to Vision Builder format
        // Copy images and metadata as-is
    }

    // MARK: - Export in Create ML format

    private func exportCreateMLFormat(to folder: URL) async throws {
        /*
         This method exports all pendingBoxes that match selectedLabels into a Create ML formatted JSON file.
         It copies the associated images into the export folder with unique filenames and creates a JSON file listing all images with bounding boxes.
         */

        // Filter boxes by selected labels removed as unused

        // Dictionary: imageId -> array of boxes removed as unused

        // We'll assume each box has a unique id or can be grouped per image by sourceImageId.
        // Since LabeledBox doesn't have sourceImageId, we group all boxes as single export unit.
        // For this example, all boxes are from one image, so treat all as one image.
        // But to comply with Create ML format, we need images info.
        // We will generate unique image filenames for the export.

        // For simplicity, and since pendingBoxes have no direct folder reference,
        // we will scan Documents/<label>/Object_* folders, and process only those matching selectedLabels.

        // Prepare Create ML JSON structure:
        // {
        //   "images": [
        //     {
        //       "imageName": "filename.jpg",
        //       "annotations": [
        //         {"label": "label", "coordinates": {"x": ..., "y": ..., "width": ..., "height": ...}}
        //       ]
        //     },
        //     ...
        //   ]
        // }

        struct CreateMLAnnotation: Codable {
            let label: String
            let coordinates: Coordinates

            struct Coordinates: Codable {
                let x: Float
                let y: Float
                let width: Float
                let height: Float
            }
        }

        struct CreateMLImageEntry: Codable {
            let imageName: String
            let annotations: [CreateMLAnnotation]
        }

        struct CreateMLRoot: Codable {
            let images: [CreateMLImageEntry]
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var createMLImages: [CreateMLImageEntry] = []

        // Sorted selected labels for consistency
        let selectedLabelsSorted = exportOptions.selectedLabels.sorted()

        for label in selectedLabelsSorted {
            let trimmedLabel = sanitizedLabel(label)
            let labelFolder = documentsPath.appendingPathComponent(trimmedLabel)

            guard FileManager.default.fileExists(atPath: labelFolder.path) else {
                continue
            }

            // Get all object folders for label
            let objectFolders = try FileManager.default.contentsOfDirectory(
                at: labelFolder,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("Object_") }

            for objectFolder in objectFolders {
                // Metadata path
                let metadataPath = objectFolder.appendingPathComponent("metadata.json")

                guard let data = try? Data(contentsOf: metadataPath),
                      let metadata = try? JSONDecoder().decode(EnhancedObjectMetadata.self, from: data)
                else {
                    continue
                }

                // Only include if label matches selectedLabels
                guard exportOptions.selectedLabels.contains(metadata.label) else {
                    continue
                }

                // Determine image file name based on imageScale option
                let imageFileName: String
                switch exportOptions.imageScale {
                case .low:
                    imageFileName = "image_640.jpg"
                case .medium:
                    imageFileName = "image_1280.jpg"
                case .high:
                    imageFileName = "image_1280.jpg" // No 2048 stored, use 1280 as closest higher
                case .original:
                    imageFileName = "image_full.jpg"
                }

                let imagePath = objectFolder.appendingPathComponent(imageFileName)
                guard FileManager.default.fileExists(atPath: imagePath.path) else {
                    continue
                }

                // Copy the image to export folder with unique name
                let uniqueImageName = "\(trimmedLabel)_\(objectFolder.lastPathComponent).jpg"
                let destImageURL = folder.appendingPathComponent(uniqueImageName)

                try? FileManager.default.removeItem(at: destImageURL)
                try FileManager.default.copyItem(at: imagePath, to: destImageURL)

                // Gather all boxes related to this image/object that are selected
                let boxesForImage = pendingBoxes.filter { box in
                    box.label == metadata.label &&
                        exportOptions.selectedLabels.contains(box.label) &&
                        // To ensure box belongs to this objectFolder, match boundingBox with metadata boundingBox
                        // Because we don't have direct link, match by CGRect approx equal within some tolerance
                        box.rect.intersects(metadata.boundingBox)
                }

                // Create annotations for each box
                var annotations: [CreateMLAnnotation] = []
                for box in boxesForImage {
                    // Coordinates expected in absolute pixels relative to image size for Create ML
                    // Use scaledBoundingBox from metadata for reference box rects
                    // But we only have box.rect normalized, so calculate coords relative to image size
                    // In the export, we use absolute pixel coordinates, so must get image size:

                    // We attempt to get image size from UIImage
                    guard let image = UIImage(contentsOfFile: destImageURL.path) else {
                        continue
                    }
                    let imgWidth = Float(image.size.width)
                    let imgHeight = Float(image.size.height)

                    let x = Float(box.rect.origin.x) * imgWidth
                    let y = Float(box.rect.origin.y) * imgHeight
                    let width = Float(box.rect.size.width) * imgWidth
                    let height = Float(box.rect.size.height) * imgHeight

                    let annotation = CreateMLAnnotation(
                        label: box.label,
                        coordinates: .init(x: x, y: y, width: width, height: height)
                    )
                    annotations.append(annotation)
                }

                if !annotations.isEmpty {
                    let imageEntry = CreateMLImageEntry(imageName: uniqueImageName, annotations: annotations)
                    createMLImages.append(imageEntry)
                }
            }
        }

        // Encode and write Create ML JSON file
        let createMLJson = CreateMLRoot(images: createMLImages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(createMLJson)

        let jsonURL = folder.appendingPathComponent("create_ml_annotations.json")
        try jsonData.write(to: jsonURL)
    }

    // MARK: - Export in YOLO format

    private func exportYOLOFormat(to folder: URL) async throws {
        /*
         Exports images and annotations in YOLO format.
         For each object in pendingBoxes matching selectedLabels:
         - Copy the image at the scale specified in exportOptions.imageScale
         - Create a .txt annotation file with lines: class_id center_x center_y width height (normalized)
         - class_id is the index of the label in sorted selectedLabels array
         */

        let selectedLabelsSorted = exportOptions.selectedLabels.sorted()
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Group boxes by object folder object to generate one annotation file per image
        // Because pendingBoxes don't have objectFolder info, we traverse folders like in createML

        // We will create a mapping: objectFolderURL -> [LabeledBox]
        var objectFolderToBoxes: [URL: [LabeledBox]] = [:]

        for label in selectedLabelsSorted {
            let trimmedLabel = sanitizedLabel(label)
            let labelFolder = documentsPath.appendingPathComponent(trimmedLabel)

            guard FileManager.default.fileExists(atPath: labelFolder.path) else {
                continue
            }

            // Get all object folders for label
            let objectFolders = try FileManager.default.contentsOfDirectory(
                at: labelFolder,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("Object_") }

            for objectFolder in objectFolders {
                let metadataPath = objectFolder.appendingPathComponent("metadata.json")

                guard let data = try? Data(contentsOf: metadataPath),
                      let metadata = try? JSONDecoder().decode(EnhancedObjectMetadata.self, from: data)
                else {
                    continue
                }

                guard exportOptions.selectedLabels.contains(metadata.label) else {
                    continue
                }

                // Find boxes in pendingBoxes that belong to this object folder by intersecting bounding boxes
                let boxesForObject = pendingBoxes.filter { box in
                    box.label == metadata.label &&
                        exportOptions.selectedLabels.contains(box.label) &&
                        box.rect.intersects(metadata.boundingBox)
                }

                if !boxesForObject.isEmpty {
                    objectFolderToBoxes[objectFolder] = boxesForObject
                }
            }
        }

        // For each object folder, copy image and create annotation file
        for (objectFolder, boxes) in objectFolderToBoxes {
            // Determine image filename based on imageScale
            let imageFileName: String
            switch exportOptions.imageScale {
            case .low:
                imageFileName = "image_640.jpg"
            case .medium:
                imageFileName = "image_1280.jpg"
            case .high:
                imageFileName = "image_1280.jpg" // fallback for 2048 doesn't exist
            case .original:
                imageFileName = "image_full.jpg"
            }

            let imagePath = objectFolder.appendingPathComponent(imageFileName)
            guard FileManager.default.fileExists(atPath: imagePath.path) else {
                continue
            }

            // Copy image to export folder with unique name
            let trimmedLabel = sanitizedLabel(boxes.first?.label ?? "unknown")
            let uniqueImageName = "\(trimmedLabel)_\(objectFolder.lastPathComponent).jpg"
            let destImageURL = folder.appendingPathComponent(uniqueImageName)

            try? FileManager.default.removeItem(at: destImageURL)
            try FileManager.default.copyItem(at: imagePath, to: destImageURL)

            // Load image size for normalization removed as unused

            // Build YOLO annotation content
            // class_id center_x center_y width height (normalized in [0,1])
            var yoloLines: [String] = []

            for box in boxes {
                guard let classIndex = selectedLabelsSorted.firstIndex(of: box.label) else {
                    continue
                }

                // Convert CGRect normalized coordinates to YOLO format
                let centerX = box.rect.midX
                let centerY = box.rect.midY
                let width = box.rect.width
                let height = box.rect.height

                // YOLO format expects normalized coordinates relative to image size (already normalized in box.rect)
                let line = "\(classIndex) \(String(format: "%.6f", centerX)) \(String(format: "%.6f", centerY)) \(String(format: "%.6f", width)) \(String(format: "%.6f", height))"
                yoloLines.append(line)
            }

            // Write annotation file with same base name but .txt extension
            let txtFileName = uniqueImageName.replacingOccurrences(of: ".jpg", with: ".txt")
            let annotationURL = folder.appendingPathComponent(txtFileName)
            let annotationContent = yoloLines.joined(separator: "\n")

            try annotationContent.write(to: annotationURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable {
    case visionBuilder = "Vision Builder"
    case createML = "Create ML"
    case yolo = "YOLO"

    var icon: String {
        switch self {
        case .visionBuilder: return "cube.box"
        case .createML: return "apple.logo"
        case .yolo: return "doc.text"
        }
    }

    var description: String {
        switch self {
        case .visionBuilder: return "Native format with full metadata"
        case .createML: return "Apple's ML training format"
        case .yolo: return "Popular object detection format"
        }
    }
}

// MARK: - Image Scale

enum ImageScale: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case original = "Original"

    var icon: String {
        switch self {
        case .low: return "photo.fill"
        case .medium: return "photo"
        case .high: return "photo.badge.plus"
        case .original: return "photo.stack"
        }
    }

    var description: String {
        switch self {
        case .low: return "640px - Fast processing"
        case .medium: return "1280px - Balanced"
        case .high: return "2048px - High quality"
        case .original: return "Full resolution"
        }
    }

    var maxDimension: CGFloat {
        switch self {
        case .low: return 640
        case .medium: return 1280
        case .high: return 2048
        case .original: return .infinity
        }
    }
}

// MARK: - FileManager Extension

extension FileManager {
    func zipItem(at sourceURL: URL, to destinationURL: URL) throws {
        #if os(macOS)
            // macOS can use Process
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            task.arguments = ["-r", destinationURL.path, sourceURL.lastPathComponent]
            task.currentDirectoryURL = sourceURL.deletingLastPathComponent()

            try task.run()
            task.waitUntilExit()
        #else
            // iOS doesn't have Process, so we need an alternative approach
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            // Create a temporary directory structure
            let tempDir = destinationURL.deletingLastPathComponent()
                .appendingPathComponent("temp_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            // Copy the source to temp
            let destInTemp = tempDir.appendingPathComponent(sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: destInTemp)
            // For iOS, we would need to use a compression library
            // For now, just move the temp folder to destination
            try FileManager.default.moveItem(at: tempDir, to: destinationURL)
            // Note: In production, install a compression library like:
            // - ZIPFoundation via Swift Package Manager
            // - DataCompression
            // Then use: try FileManager.default.zipItem(at: sourceURL, to: destinationURL, compressionMethod: .deflate)
        #endif
    }
}
