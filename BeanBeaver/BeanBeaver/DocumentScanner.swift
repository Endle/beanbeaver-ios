import SwiftUI
import VisionKit
import os

extension Logger {
    /// Camera presentation and VisionKit's delegate callbacks.
    ///
    /// VisionKit's own finish button is outside this app's code: if a tap on it
    /// never reaches `didFinishWith`, nothing on screen distinguishes that from
    /// a scan this app dropped. These lines make the two separable in a device
    /// log (`subsystem == "com.beanbeaver.BeanBeaver"`). `.notice` so they are
    /// persisted and survive into a `log collect`; values are counts, sizes and
    /// flags, never receipt content, so they are logged `.public`.
    static let scanner = Logger(subsystem: "com.beanbeaver.BeanBeaver", category: "scanner")
}

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
        // Appear/disappear rather than the flag that presents this: a SwiftUI
        // presentation can be requested and never shown (see the result-cover
        // notes in CLAUDE.md), and only these say it actually was.
        .onDisappear { Logger.scanner.notice("camera cover disappeared") }
        .onAppear {
            Logger.scanner.notice("camera cover appeared (hint: \(!hasSeenScanSaveHint, privacy: .public))")
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
        Logger.scanner.notice("camera \(context.coordinator.session, privacy: .public) created")
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner
        /// Ties each callback to the camera it came from, should SwiftUI ever
        /// rebuild the controller while one is on screen.
        let session = String(UUID().uuidString.prefix(8))
        init(_ parent: DocumentScanner) { self.parent = parent }

        /// VisionKit holds its delegate weakly, so a coordinator released while
        /// its camera is still up turns every button in that camera into a
        /// silent no-op. Logged so that case shows up rather than being
        /// inferred.
        deinit {
            let session = session
            Logger.scanner.notice("camera \(session, privacy: .public) coordinator released")
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // Use the most recent page; encode to JPEG for the Rust seam.
            if scan.pageCount > 0,
               let data = scan.imageOfPage(at: scan.pageCount - 1).jpegData(compressionQuality: 0.9) {
                Logger.scanner.notice("""
                    camera \(self.session, privacy: .public) finished: \(scan.pageCount, privacy: .public) \
                    page(s), last page \(data.count, privacy: .public) bytes
                    """)
                parent.onScan(data)
            } else {
                // Closes the camera with nothing to read — no result, no error.
                Logger.scanner.error("""
                    camera \(self.session, privacy: .public) finished with no usable page \
                    (\(scan.pageCount, privacy: .public) page(s))
                    """)
            }
            parent.onFinish()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            Logger.scanner.notice("camera \(self.session, privacy: .public) cancelled")
            parent.onFinish()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            Logger.scanner.error("""
                camera \(self.session, privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
            parent.onFinish()
        }
    }
}
