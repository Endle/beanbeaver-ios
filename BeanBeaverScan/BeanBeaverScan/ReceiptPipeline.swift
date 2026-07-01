import Foundation
import Observation
import os
import BBReceiptKit

/// Drives the on-device scan: load models once, then run `OcrSession.scan`
/// off the main thread and publish the result for SwiftUI.
@Observable
@MainActor
final class ReceiptPipeline {
    enum Status {
        case idle
        case scanning
        case done(ReceiptResult)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// The exact JPEG bytes (written to a temp file) that the OCR last saw, for
    /// diagnostics: export it and A/B against the desktop server to isolate the
    /// capture/encode path from the OCR model.
    private(set) var capturedImageURL: URL?

    /// Swift-observed wall time (ms) of the last `OcrSession.scan` call —
    /// includes image decode + FFI marshalling, so it's ≥ the Rust `total_ms`
    /// in `ReceiptResult.timings`. The user-perceived scan latency.
    private(set) var lastWallMs: Double?

    /// Default credit-card account for the placeholder posting; tweak in UI later.
    var creditCardAccount = "Liabilities:CreditCard"

    private var session: OcrSession?

    /// Instruments signpost: a "scan" interval per `OcrSession.scan`, so the
    /// on-device latency shows up in the Time Profiler / os_signpost track.
    private static let signposter = OSSignposter(
        subsystem: "com.beanbeaver.BeanBeaverScan", category: "scan")

    private func loadedSession() throws -> OcrSession {
        if let session { return session }
        // OCR runs on CPU: the core is built CPU-only because CPU beats CoreML/ANE
        // on both speed and accuracy for the shipped dynamic-shape mobile models.
        guard let dir = Bundle.main.resourceURL else {
            throw NSError(domain: "BeanBeaverScan", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No app resource bundle"])
        }
        let s = try OcrSession.load(modelsDirectory: dir)
        session = s
        return s
    }

#if DEBUG
    /// Run the pipeline on a JPEG bundled in the app (debug/demo path that
    /// bypasses the photo picker).
    func scanBundledSample(named name: String) async {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else {
            status = .failed("Bundled sample \(name).jpg not found")
            return
        }
        await scan(imageData: data)
    }
#endif

    func scan(imageData: Data) async {
        status = .scanning
        capturedImageURL = persistCapture(imageData)
        lastWallMs = nil
        let account = creditCardAccount
        do {
            let session = try loadedSession()
            let signpost = Self.signposter.beginInterval("scan")
            let started = Date()
            // OCR is CPU-heavy; keep it off the main actor.
            let result = try await Task.detached(priority: .userInitiated) {
                try session.scan(imageData: imageData, creditCardAccount: account)
            }.value
            lastWallMs = Date().timeIntervalSince(started) * 1000
            Self.signposter.endInterval("scan", signpost)
            status = .done(result)
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// Write the captured JPEG to a timestamped temp file so it can be exported
    /// via the share sheet (AirDrop / Files / Mail).
    private func persistCapture(_ data: Data) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receipt_capture_\(stamp).jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

#if DEBUG
extension ReceiptPipeline {
    /// Preview/screenshot-only factory pinned to a given status, so SwiftUI
    /// previews can render every UI state without running OCR. Must live in this
    /// file: `status`'s setter is `private`.
    static func preview(_ status: Status) -> ReceiptPipeline {
        let pipeline = ReceiptPipeline()
        pipeline.status = status
        return pipeline
    }
}

/// Headless on-device E2E harness. Launched via
/// `simctl launch booted <bid> -autoRunBatch`, it runs every JPEG in the app's
/// `Documents/batch_in/` through the real on-device pipeline (Rust ocr-paddle →
/// receipt-core, exactly as a user scan would) and writes structured results to
/// `Documents/batch_out.json`. A host script pushes the images into the app
/// container and pulls the JSON back to diff against ground-truth fixtures — the
/// "device sim live mode" counterpart to the desktop pytest suite (image bytes
/// in, parsed `ReceiptResult` out, no screenshots, which truncate).
enum BatchRunner {
    struct Item: Codable {
        let description: String
        let price: String
        let category: String?
    }

    struct Result: Codable {
        let name: String          // stem of the input image (maps to <stem>.expected.json)
        let merchant: String
        let date: String?
        let dateIsPlaceholder: Bool
        let total: String
        let subtotal: String?
        let tax: String?
        let items: [Item]
        let warnings: [String]
        let wallMs: Double
        let error: String?
    }

    struct Output: Codable {
        let count: Int
        let results: [Result]
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-autoRunBatch")
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Load the OCR session once, scan every `Documents/batch_in/*.jpg` in sorted
    /// order, then atomically write `Documents/batch_out.json`.
    static func run() async {
        let inDir = documents.appendingPathComponent("batch_in", isDirectory: true)
        let outURL = documents.appendingPathComponent("batch_out.json")

        let images = (try? FileManager.default.contentsOfDirectory(
            at: inDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        let session = try? OcrSession.load(modelsDirectory: Bundle.main.resourceURL!)
        var results: [Result] = []
        for url in images {
            let name = url.deletingPathExtension().lastPathComponent
            guard let session, let data = try? Data(contentsOf: url) else {
                results.append(.failure(name, "load failed"))
                continue
            }
            let started = Date()
            do {
                let r = try session.scan(imageData: data,
                                         creditCardAccount: "Liabilities:CreditCard")
                results.append(Result(
                    name: name, merchant: r.merchant, date: r.date,
                    dateIsPlaceholder: r.dateIsPlaceholder, total: r.total,
                    subtotal: r.subtotal, tax: r.tax,
                    items: r.items.map { Item(description: $0.description,
                                              price: $0.price, category: $0.category) },
                    warnings: r.warnings,
                    wallMs: Date().timeIntervalSince(started) * 1000, error: nil))
            } catch {
                results.append(.failure(name, String(describing: error)))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? encoder.encode(Output(count: results.count, results: results))
        else { return }
        // Write to a temp file then rename so the host never reads a partial file.
        let tmp = outURL.appendingPathExtension("tmp")
        try? bytes.write(to: tmp)
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.moveItem(at: tmp, to: outURL)
    }
}

private extension BatchRunner.Result {
    static func failure(_ name: String, _ message: String) -> BatchRunner.Result {
        BatchRunner.Result(name: name, merchant: "", date: nil, dateIsPlaceholder: false,
                           total: "", subtotal: nil, tax: nil, items: [], warnings: [],
                           wallMs: 0, error: message)
    }
}
#endif
