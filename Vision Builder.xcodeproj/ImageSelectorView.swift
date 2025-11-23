import PhotosUI
import SwiftUI

struct ImageSelectorView: UIViewControllerRepresentable {
    var onComplete: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        print("🎯 DEBUG: Photo picker created")
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImageSelectorView

        init(_ parent: ImageSelectorView) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            print("🎯 DEBUG: Photo picker finished, results count: \(results.count)")
            picker.dismiss(animated: true)

            guard let result = results.first else {
                print("🎯 DEBUG: No photo selected, calling onComplete(nil)")
                parent.onComplete(nil)
                return
            }

            print("🎯 DEBUG: Loading selected photo...")
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("❌ DEBUG: Error loading photo: \(error)")
                        self.parent.onComplete(nil)
                    } else if let image = object as? UIImage {
                        print("✅ DEBUG: Photo loaded successfully, size: \(image.size)")
                        self.parent.onComplete(image)
                    } else {
                        print("❌ DEBUG: Photo object is not UIImage")
                        self.parent.onComplete(nil)
                    }
                }
            }
        }
    }
}
