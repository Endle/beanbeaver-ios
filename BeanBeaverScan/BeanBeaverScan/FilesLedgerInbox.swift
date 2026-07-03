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

    func append(_ beancount: String) async throws -> LedgerExportOutcome {
        guard let bookmark else {
            throw LedgerExportError("No ledger file chosen yet. Pick one in Settings › Sync.")
        }
        // Coordinated file IO is blocking; keep it off the main actor.
        let name = try await Task.detached { try Self.appendToBookmark(bookmark, text: beancount) }.value
        // A stale bookmark was refreshed inside the task; re-read the name we stored.
        return .appended(fileName: name)
    }

    /// Resolve the bookmark, append `text` (ensuring a blank-line separator), and
    /// return the file's name. Runs off the main actor.
    private nonisolated static func appendToBookmark(_ bookmark: Data, text: String) throws -> String {
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
                let existing = (try? Data(contentsOf: writeURL)) ?? Data()
                var out = existing
                // Separate transactions with a blank line; beancount is newline-oriented.
                if !out.isEmpty {
                    let nl = Data("\n".utf8)
                    if !out.suffix(2).elementsEqual(Data("\n\n".utf8)) {
                        out.append(out.suffix(1).elementsEqual(nl) ? nl : Data("\n\n".utf8))
                    }
                }
                out.append(Data(text.utf8))
                if !text.hasSuffix("\n") { out.append(Data("\n".utf8)) }
                try out.write(to: writeURL, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
        return url.lastPathComponent
    }
}
