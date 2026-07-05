import Foundation

/// The on-disk home for captured-receipt JPEGs (`ReceiptPipeline.persistCapture`)
/// and the manual cleanup for them. These are kept intentionally — unlike a
/// cache, they're not deleted after each scan — so a user can come back and
/// review the original photo later. Since nothing here auto-expires yet, this
/// is also the thing to point at when explaining where "the receipt photo"
/// lives for the "we don't keep what we don't need" promise.
enum ReceiptCaptureStore {
    static let filenamePrefix = "receipt_capture_"

    private static var directory: URL { FileManager.default.temporaryDirectory }

    /// Where `ReceiptPipeline` should write a freshly captured JPEG.
    static func newCaptureURL() -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        return directory.appendingPathComponent("\(filenamePrefix)\(stamp).jpg")
    }

    private static var allCaptures: [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return items.filter { $0.lastPathComponent.hasPrefix(filenamePrefix) }
    }

    /// Total bytes currently used by captured-receipt JPEGs.
    static func totalBytes() -> Int64 {
        allCaptures.reduce(Int64(0)) { $0 + Int64(fileSize($1)) }
    }

    /// Delete every captured-receipt JPEG except `keeping` (the one currently
    /// on screen, if any). Returns how many files were removed and how many
    /// bytes that freed, for the confirmation message.
    @discardableResult
    static func clearOld(keeping: URL?) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        var count = 0
        var bytes: Int64 = 0
        for url in allCaptures where url != keeping {
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
