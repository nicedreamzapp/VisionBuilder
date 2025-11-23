import Combine
import Foundation
import SwiftUI

// MARK: - Dataset Types

struct DatasetImage: Identifiable, Codable {
    var id = UUID()
    let filename: String
    let filepath: String
    let labelFolderName: String
    let objectFolderName: String
    let timestamp: Date
    let fileSize: Int64

    init(filename: String, filepath: String, labelFolderName: String, objectFolderName: String, fileSize: Int64 = 0) {
        id = UUID()
        self.filename = filename
        self.filepath = filepath
        self.labelFolderName = labelFolderName
        self.objectFolderName = objectFolderName
        timestamp = Date()
        self.fileSize = fileSize
    }

    // Create temporary DatasetImage for new photos
    static func createTemporary(from _: UIImage) -> DatasetImage {
        return DatasetImage(
            filename: "temp_image.jpg",
            filepath: "temporary",
            labelFolderName: "New Photo",
            objectFolderName: "temp_object",
            fileSize: 0
        )
    }
}

struct LabelFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    let name: String
    let path: String
    let objectCount: Int
    let lastModified: Date
    var images: [DatasetImage] = [] // Add images array

    init(name: String, path: String, objectCount: Int = 0) {
        id = UUID()
        self.name = name
        self.path = path
        self.objectCount = objectCount
        lastModified = Date()
        images = []
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LabelFolder, rhs: LabelFolder) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - DatasetManager

@MainActor
class DatasetManager: ObservableObject {
    @Published var labelFolders: [LabelFolder] = []
    @Published var isLoading = false
    @Published var currentFolder: LabelFolder?
    @Published var datasetImages: [DatasetImage] = []

    private let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    // Computed property for total object count
    var totalObjectCount: Int {
        labelFolders.reduce(0) { $0 + $1.objectCount }
    }

    func loadDataset() async {
        isLoading = true

        do {
            let folderURLs = try FileManager.default.contentsOfDirectory(
                at: documentsPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            print("Discovered label folders:")
            var folders: [LabelFolder] = []

            for url in folderURLs {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

                guard isDirectory.boolValue,
                      !url.lastPathComponent.hasPrefix("."),
                      url.lastPathComponent != "Dataset"
                else {
                    continue
                }

                // Print the label folder found
                print(" - Label folder: \(url.lastPathComponent)")

                // Count object folders
                let objectCount = countObjectsInFolder(url)

                // Log subfolders and image file existence
                do {
                    let subfolders = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil
                    ).filter { $0.hasDirectoryPath }

                    for subfolder in subfolders {
                        print("   - Subfolder: \(subfolder.lastPathComponent)")

                        let imagePath = subfolder.appendingPathComponent("image_640.jpg")
                        if FileManager.default.fileExists(atPath: imagePath.path) {
                            print("     - Found image_640.jpg")
                        } else {
                            // Check for any other .jpg files for diagnosis
                            if let otherJpg = try? FileManager.default.contentsOfDirectory(at: subfolder, includingPropertiesForKeys: nil)
                                .first(where: { $0.pathExtension.lowercased() == "jpg" }) {
                                print("     - Missing image_640.jpg but found other JPG: \(otherJpg.lastPathComponent)")
                            } else {
                                print("     - No image_640.jpg or any other JPG found")
                            }
                        }
                    }
                } catch {
                    print("   - Error reading subfolders for \(url.lastPathComponent): \(error)")
                }

                var folder = LabelFolder(
                    name: url.lastPathComponent,
                    path: url.path,
                    objectCount: objectCount
                )

                // Load images for this folder
                folder.images = loadImagesForFolder(url)

                folders.append(folder)
            }

            labelFolders = folders.sorted { $0.lastModified > $1.lastModified }
        } catch {
            print("Error loading dataset: \(error)")
        }

        isLoading = false
    }

    func loadImagesForFolder(_ folder: LabelFolder) async {
        currentFolder = folder

        let folderURL = URL(fileURLWithPath: folder.path)
        datasetImages = loadImagesForFolder(folderURL)
    }

    private func loadImagesForFolder(_ folderURL: URL) -> [DatasetImage] {
        do {
            let objectFolders = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("Object_") && $0.hasDirectoryPath }

            return objectFolders.compactMap { objectFolder -> DatasetImage? in
                let imagePath = objectFolder.appendingPathComponent("image_640.jpg")
                guard FileManager.default.fileExists(atPath: imagePath.path) else {
                    return nil
                }

                let fileAttributes = try? FileManager.default.attributesOfItem(atPath: imagePath.path)
                let fileSize = fileAttributes?[.size] as? Int64 ?? 0

                return DatasetImage(
                    filename: "image_640.jpg",
                    filepath: imagePath.path,
                    labelFolderName: folderURL.lastPathComponent,
                    objectFolderName: objectFolder.lastPathComponent,
                    fileSize: fileSize
                )
            }.sorted { $0.timestamp > $1.timestamp }
        } catch {
            print("Error loading images: \(error)")
            return []
        }
    }

    func deleteFolder(_ folder: LabelFolder) {
        let folderURL = URL(fileURLWithPath: folder.path)
        do {
            try FileManager.default.removeItem(at: folderURL)
            labelFolders.removeAll { $0.id == folder.id }
        } catch {
            print("Error deleting folder: \(error)")
        }
    }

    private func countObjectsInFolder(_ folderURL: URL) -> Int {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            return contents.filter { $0.lastPathComponent.hasPrefix("Object_") }.count
        } catch {
            return 0
        }
    }
}

// MARK: - DetectedBox (for SmartAssistant compatibility)

struct DetectedBox: Identifiable, Codable {
    let id: UUID
    var label: String
    var rect: CGRect
    var confidence: Float
    var isSaved: Bool
    var detectionMethod: String?

    init(id: UUID = UUID(), label: String, rect: CGRect, confidence: Float = 1.0, isSaved: Bool = false, detectionMethod: String? = nil) {
        self.id = id
        self.label = label
        self.rect = rect
        self.confidence = confidence
        self.isSaved = isSaved
        self.detectionMethod = detectionMethod
    }

    // Convert from LabeledBox
    init(from labeledBox: LabeledBox) {
        id = labeledBox.id
        label = labeledBox.label
        rect = labeledBox.rect
        confidence = 1.0 // LabeledBox doesn't have confidence
        isSaved = labeledBox.isSaved
        detectionMethod = labeledBox.detectionMethod
    }
}

// MARK: - Extensions for compatibility

extension LabeledBox: Equatable {
    static func == (lhs: LabeledBox, rhs: LabeledBox) -> Bool {
        lhs.id == rhs.id
    }
}

extension LabeledBox {
    // Convert to DetectedBox for compatibility
    var asDetectedBox: DetectedBox {
        return DetectedBox(from: self)
    }
}

extension BoxState {
    // Computed property for compatibility with existing code
    var labeledBoxes: [LabeledBox] {
        get { boxes }
        set { boxes = newValue }
    }
}
