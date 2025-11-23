import SwiftUI

// The sample DatasetTabView is now the primary DatasetTabView used for the Dataset tab.
// struct DatasetTabView: View {
//     @EnvironmentObject private var datasetManager: DatasetManager
//     @EnvironmentObject private var exportManager: ExportManager
//     @State private var selectedImage: DatasetImage?

//     var body: some View {
//         NavigationView {
//             VStack {
//                 if datasetManager.datasetImages.isEmpty {
//                     Text("No images in dataset yet.")
//                         .font(.title3)
//                         .foregroundColor(.secondary)
//                         .padding()
//                 } else {
//                     ScrollView(.vertical) {
//                         LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
//                             ForEach(datasetManager.datasetImages) { image in
//                                 if let uiImage = UIImage(contentsOfFile: image.filepath) {
//                                     Button(action: { selectedImage = image }) {
//                                         Image(uiImage: uiImage)
//                                             .resizable()
//                                             .aspectRatio(1, contentMode: .fit)
//                                             .cornerRadius(8)
//                                             .shadow(radius: 4)
//                                     }
//                                 }
//                             }
//                         }
//                         .padding()
//                     }
//                 }
//             }
//             .navigationTitle("Dataset")
//             .sheet(item: $selectedImage) { image in
//                 DatasetImageViewer(datasetImage: image) {
//                     selectedImage = nil
//                 }
//             }
//         }
//     }
// }

// Preview (uses an empty DatasetManager for simplicity)
#Preview {
    DatasetTabView()
        .environmentObject(DatasetManager())
        .environmentObject(ExportManager())
}
