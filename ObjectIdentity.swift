//
//  ObjectIdentity.swift
//  Vision Builder
//

import Foundation
import SwiftData
import UIKit
@preconcurrency import CoreGraphics

@Model
final class ObjectIdentity {
    var id: UUID
    var label: String
    var createdAt: Date
    var lastSeenAt: Date
    var instanceCount: Int
    @Attribute(.externalStorage) var representativeImageData: Data?
    @Relationship(deleteRule: .cascade, inverse: \ObjectInstance.identity)
    var instances: [ObjectInstance]
    var prototypeEmbedding: [Float]
    var notes: String?
    var tags: [String]
    
    init(
        id: UUID = UUID(),
        label: String,
        prototypeEmbedding: [Float],
        representativeImageData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.prototypeEmbedding = prototypeEmbedding
        self.representativeImageData = representativeImageData
        self.createdAt = createdAt
        self.lastSeenAt = createdAt
        self.instanceCount = 0
        self.instances = []
        self.notes = nil
        self.tags = []
    }
}

@Model
final class ObjectInstance {
    var id: UUID
    var identity: ObjectIdentity?
    var detectedAt: Date
    var sourceImagePath: String?
    var boundingBoxX: Double
    var boundingBoxY: Double
    var boundingBoxWidth: Double
    var boundingBoxHeight: Double
    var embedding: [Float]
    var detectionConfidence: Float
    var imageQuality: Float
    @Attribute(.externalStorage) var cropImageData: Data?
    var isVerified: Bool
    var recognitionConfidence: Float?
    var contourPoints: [CGPoint]?
    
    init(
        id: UUID = UUID(),
        embedding: [Float],
        boundingBox: BoundingBox,
        contourPoints: [CGPoint]? = nil,
        detectedAt: Date = Date(),
        detectionConfidence: Float = 1.0,
        imageQuality: Float = 1.0
    ) {
        self.id = id
        self.embedding = embedding
        self.boundingBoxX = boundingBox.x
        self.boundingBoxY = boundingBox.y
        self.boundingBoxWidth = boundingBox.width
        self.boundingBoxHeight = boundingBox.height
        self.contourPoints = contourPoints
        self.detectedAt = detectedAt
        self.detectionConfidence = detectionConfidence
        self.imageQuality = imageQuality
        self.isVerified = false
        self.recognitionConfidence = nil
    }
    
    var boundingBox: BoundingBox {
        BoundingBox(x: boundingBoxX, y: boundingBoxY, width: boundingBoxWidth, height: boundingBoxHeight)
    }
    
    @Transient var _cropUIImage: UIImage? {
        guard let data = cropImageData else { return nil }
        return UIImage(data: data)
    }
    
    func _setCropUIImage(_ image: UIImage) {
        self.cropImageData = image.jpegData(compressionQuality: 0.8)
    }
}

@Model
final class UnlabeledCluster {
    var id: UUID
    @Relationship(deleteRule: .cascade)
    var instances: [ObjectInstance]
    var centroidEmbedding: [Float]
    var createdAt: Date
    var representativeInstanceID: UUID?
    var hasBeenPresented: Bool
    var userLabel: String?
    var labeledAt: Date?
    
    init(
        id: UUID = UUID(),
        instances: [ObjectInstance] = [],
        centroidEmbedding: [Float],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.instances = instances
        self.centroidEmbedding = centroidEmbedding
        self.createdAt = createdAt
        self.hasBeenPresented = false
    }
    
    var representativeInstance: ObjectInstance? {
        guard let repID = representativeInstanceID else {
            return instances.first
        }
        return instances.first { $0.id == repID }
    }
}

struct BoundingBox: Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    
    init(from rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
    
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

class ObjectRecognitionStorage {
    static let shared = ObjectRecognitionStorage()
    let container: ModelContainer

    private static let storeName = "ObjectRecognition"

    private init() {
        let schema = Schema([
            ObjectIdentity.self,
            ObjectInstance.self,
            UnlabeledCluster.self
        ])

        let config = ModelConfiguration(
            Self.storeName,
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            container = try ModelContainer(for: schema, configurations: [config])
            print("✅ SwiftData ObjectRecognition container initialized")
        } catch {
            print("⚠️ SwiftData migration error, resetting database: \(error)")
            // Delete old database and try again
            Self.deleteDatabase()
            do {
                container = try ModelContainer(for: schema, configurations: [config])
                print("✅ SwiftData ObjectRecognition container recreated after reset")
            } catch {
                fatalError("Failed to initialize SwiftData container after reset: \(error)")
            }
        }
    }

    var context: ModelContext {
        container.mainContext
    }

    /// Delete the database files to allow schema reset
    private static func deleteDatabase() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let storeURL = appSupport.appendingPathComponent("\(storeName).store")
        let walURL = appSupport.appendingPathComponent("\(storeName).store-wal")
        let shmURL = appSupport.appendingPathComponent("\(storeName).store-shm")

        // Also try default.store naming
        let defaultURL = appSupport.appendingPathComponent("default.store")
        let defaultWalURL = appSupport.appendingPathComponent("default.store-wal")
        let defaultShmURL = appSupport.appendingPathComponent("default.store-shm")

        for url in [storeURL, walURL, shmURL, defaultURL, defaultWalURL, defaultShmURL] {
            try? fileManager.removeItem(at: url)
        }

        print("🗑️ Deleted old database files for schema reset")
    }

    /// Manually reset the database (for debugging/settings)
    static func resetDatabase() {
        deleteDatabase()
        print("🔄 Database will be recreated on next app launch")
    }
}

extension ObjectIdentity {
    func updatePrototype() {
        guard !instances.isEmpty else { return }
        let dimension = instances.first?.embedding.count ?? 0
        guard dimension > 0 else { return }
        var sum = [Float](repeating: 0, count: dimension)
        for instance in instances {
            for (i, value) in instance.embedding.enumerated() {
                sum[i] += value
            }
        }
        let count = Float(instances.count)
        prototypeEmbedding = sum.map { $0 / count }
        let magnitude = sqrt(prototypeEmbedding.reduce(0) { $0 + $1 * $1 })
        if magnitude > 0 {
            prototypeEmbedding = prototypeEmbedding.map { $0 / magnitude }
        }
    }
    
    func addInstance(_ instance: ObjectInstance) {
        instances.append(instance)
        instance.identity = self
        instanceCount = instances.count
        lastSeenAt = Date()
        updatePrototype()
        if representativeImageData == nil || instance.imageQuality > (instances.first?.imageQuality ?? 0) {
            representativeImageData = instance.cropImageData
        }
    }
}

extension UnlabeledCluster {
    func selectRepresentative() {
        guard !instances.isEmpty else { return }
        let best = instances.max { a, b in
            if a.imageQuality != b.imageQuality {
                return a.imageQuality < b.imageQuality
            }
            return a.detectionConfidence < b.detectionConfidence
        }
        representativeInstanceID = best?.id
    }
}
