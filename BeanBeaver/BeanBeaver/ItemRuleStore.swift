import BBReceiptKit
import Foundation
import Observation

/// A rule document the user brought in, stored verbatim.
///
/// The TOML text is **copied**, not referenced by a security-scoped bookmark
/// (cf. `FilesLedgerInbox`): rules have to keep working after the source file is
/// moved, renamed, or deleted from Files.
struct ImportedRuleDocument: Codable, Identifiable, Equatable {
    let id: UUID
    /// Filename it was imported from, shown in the list.
    var displayName: String
    var importedAt: Date
    /// The document itself — what gets handed to the core as an override layer.
    var toml: String
}

/// Owns the user's imported rule documents and the `RuleBook` they produce.
///
/// Two responsibilities that are easy to conflate: this is the *only* thing that
/// persists user rules, and it is also what the scan path reads to build
/// `ParseOptions`. Keeping both here is what stops the browser from showing one
/// ruleset while scans use another.
@Observable
@MainActor
final class ItemRuleStore {
    /// The app's one store. Read at scan time (like `LedgerFormatPrefs`) rather
    /// than snapshotted into the pipeline, so an import takes effect on the very
    /// next scan without anything having to re-plumb it.
    static let shared = ItemRuleStore()

    private(set) var documents: [ImportedRuleDocument] = []

    /// The rule corpus currently in force: bundled defaults plus every imported
    /// document, later ones winning. Rebuilt whenever `documents` changes.
    private(set) var book: RuleBook?

    /// Non-nil when the stored documents failed to load — which should be
    /// impossible, since import validates before persisting, but a document
    /// could still be invalidated by a core upgrade that removes a rule id.
    private(set) var loadError: String?

    private let storage: JSONFile<Persisted>
    var storageIssue: String? { storage.issue }
    var canModify: Bool { !storage.loadFailed }

    private struct Persisted: Codable {
        let documents: [ImportedRuleDocument]
    }

    init(fileURL: URL = ReceiptCaptureStore.directory.appendingPathComponent("item_rules.json")) {
        storage = JSONFile(url: fileURL)
        load()
        rebuild()
    }

    /// The overlay handed to every scan. Empty means bundled defaults only.
    var parseOptions: ParseOptions {
        ParseOptions(ruleDocuments: documents.map(\.toml), knownMerchants: [])
    }

    // MARK: - Import

    /// Validate `toml` by building a `RuleBook` from it, then persist.
    ///
    /// Validation is the core's, not ours: malformed TOML, an undeclared tag
    /// path, and a `disables` naming an unknown rule id all come back as
    /// `ScanError`. Swift never parses TOML itself.
    ///
    /// Returns what the document added, for the confirmation message.
    @discardableResult
    func importDocument(named name: String, toml: String) throws -> ImportSummary {
        guard canModify else {
            throw NSError(domain: "BeanBeaver.Storage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: storageIssue ?? "Rule storage is unavailable."])
        }
        let before = book
        let candidate = try RuleBook(
            options: ParseOptions(
                ruleDocuments: documents.map(\.toml) + [toml],
                knownMerchants: []
            )
        )

        let addedRules = candidate.rules().count - (before?.rules().count ?? 0)
        let knownTags = Set((before?.tags() ?? []).map(\.path))
        let addedTags = candidate.tags().filter { !knownTags.contains($0.path) }.count

        documents.append(
            ImportedRuleDocument(
                id: UUID(), displayName: name, importedAt: Date(), toml: toml
            )
        )
        save()
        book = candidate
        loadError = nil
        return ImportSummary(rules: addedRules, tags: addedTags)
    }

    struct ImportSummary {
        let rules: Int
        let tags: Int
    }

    func remove(_ document: ImportedRuleDocument) {
        guard canModify else { return }
        documents.removeAll { $0.id == document.id }
        save()
        rebuild()
    }

    func remove(atOffsets offsets: IndexSet) {
        guard canModify else { return }
        documents.remove(atOffsets: offsets)
        save()
        rebuild()
    }

    // MARK: - Persistence

    private func load() {
        guard let decoded = storage.load() else { return }
        documents = decoded.documents
    }

    private func save() {
        storage.save(Persisted(documents: documents))
    }

    func retryPersistence() {
        if storage.loadFailed {
            load()
            rebuild()
        } else {
            save()
        }
    }

    private func rebuild() {
        do {
            book = try RuleBook(options: parseOptions)
            loadError = nil
        } catch {
            // Fall back to the bundled corpus so the browser still renders and
            // the message explains why the user's rules are not applying.
            book = try? RuleBook(options: ParseOptions(ruleDocuments: [], knownMerchants: []))
            loadError = String(describing: error)
        }
    }
}
