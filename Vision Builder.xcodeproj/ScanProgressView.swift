import SwiftUI

struct ScanProgressView: View {
    @ObservedObject var indexer: PhotoLibraryIndexer
    
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            // Progress card
            VStack(spacing: 20) {
                // Animated scanning indicator
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.blue)
                
                VStack(spacing: 8) {
                    Text("Scanning Photos")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text(indexer.currentOperation)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                // Progress bar
                VStack(spacing: 4) {
                    ProgressView(value: indexer.progress)
                        .progressViewStyle(.linear)
                    
                    Text("\(indexer.processedCount) / \(indexer.totalCount) photos")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
                    .shadow(radius: 20)
            )
            .padding(40)
        }
    }
}
