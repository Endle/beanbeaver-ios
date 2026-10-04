import SwiftUI

/// The exact photo the OCR saw, shown on request so a user can verify a scan
/// against the original receipt. Pinch or double-tap to zoom in on fine print —
/// see `ZoomableImageView`.
struct OriginReceiptView: View {
    let imageURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed || imageURL == nil {
                    ContentUnavailableView("No Photo Available", systemImage: "photo")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Original Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // A sheet doesn't take its presenter's tint, and this one opens over
        // the result screen and the receipt detail — both brand red.
        .tint(.bbAccent)
        .task(id: imageURL) {
            guard let imageURL else { return }
            // The capture is a JPEG already on disk; decode it off the main
            // thread so opening the sheet never hitches.
            let decoded = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: imageURL.path)
            }.value
            if let decoded { image = decoded } else { loadFailed = true }
        }
    }
}
