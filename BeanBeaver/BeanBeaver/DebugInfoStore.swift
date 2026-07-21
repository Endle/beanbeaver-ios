import Foundation
import BBReceiptKit

/// Backs the opt-in "Store detailed debug info" setting (Settings › Debug,
/// off by default). Enabling it keeps a full copy of each scan's parsed
/// contents — merchant, items, prices, the raw OCR text, per-field
/// confidence, and the generated beancount — plus internal error detail, in
/// a JSON file per scan, so a specific problem can be diagnosed later. That's
/// more than BeanBeaver normally retains, so every entry point here is a
/// no-op unless `isEnabled`; nothing is written by default.
enum DebugInfoStore {
    static let enabledKey = "storeDetailedDebugInfo"
    private static let filenamePrefix = "debug_info_"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DebugInfo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Full snapshot of one parsed receipt, for diagnosis. Deliberately richer
    /// than `ReceiptExportJSON` (the ledger sidecar, which trims to what the
    /// ledger needs): this keeps everything the parser returns — the raw OCR
    /// dump, the merchant resolution, per-field confidence, split tenders, and
    /// the generated beancount — so a bad parse can be understood off-device
    /// without re-running the scan on hardware.
    private struct DebugReceiptJSON: Encodable {
        struct Item: Encodable {
            let description: String
            let price: String
            let quantity: Int32
            let category: String?
            let tags: [String]
        }
        struct Merchant: Encodable {
            let raw: String
            let canonical: String?
            let status: String
            let score: Double
        }
        struct Tender: Encodable {
            let amount: String
            let account: String?
            let kind: String
            let rawLabel: String
        }
        struct Confidence: Encodable {
            let merchant: Double
            let date: Double
            let total: Double
            let itemsCategorized: Double
            let needsReview: Bool
        }
        /// A parser warning paired with the item it follows (nil = not tied to a
        /// specific line), reconstructed from the parallel `warnings` /
        /// `warningAfterItemIndices` arrays the FFI returns.
        struct Warning: Encodable {
            let message: String
            let afterItemIndex: Int32?
        }
        struct Timings: Encodable {
            let prepMs: Double
            let detectMs: Double
            let classifyMs: Double
            let recognizeMs: Double
            let parseMs: Double
            let totalMs: Double
            /// Swift-observed total (incl. decode + FFI); nil when unavailable.
            let wallMs: Double?
        }

        let merchant: String
        let merchantMatch: Merchant
        let date: String?
        let dateIsPlaceholder: Bool
        let total: String
        let subtotal: String?
        let tax: String?
        let items: [Item]
        let warnings: [Warning]
        let tenders: [Tender]
        let confidence: Confidence
        let rawText: String
        let imageFilename: String
        let beancount: String
        let beanbeaverId: String?
        let documentRelpath: String?
        let timings: Timings

        init(_ r: ReceiptResult, wallMs: Double?) {
            merchant = r.merchant
            merchantMatch = Merchant(
                raw: r.merchantMatch.raw, canonical: r.merchantMatch.canonical,
                status: String(describing: r.merchantMatch.status), score: r.merchantMatch.score)
            date = r.date
            dateIsPlaceholder = r.dateIsPlaceholder
            total = r.total
            subtotal = r.subtotal
            tax = r.tax
            items = r.items.map {
                Item(description: $0.description, price: $0.price, quantity: $0.quantity,
                     category: $0.category, tags: $0.tags)
            }
            warnings = r.warnings.enumerated().map { i, message in
                let idx = i < r.warningAfterItemIndices.count ? r.warningAfterItemIndices[i] : -1
                return Warning(message: message, afterItemIndex: idx >= 0 ? idx : nil)
            }
            tenders = r.tenders.map {
                Tender(amount: $0.amount, account: $0.account, kind: $0.kind, rawLabel: $0.rawLabel)
            }
            confidence = Confidence(
                merchant: r.confidence.merchant, date: r.confidence.date, total: r.confidence.total,
                itemsCategorized: r.confidence.itemsCategorized, needsReview: r.confidence.needsReview)
            rawText = r.rawText
            imageFilename = r.imageFilename
            beancount = r.beancount
            beanbeaverId = r.beanbeaverId
            documentRelpath = r.documentRelpath
            timings = Timings(
                prepMs: r.timings.ms(.prep), detectMs: r.timings.ms(.detect),
                classifyMs: r.timings.ms(.classify), recognizeMs: r.timings.ms(.recognize),
                parseMs: r.timings.ms(.parse), totalMs: r.timings.totalMs, wallMs: wallMs)
        }
    }

    /// App/OS/device the dump was captured on, so a stored (or shared) entry is
    /// self-describing — a parse bug often hangs on the exact core build or the
    /// device's compute, both of which are otherwise invisible in the JSON.
    private struct Environment: Encodable {
        let appVersion: String
        let appBuild: String
        let os: String
        let device: String

        static var current: Environment {
            let info = Bundle.main.infoDictionary
            var sys = utsname()
            uname(&sys)
            let device = withUnsafeBytes(of: &sys.machine) { raw -> String in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return Environment(
                appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
                appBuild: info?["CFBundleVersion"] as? String ?? "?",
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                device: device)
        }
    }

    private struct Entry: Encodable {
        let generatedAt: Date
        let outcome: String
        let environment: Environment
        let receipt: DebugReceiptJSON?
        let error: String?
    }

    /// Record a completed scan. No-op unless the setting is on.
    static func recordSuccess(result: ReceiptResult, wallMs: Double?) {
        guard isEnabled else { return }
        write(Entry(generatedAt: Date(), outcome: "success", environment: .current,
                    receipt: DebugReceiptJSON(result, wallMs: wallMs), error: nil))
    }

    /// Record a failed scan. No-op unless the setting is on.
    static func recordFailure(_ error: Error) {
        guard isEnabled else { return }
        write(Entry(generatedAt: Date(), outcome: "failed", environment: .current,
                    receipt: nil, error: String(describing: error)))
    }

    /// Record a ledger export failure — `message` is already the
    /// user-facing string (same `(error as? LocalizedError)?.errorDescription
    /// ?? error.localizedDescription` the call sites use), so this carries
    /// whatever request context that message was built with. No-op unless the
    /// setting is on.
    static func recordExportFailure(context: String, message: String) {
        guard isEnabled else { return }
        write(Entry(generatedAt: Date(), outcome: "export_failed", environment: .current,
                    receipt: nil, error: "\(context): \(message)"))
    }

    private static func write(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        try? data.write(to: directory.appendingPathComponent("\(filenamePrefix)\(stamp).json"))
    }

    struct StoredEntry: Identifiable {
        let id: String
        let url: URL
        let modified: Date?
        let byteCount: Int
    }

    static func allEntries() -> [StoredEntry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix(filenamePrefix) }
            .map { url -> StoredEntry in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return StoredEntry(id: url.lastPathComponent, url: url,
                                    modified: values?.contentModificationDate,
                                    byteCount: values?.fileSize ?? 0)
            }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    @discardableResult
    static func clearAll() -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for entry in allEntries() {
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            count += 1
            bytes += Int64(entry.byteCount)
        }
        return (count, bytes)
    }
}
