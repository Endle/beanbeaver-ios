import SwiftUI
import VisionKit

/// `DocumentScanner` plus a one-time coaching hint. VisionKit has no delegate
/// callback for "page kept" — only the final `didFinishWith` once the user
/// taps its own top-right "Save" (see `DocumentScanner` below) — so we can't
/// auto-dismiss after a single page. Since we can't detect that moment either,
/// the hint is shown upfront, when the camera opens, rather than pointing at
/// "Save" only once it actually appears.
struct ScannerWithHint: View {
    var onScan: (Data) -> Void
    var onFinish: () -> Void

    /// Persisted so the hint only ever shows once, the first time someone scans.
    @AppStorage("hasSeenScanSaveHint") private var hasSeenScanSaveHint = false
    @State private var showHint = false

    var body: some View {
        ZStack(alignment: .top) {
            DocumentScanner(onScan: onScan, onFinish: onFinish)
                .ignoresSafeArea()

            if showHint {
                ScanSaveHint {
                    withAnimation { showHint = false }
                }
                .padding(.top, 60)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            guard !hasSeenScanSaveHint else { return }
            hasSeenScanSaveHint = true
            withAnimation { showHint = true }
            Task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation { showHint = false }
            }
        }
    }
}

/// "Tap Save to finish" banner — see `ScannerWithHint`.
private struct ScanSaveHint: View {
    var onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 10) {
                Image(systemName: "hand.tap.fill")
                Text("After you snap the photo, tap **Save** (top right) to finish.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// SwiftUI wrapper around VisionKit's document scanner — auto edge-detect,
/// perspective deskew, crop, and rotate. Hands the last scanned page back as
/// JPEG bytes. Not available on the simulator (`isSupported == false`).
struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: (Data) -> Void
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // Use the most recent page; encode to JPEG for the Rust seam.
            if scan.pageCount > 0,
               let data = scan.imageOfPage(at: scan.pageCount - 1).jpegData(compressionQuality: 0.9) {
                parent.onScan(data)
            }
            parent.onFinish()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onFinish()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            parent.onFinish()
        }
    }
}
