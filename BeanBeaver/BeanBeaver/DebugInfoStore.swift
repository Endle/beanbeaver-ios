import Foundation
import BBReceiptKit

/// Backs the opt-in "Store detailed debug info" setting (Settings › Debug,
/// off by default). Enabling it keeps a full copy of each scan's parsed
/// contents — merchant, items, prices — plus internal error detail, in a
/// JSON file per scan, so a specific problem can be diagnosed later. That's
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

    private struct Entry: Encodable {
        let generatedAt: Date
        let outcome: String
        let receipt: ReceiptExportJSON?
        let error: String?
    }

    /// Record a completed scan. No-op unless the setting is on.
    static func recordSuccess(result: ReceiptResult, wallMs: Double?) {
        guard isEnabled else { return }
        write(Entry(generatedAt: Date(), outcome: "success",
                    receipt: ReceiptExportJSON(result, wallMs: wallMs), error: nil))
    }

    /// Record a failed scan. No-op unless the setting is on.
    static func recordFailure(_ error: Error) {
        guard isEnabled else { return }
        write(Entry(generatedAt: Date(), outcome: "failed", receipt: nil,
                    error: String(describing: error)))
    }

    /// Record a ledger sync/export failure — `message` is already the
    /// user-facing string (same `(error as? LocalizedError)?.errorDescription
    /// ?? error.localizedDescription` the call sites use), so this carries
    /// whatever request context that message was built with. No-op unless the
    /// setting is on.
    static func recordSyncFailure(context: String, message: String) {
        guard isEnabled else { return }
        write(Entry(generatedAt: Date(), outcome: "sync_failed", receipt: nil,
                    error: "\(context): \(message)"))
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
