import PhotosUI
import SwiftUI

struct ImageSelectorView: UIViewControllerRepresentable {
    var onComplete: ([UIImage]?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 0 // 0 = unlimited selection

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        print("🎯 DEBUG: Photo picker created [multi-mode]")
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

            guard !results.isEmpty else {
                print("🎯 DEBUG: No photos selected, calling onComplete(nil)")
                parent.onComplete(nil)
                return
            }

            let dispatchGroup = DispatchGroup()
            var images: [UIImage] = []

            for result in results {
                dispatchGroup.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    DispatchQueue.main.async {
                        if let image = object as? UIImage {
                            images.append(image)
                        }
                        dispatchGroup.leave()
                    }
                }
            }

            dispatchGroup.notify(queue: .main) {
                print("✅ DEBUG: All selected photos loaded, count: \(images.count)")
                self.parent.onComplete(images.isEmpty ? nil : images)
            }
        }
    }
}
