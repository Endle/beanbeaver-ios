import Foundation
import Observation

/// Appends transactions to a single user-chosen `.bean` file reached through the
/// system Files layer. Because every cloud provider (iCloud Drive, Dropbox, Box,
/// Google Drive, OneDrive, Working Copy…) vends its folders through the same
/// document-picker / file-provider API, this one backend covers all of them: the
/// user picks a destination once and we persist a security-scoped bookmark.
///
/// The intended workflow is a dedicated inbox file the user `include`s from their
/// main ledger, so we only ever append — we never rewrite their real journal.
@Observable
@MainActor
final class FilesLedgerInbox: LedgerDestination {
    let kind: LedgerDestinationKind = .filesInbox

    private nonisolated static let bookmarkKey = "ledgerInboxBookmark"
    private nonisolated static let nameKey = "ledgerInboxName"

    /// Display name of the chosen file (e.g. `receipts-inbox.bean`), or nil.
    private(set) var fileName: String?

    init() {
        fileName = UserDefaults.standard.string(forKey: Self.nameKey)
    }

    var isConfigured: Bool { bookmark != nil }

    private var bookmark: Data? {
        UserDefaults.standard.data(forKey: Self.bookmarkKey)
    }

    /// Record a file the user picked in the document picker. The URL is already
    /// security-scoped by the picker; we snapshot a bookmark for later launches.
    func setDestination(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.nameKey)
        fileName = url.lastPathComponent
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        fileName = nil
    }

    func append(_ entries: [LedgerEntry]) async throws -> LedgerExportOutcome {
        guard let bookmark else {
            throw LedgerExportError("No ledger file chosen yet. Pick one in Settings › Sync.")
        }
        // Coordinated file IO is blocking; keep it off the main actor. The whole
        // batch is one read-modify-write — the file is rewritten wholesale, so
        // appending per entry would re-read and re-write it N times.
        let texts = entries.map(\.beancount)
        let documents = entries.flatMap { entry -> [ReceiptDocument] in
            guard let document = entry.document else { return [] }
            // The `.json` details sidecar rides next to the image, sharing its
            // content-addressed relpath (…-<sha8>.json) — absent when the option
            // is off or there's no image to anchor it to.
            guard let json = entry.json else { return [document] }
            let relpath = (document.relpath as NSString).deletingPathExtension + ".json"
            return [document, ReceiptDocument(data: json, relpath: relpath)]
        }
        let name = try await Task.detached {
            try Self.appendToBookmark(bookmark, texts: texts, documents: documents)
        }.value
        // A stale bookmark was refreshed inside the task; re-read the name we stored.
        return .appended(fileName: name, count: entries.count)
    }

    /// Resolve the bookmark, append every text in `texts` (ensuring a blank-line
    /// separator between them), best-effort store `documents` beside the ledger
    /// file, and return the file's name. Runs off the main actor.
    private nonisolated static func appendToBookmark(
        _ bookmark: Data, texts: [String], documents: [ReceiptDocument]
    ) throws -> String {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else {
            throw LedgerExportError("Couldn't open the ledger file — its permission may have been revoked. Re-pick it in Settings.")
        }
        defer { url.stopAccessingSecurityScopedResource() }

        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { writeURL in
            do {
                var out = (try? Data(contentsOf: writeURL)) ?? Data()
                for text in texts {
                    appendTransaction(text, to: &out)
                }
                try out.write(to: writeURL, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }

        for document in documents {
            storeSidecar(document, besideLedgerFile: url)
        }
        return url.lastPathComponent
    }

    /// Append one transaction to `out`, separated from whatever precedes it by a
    /// blank line — beancount is newline-oriented.
    private nonisolated static func appendTransaction(_ text: String, to out: inout Data) {
        if !out.isEmpty {
            let nl = Data("\n".utf8)
            if !out.suffix(2).elementsEqual(Data("\n\n".utf8)) {
                out.append(out.suffix(1).elementsEqual(nl) ? nl : Data("\n\n".utf8))
            }
        }
        out.append(Data(text.utf8))
        if !text.hasSuffix("\n") { out.append(Data("\n".utf8)) }
    }

    /// Write a receipt sidecar (the image, or the `.json` details file) to
    /// `<ledger-file-dir>/<relpath>` (i.e. a `beanbeaver/` subfolder next to the
    /// inbox `.bean`), so the transaction's `document:` link resolves when the
    /// user's `option "documents"` root points at that directory.
    ///
    /// Best-effort: the document picker grants a security scope to the *file*,
    /// not its parent, so creating a sibling folder may be denied by the sandbox.
    /// We log and continue rather than fail the (already-written) transaction.
    /// The robust fix is to let the user pick the containing *folder* instead of
    /// a single file — a future settings change.
    private nonisolated static func storeSidecar(_ document: ReceiptDocument, besideLedgerFile ledger: URL) {
        let dir = ledger.deletingLastPathComponent()
        let dest = dir.appendingPathComponent(document.relpath)
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: dest, options: [], error: &coordError) { writeURL in
            do {
                try FileManager.default.createDirectory(
                    at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Idempotent: same content hash -> same filename; skip if present.
                if !FileManager.default.fileExists(atPath: writeURL.path) {
                    try document.data.write(to: writeURL, options: .atomic)
                }
            } catch {
                NSLog("[FilesLedgerInbox] sidecar not stored (\(document.relpath)): \(error.localizedDescription)")
            }
        }
        if let coordError {
            NSLog("[FilesLedgerInbox] sidecar coordination failed: \(coordError.localizedDescription)")
        }
    }
}
