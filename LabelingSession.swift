// LabelingSession.swift
// Session persistence for labeling workflow
import SwiftUI
import SwiftData
import Combine

// MARK: - Labeling Session Model

@Model
final class LabelingSession {
    var id: UUID
    var createdAt: Date
    var lastModifiedAt: Date
    var sessionName: String
    var totalImages: Int
    var currentImageIndex: Int
    var isCompleted: Bool

    // Store image paths (for library images) or data (for camera)
    var imagePaths: [String]
    @Attribute(.externalStorage) var cameraImageData: [Data]

    // Labeled boxes per image (JSON encoded)
    var labeledBoxesJSON: [String]

    // Quick stats
    var totalObjectsLabeled: Int

    init(
        sessionName: String = "Labeling Session",
        imagePaths: [String] = [],
        cameraImageData: [Data] = []
    ) {
        let imageCount = max(imagePaths.count, cameraImageData.count)
        self.id = UUID()
        self.createdAt = Date()
        self.lastModifiedAt = Date()
        self.sessionName = sessionName
        self.totalImages = imageCount
        self.currentImageIndex = 0
        self.isCompleted = false
        self.imagePaths = imagePaths
        self.cameraImageData = cameraImageData
        self.labeledBoxesJSON = Array(repeating: "[]", count: imageCount)
        self.totalObjectsLabeled = 0
    }

    var progress: Double {
        guard totalImages > 0 else { return 0 }
        return Double(currentImageIndex) / Double(totalImages)
    }

    var remainingImages: Int {
        max(0, totalImages - currentImageIndex)
    }

    var displayName: String {
        if sessionName.isEmpty {
            return "Session \(createdAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return sessionName
    }

    func updateProgress(index: Int, labeledCount: Int) {
        currentImageIndex = index
        totalObjectsLabeled = labeledCount
        lastModifiedAt = Date()
        isCompleted = index >= totalImages
    }

    func saveLabeledBoxes(_ boxes: [LabeledBox], forImageIndex index: Int) {
        guard index < labeledBoxesJSON.count else { return }

        let encoder = JSONEncoder()
        if let data = try? encoder.encode(boxes),
           let json = String(data: data, encoding: .utf8) {
            labeledBoxesJSON[index] = json
        }
        lastModifiedAt = Date()
    }

    func loadLabeledBoxes(forImageIndex index: Int) -> [LabeledBox] {
        guard index < labeledBoxesJSON.count else { return [] }

        let decoder = JSONDecoder()
        if let data = labeledBoxesJSON[index].data(using: .utf8),
           let boxes = try? decoder.decode([LabeledBox].self, from: data) {
            return boxes
        }
        return []
    }
}

// MARK: - Session Storage

class SessionStorage {
    static let shared = SessionStorage()

    private static let storeName = "LabelingSessions"

    lazy var container: ModelContainer = {
        let schema = Schema([LabelingSession.self])
        let config = ModelConfiguration(
            Self.storeName,
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            print("✅ SwiftData LabelingSessions container initialized")
            return container
        } catch {
            print("⚠️ SwiftData session migration error, resetting: \(error)")
            Self.deleteDatabase()
            do {
                let container = try ModelContainer(for: schema, configurations: [config])
                print("✅ SwiftData LabelingSessions container recreated after reset")
                return container
            } catch {
                fatalError("Failed to create session container after reset: \(error)")
            }
        }
    }()

    var context: ModelContext {
        container.mainContext
    }

    private init() {}

    private static func deleteDatabase() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let storeURL = appSupport.appendingPathComponent("\(storeName).store")
        let walURL = appSupport.appendingPathComponent("\(storeName).store-wal")
        let shmURL = appSupport.appendingPathComponent("\(storeName).store-shm")

        for url in [storeURL, walURL, shmURL] {
            try? fileManager.removeItem(at: url)
        }

        print("🗑️ Deleted old session database files")
    }

    @MainActor
    func createSession(from images: [UIImage], name: String = "") -> LabelingSession {
        let imageData = images.compactMap { $0.jpegData(compressionQuality: 0.8) }
        let session = LabelingSession(
            sessionName: name.isEmpty ? "Session \(Date().formatted(date: .abbreviated, time: .shortened))" : name,
            cameraImageData: imageData
        )
        context.insert(session)
        try? context.save()
        return session
    }

    @MainActor
    func getIncompleteSessions() -> [LabelingSession] {
        let descriptor = FetchDescriptor<LabelingSession>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.lastModifiedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    func getRecentSessions(limit: Int = 5) -> [LabelingSession] {
        var descriptor = FetchDescriptor<LabelingSession>(
            sortBy: [SortDescriptor(\.lastModifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    func deleteSession(_ session: LabelingSession) {
        context.delete(session)
        try? context.save()
    }

    @MainActor
    func saveSession(_ session: LabelingSession) {
        try? context.save()
    }
}

// MARK: - Session Manager (Observable)

@MainActor
class SessionManager: ObservableObject {
    @Published var incompleteSessions: [LabelingSession] = []
    @Published var recentSessions: [LabelingSession] = []
    @Published var activeSession: LabelingSession?

    private let storage = SessionStorage.shared

    func refresh() {
        incompleteSessions = storage.getIncompleteSessions()
        recentSessions = storage.getRecentSessions()
    }

    func createSession(from images: [UIImage]) -> LabelingSession {
        let session = storage.createSession(from: images)
        activeSession = session
        refresh()
        return session
    }

    func resumeSession(_ session: LabelingSession) {
        activeSession = session
    }

    func completeSession() {
        if let session = activeSession {
            session.isCompleted = true
            storage.saveSession(session)
        }
        activeSession = nil
        refresh()
    }

    func deleteSession(_ session: LabelingSession) {
        if activeSession?.id == session.id {
            activeSession = nil
        }
        storage.deleteSession(session)
        refresh()
    }

    func saveProgress(index: Int, labeledCount: Int, boxes: [LabeledBox]) {
        guard let session = activeSession else { return }
        session.updateProgress(index: index, labeledCount: labeledCount)
        session.saveLabeledBoxes(boxes, forImageIndex: index)
        storage.saveSession(session)
    }
}
