import Foundation

/// The on-disk home for captured-receipt JPEGs (`ReceiptPipeline.persistCapture`)
/// and for the pending import batch (`ReceiptBatch`'s `batch.json`). A capture
/// is no longer expired by any heuristic here — once a scan succeeds, its photo
/// is owned by that receipt's `SpendRecord` (`SpendStore`) and lives until the
/// user deletes the receipt or clears its photo. This type only knows how to
/// name, total, and delete captures; it has no opinion about which ones a
/// caller should keep.
///
/// Application Support rather than `tmp`: the system purges `tmp` whenever the
/// app isn't running, which for a batch that outlives a launch would strand it
/// on missing photos — and a receipt exported without its photo still carries
/// `document:` metadata pointing at a file that was never uploaded, so the
/// user's ledger gets a silently broken link.
enum ReceiptCaptureStore {
    static let filenamePrefix = "receipt_capture_"

    /// Created on first use and marked backup-excluded, both of which have to be
    /// done by hand: Application Support doesn't exist by default on iOS, and
    /// leaving it in a backup would put receipt photos in iCloud. An unexported
    /// batch is work-in-progress; the user's ledger is the archive.
    static let directory: URL = {
        let fm = FileManager.default
        var url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeanBeaver", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    /// Where `ReceiptPipeline` should write a freshly captured JPEG. The name is
    /// random rather than a timestamp: at one-second resolution two scans landing
    /// in the same second produce the same path, and the second silently
    /// overwrites the first — reachable once a batch parses photos back to back.
    static func newCaptureURL() -> URL {
        directory.appendingPathComponent("\(filenamePrefix)\(UUID().uuidString).jpg")
    }

    /// The capture named `filename`, wherever the container happens to live this
    /// launch. Persisted records store the bare filename, never a URL: container
    /// paths change across app updates and reinstalls, so a stored absolute URL
    /// goes stale.
    static func url(forFilename filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    private static var allCaptures: [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return items.filter { $0.lastPathComponent.hasPrefix(filenamePrefix) }
    }

    /// Total bytes currently used by captured-receipt JPEGs. `batch.json` and
    /// `spend.json` share this directory but aren't captures, so the prefix
    /// filter leaves them out of the total.
    static func totalBytes() -> Int64 {
        allCaptures.reduce(Int64(0)) { $0 + Int64(fileSize($1)) }
    }

    /// Delete one capture by name. A no-op if it's already gone. The caller —
    /// `SpendStore`, today — is the one that knows whether anything still needs
    /// this photo.
    static func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(forFilename: filename))
    }

    /// Delete every captured-receipt JPEG, unconditionally. Returns how many
    /// files were removed and how many bytes that freed, for a confirmation
    /// message.
    @discardableResult
    static func deleteAllPhotos() -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        var count = 0
        var bytes: Int64 = 0
        for url in allCaptures {
            let size = fileSize(url)
            guard (try? fm.removeItem(at: url)) != nil else { continue }
            count += 1
            bytes += Int64(size)
        }
        return (count, bytes)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}
