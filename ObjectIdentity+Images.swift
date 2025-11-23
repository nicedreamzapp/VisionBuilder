// This file keeps UIKit helpers on the main actor to avoid tainting SwiftData models with @MainActor isolation.
import Foundation
import UIKit

@MainActor
extension ObjectIdentity {
    var representativeImage: UIImage? {
        guard let data = representativeImageData else { return nil }
        return UIImage(data: data)
    }

    func setRepresentativeImage(_ image: UIImage) {
        self.representativeImageData = image.jpegData(compressionQuality: 0.8)
    }
}

@MainActor
extension ObjectInstance {
    var cropImage: UIImage? {
        guard let data = cropImageData else { return nil }
        return UIImage(data: data)
    }

    func setCropImage(_ image: UIImage) {
        self.cropImageData = image.jpegData(compressionQuality: 0.8)
    }
}
