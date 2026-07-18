import Foundation
import Observation
import os
import BBReceiptKit

/// The process's one loaded `OcrSession`, shared by the single-receipt camera
/// flow (`ReceiptPipeline`) and the photo-library batch (`ReceiptBatch`). A
/// second session would load the models a second time, and they aren't small.
@MainActor
enum OcrSessionProvider {
    private static var session: OcrSession?
    /// Whether `session` was built with the orientation classifier — so a change
    /// to the setting reloads the session on the next scan.
    private static var loadedWithOrientationCls: Bool?

    /// The one global switch for the orientation classifier, read from the
    /// `skipOrientationCheck` default (default off = keep the classifier —
    /// current behavior). Drives both interactive scans and the headless
    /// `BatchRunner`. For a headless A/B it can be overridden per launch via
    /// `-skipOrientationCheck YES|NO` (NSUserDefaults argument domain).
    nonisolated static var useOrientationCls: Bool {
        !UserDefaults.standard.bool(forKey: "skipOrientationCheck")
    }

    static func loaded() throws -> OcrSession {
        let useCls = useOrientationCls
        // Reuse the cached session only if the orientation-cls setting is
        // unchanged; otherwise reload (the classifier is loaded at construction).
        if let session, loadedWithOrientationCls == useCls { return session }
        // OCR runs on CPU: the core is built CPU-only because CPU beats CoreML/ANE
        // on both speed and accuracy for the shipped dynamic-shape mobile models.
        guard let dir = Bundle.main.resourceURL else {
            throw NSError(domain: "BeanBeaver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No app resource bundle"])
        }
        let s = try OcrSession.load(modelsDirectory: dir, useOrientationCls: useCls)
        session = s
        loadedWithOrientationCls = useCls
        return s
    }
}

/// Drives the on-device scan of a single camera-captured receipt: run
/// `OcrSession.scan` off the main thread and publish the result for SwiftUI.
/// The photo-library batch has its own driver (`ReceiptBatch`) but shares the
/// session and `ReceiptCaptureStore`.
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

    /// 0...1 estimated progress through the scan, animated against hardcoded
    /// per-stage duration guesses (see `StepEstimate`) since we don't get a real
    /// progress signal across the FFI boundary. Caps below 1 until the actual
    /// result arrives, so a slow scan never looks falsely complete.
    private(set) var scanProgress: Double = 0

    /// Human-readable label for whichever stage the estimate currently sits in.
    private(set) var scanStepLabel: String = StepEstimate.steps[0].label

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

    private var progressTask: Task<Void, Never>?

    /// Instruments signpost: a "scan" interval per `OcrSession.scan`, so the
    /// on-device latency shows up in the Time Profiler / os_signpost track.
    private static let signposter = OSSignposter(
        subsystem: "com.beanbeaver.BeanBeaver", category: "scan")

    /// Run the pipeline on a JPEG bundled in the app, bypassing the camera and
    /// photo picker. Shipped (not DEBUG-only) so anyone without a receipt in
    /// hand — an App Review tester, a curious first-time user — can still see
    /// the whole scan → beancount flow.
    func scanBundledSample(named name: String) async {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else {
            status = .failed("Bundled sample \(name).jpg not found")
            return
        }
        await scan(imageData: data)
    }

    /// Return to the home screen (idle state) so the user can scan another receipt.
    func reset() {
        status = .idle
        capturedImageURL = nil
        lastWallMs = nil
        progressTask?.cancel()
        scanProgress = 0
        scanStepLabel = StepEstimate.steps[0].label
    }

    func scan(imageData: Data) async {
        status = .scanning
        capturedImageURL = persistCapture(imageData)
        lastWallMs = nil
        scanProgress = 0
        scanStepLabel = StepEstimate.steps[0].label
        progressTask?.cancel()
        progressTask = Task { await self.animateEstimatedProgress() }
        let account = creditCardAccount
        do {
            let session = try OcrSessionProvider.loaded()
            let signpost = Self.signposter.beginInterval("scan")
            let started = Date()
            // OCR is CPU-heavy; keep it off the main actor.
            let result = try await Task.detached(priority: .userInitiated) {
                try session.scan(imageData: imageData, creditCardAccount: account)
            }.value
            lastWallMs = Date().timeIntervalSince(started) * 1000
            Self.signposter.endInterval("scan", signpost)
            progressTask?.cancel()
            scanProgress = 1
            status = .done(result)
            DebugInfoStore.recordSuccess(result: result, wallMs: lastWallMs)
        } catch {
            progressTask?.cancel()
            status = .failed(String(describing: error))
            DebugInfoStore.recordFailure(error)
        }
    }

    /// Hardcoded rough per-stage duration guesses (ms), taken from a typical
    /// on-device scan (see the `ScanTimings.preview` fixture). Used only to
    /// animate a progress bar client-side — not a measurement of the live scan.
    private enum StepEstimate {
        static let steps: [(label: String, ms: Double)] = [
            ("Preparing image…", 28),
            ("Detecting text…", 322),
            ("Checking orientation…", 41),
            ("Recognizing text…", 408),
            ("Parsing receipt…", 17),
        ]
        /// Running total of `ms` after each step, e.g. [28, 350, 391, 799, 816].
        static let cumulativeMs: [Double] = {
            var sum = 0.0
            return steps.map { sum += $0.ms; return sum }
        }()
        static let totalMs = cumulativeMs.last ?? 1
    }

    /// Ticks `scanProgress`/`scanStepLabel` by comparing elapsed time against
    /// `StepEstimate`, since there's no real progress signal across the FFI
    /// boundary. Caps at 96% so a scan that runs long than the estimate doesn't
    /// look finished before the actual result arrives; `scan(imageData:)` snaps
    /// it to 100% itself once the result is in.
    private func animateEstimatedProgress() async {
        let started = Date()
        while !Task.isCancelled {
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            let stepIndex = StepEstimate.cumulativeMs.firstIndex { elapsedMs < $0 }
                ?? StepEstimate.steps.count - 1
            scanStepLabel = StepEstimate.steps[stepIndex].label
            scanProgress = min(elapsedMs / StepEstimate.totalMs, 0.96)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    /// Write the captured JPEG to a timestamped temp file so it can be exported
    /// via the share sheet (AirDrop / Files / Mail).
    private func persistCapture(_ data: Data) -> URL? {
        let url = ReceiptCaptureStore.newCaptureURL()
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

    /// One raw OCR detection box, mirrored from the Rust `OcrDetection` so the
    /// headless batch output carries the on-device OCR geometry — enough to diff
    /// live boxes against the frozen `.ocr.json` snapshots.
    struct Detection: Codable {
        let pointsXy: [Double]
        let text: String
        let confidence: Double
    }

    /// Per-stage on-device timings (ms) for one scan, mirrored from the Rust
    /// `ScanTimings`, so the headless batch output carries the stage breakdown
    /// (not just wall time) for latency profiling.
    struct Timings: Codable {
        let prepMs: Double
        let detectMs: Double
        let classifyMs: Double
        let recognizeMs: Double
        let parseMs: Double
        let totalMs: Double
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
        let timings: Timings?     // nil only when the scan itself failed
        let error: String?
        // Debug / E2E extras (nil on a failed scan): the full merchant
        // resolution plus the raw OCR text and detection boxes, so live output
        // can be diffed against the frozen `.ocr.json` snapshots. `var` + `nil`
        // default keeps the `.failure` factory below valid.
        var merchantRaw: String? = nil
        var merchantCanonical: String? = nil
        var merchantStatus: String? = nil
        var rawText: String? = nil
        var detections: [Detection]? = nil
    }

    struct Output: Codable {
        let count: Int
        let results: [Result]
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-autoRunBatch")
    }

    /// Value following a launch flag, e.g. `-batchDelaySec 2` → "2".
    static func argValue(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Load the OCR session once, scan every `Documents/batch_in/*.jpg` in sorted
    /// order, then atomically write `Documents/batch_out.json`.
    static func run() async {
        let inDir = documents.appendingPathComponent("batch_in", isDirectory: true)
        let outURL = documents.appendingPathComponent("batch_out.json")
        // Clear any prior run's output up front so a host harness that can't
        // delete the file remotely (devicectl) can treat its reappearance as an
        // unambiguous "this run finished" signal.
        try? FileManager.default.removeItem(at: outURL)

        let images = (try? FileManager.default.contentsOfDirectory(
            at: inDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        // Optional cooldown between scans (`-batchDelaySec N`): run each scan
        // closer to real single-scan conditions (cold SoC) instead of back to
        // back, so the timings aren't skewed by sustained-load throttling.
        let delaySec = argValue("-batchDelaySec").flatMap(Double.init) ?? 0
        NSLog("[Batch] \(images.count) image(s), delay=\(delaySec)s")

        let session = try? OcrSession.load(modelsDirectory: Bundle.main.resourceURL!,
                                           useOrientationCls: OcrSessionProvider.useOrientationCls)
        var results: [Result] = []
        for (i, url) in images.enumerated() {
            let name = url.deletingPathExtension().lastPathComponent
            guard let session, let data = try? Data(contentsOf: url) else {
                results.append(.failure(name, "load failed"))
                continue
            }
            if delaySec > 0 && i > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
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
                    wallMs: Date().timeIntervalSince(started) * 1000,
                    timings: Timings(
                        prepMs: r.timings.prepMs, detectMs: r.timings.detectMs,
                        classifyMs: r.timings.classifyMs, recognizeMs: r.timings.recognizeMs,
                        parseMs: r.timings.parseMs, totalMs: r.timings.totalMs),
                    error: nil,
                    merchantRaw: r.merchantMatch.raw,
                    merchantCanonical: r.merchantMatch.canonical,
                    merchantStatus: "\(r.merchantMatch.status)",
                    rawText: r.rawText,
                    detections: r.detections.map {
                        Detection(pointsXy: $0.pointsXy, text: $0.text, confidence: $0.confidence)
                    }))
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
                           wallMs: 0, timings: nil, error: message)
    }
}
#endif
