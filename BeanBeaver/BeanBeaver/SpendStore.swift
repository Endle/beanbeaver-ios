import Foundation
import Observation
import BBReceiptKit

/// One scanned receipt's persisted record: its parsed data, the state of its
/// photo, and whether it's reached an export target yet. This — not the
/// receipt total — is what every spending figure is computed from (via
/// `SpendSummary`), and what `ReceiptsView` lists. See `SpendStore` for the store that owns
/// these.
struct SpendRecord: Identifiable, Codable {
    let id: UUID
    /// Var, not let: `ReceiptEditorView` replaces this wholesale when the user
    /// corrects a misread receipt (`SpendStore.updateResult`). Still the parse
    /// rather than anything hand-assembled — a correction is re-rendered by the
    /// core, not patched here.
    var result: ReceiptResult
    let scannedAt: Date
    /// Bare filename in `ReceiptCaptureStore.directory`, never a URL — container
    /// paths go stale across updates. Nil when the capture write itself failed.
    let captureFilename: String?
    var wallMs: Double?
    /// Kept out of every spending total — returned, business, not mine. Totals-scoped
    /// only; the stored parse and what an export ships are untouched.
    var isExcluded = false

    // MARK: The two explicit states

    /// Set when the *user* clears the photo, so "you cleared this" can be said
    /// plainly and told apart from a file that went missing on its own.
    var photoClearedAt: Date?
    /// Set the first time this receipt reaches any export target, cleared never.
    var exportedAt: Date?
    /// Which targets it has reached, dedup'd — `LedgerDestinationKind.shortTitle`
    /// ("GitHub") and/or "Money Manager". Plural because a receipt can legitimately
    /// go to both, and the row should say which.
    var exportedTargets: [String] = []
}

extension SpendRecord {
    /// Three states, not two, because they read differently to a user and only
    /// one of them is a problem — see `SpendStore.photoState(for:)`.
    enum PhotoState: Equatable { case present, cleared, unavailable }

    var isExported: Bool { exportedAt != nil }

    /// What a row's status dot says. One state per receipt, not one per target:
    /// *which* target it reached is detail-view material (`exportedTargets`),
    /// while the list only ever has to answer "is this filed yet".
    ///
    /// Two states, and `isExcluded` is deliberately not a third. Exclusion is
    /// budget-scoped — see `SpendRecord.isExcluded`, which leaves the stored
    /// parse and everything an export ships untouched — so an excluded receipt
    /// is still in the backlog and still goes out with it. A grey "excluded"
    /// dot would sit on a row that the export bar below is about to file, and
    /// under a chip counting it as unexported. The exclusion is said in words
    /// in the row's subtitle instead, where it can't be mistaken for status.
    enum ExportStatus: Equatable {
        case exported, notExported

        var label: String {
            switch self {
            case .exported: return "Exported"
            case .notExported: return "Not exported"
            }
        }
    }

    var exportStatus: ExportStatus { isExported ? .exported : .notExported }
}

/// Every receipt ever scanned, kept indefinitely until the user removes it —
/// the substrate the budget and the Receipts screen are both views over. Owns
/// the lifetime of each receipt's captured photo: deleting a record deletes its
/// photo, and clearing a photo leaves the record (and every spending figure it
/// contributes to) untouched. This is what let `ReceiptCaptureStore.clearOld`
/// go away — nothing here ages out on its own.
@Observable
@MainActor
final class SpendStore {
    static let shared = SpendStore()

    private(set) var records: [SpendRecord] = []   // newest first

    private static var fileURL: URL {
        ReceiptCaptureStore.directory.appendingPathComponent("spend.json")
    }

    private struct Persisted: Codable {
        let records: [SpendRecord]
    }

    init() {
        load()
    }

    // MARK: Recording

    /// Insert a freshly scanned receipt at the front. Dedup'd on
    /// `result.beanbeaverId` when the core supplied one — the same identity
    /// GitHub files under, so scanning the same photo twice doesn't double-count
    /// in the budget. A nil id (no image hash) records unconditionally.
    func record(result: ReceiptResult, captureFilename: String?, wallMs: Double?) {
        if let id = result.beanbeaverId,
           records.contains(where: { $0.result.beanbeaverId == id }) {
            return
        }
        records.insert(SpendRecord(id: UUID(), result: result, scannedAt: Date(),
                                   captureFilename: captureFilename, wallMs: wallMs),
                       at: 0)
        save()
    }

    // MARK: Mutation

    /// Replace one record's parse with a corrected one (`ReceiptEditorView`).
    ///
    /// The whole `ReceiptResult`, not a patch: an edit goes back through
    /// `reformatReceipt`, so the beancount, the accounts, the tags and the
    /// warnings are all re-derived together and there is no version of this
    /// record where some of them are corrected and the rest are not.
    ///
    /// Every spending figure follows from `records`, so this is also what makes
    /// a corrected price reach the budget — no separate invalidation, because
    /// `SpendSummary` is computed from these rows on each read.
    func updateResult(_ id: UUID, to result: ReceiptResult) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].result = result
        save()
    }

    /// The same update addressed by identity rather than row, for the scan
    /// result screen — it holds a `ReceiptResult` straight from the pipeline and
    /// never learns the `SpendRecord.id` that `record(result:…)` minted for it.
    ///
    /// Matched on the receipt's *previous* `beanbeaverId`, since correcting the
    /// date changes the id the edited copy will carry. A receipt with no id
    /// can't be located this way and is left alone — the same nil-hash case that
    /// makes `record(result:…)` skip its dedup.
    func updateResult(replacing previous: ReceiptResult, with result: ReceiptResult) {
        guard let id = previous.beanbeaverId,
              let index = records.firstIndex(where: { $0.result.beanbeaverId == id })
        else { return }
        records[index].result = result
        save()
    }

    func setExcluded(_ excluded: Bool, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isExcluded = excluded
        save()
    }

    /// Mark every record whose `beanbeaverId` is in `ids` as having reached
    /// `target` (e.g. "GitHub"), stamping `exportedAt` the first time. Called
    /// from the one hook in `LedgerExporter.export`, so every ledger export call
    /// site benefits without repeating itself.
    func markExported(ids: [String], target: String) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        var changed = false
        for index in records.indices {
            guard let id = records[index].result.beanbeaverId, idSet.contains(id) else { continue }
            if records[index].exportedAt == nil { records[index].exportedAt = Date() }
            if !records[index].exportedTargets.contains(target) {
                records[index].exportedTargets.append(target)
            }
            changed = true
        }
        if changed { save() }
    }

    /// Same idea as `markExported`, keyed by the results a Money Manager
    /// presentation site already has on hand rather than ids a caller has to
    /// extract first. Marked at presentation, not confirmed delivery — the
    /// share sheet may be cancelled — which is why the row says "Shared", never
    /// "Filed".
    func markShared(results: [ReceiptResult], target: String = "Money Manager") {
        markExported(ids: results.compactMap(\.beanbeaverId), target: target)
    }

    /// Drop the row **and its photo**. The store owns photo lifetime now, which
    /// is what lets the old sweep go away.
    func remove(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let filename = records[index].captureFilename {
            ReceiptCaptureStore.delete(filename: filename)
        }
        records.remove(at: index)
        save()
    }

    /// Drop a chosen set of rows and their photos in one pass — the middle
    /// ground between `remove(_:)` and `removeAll()`, so tidying up a handful of
    /// receipts isn't one swipe at a time. Saves once, not once per row.
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = records.count
        for record in records where ids.contains(record.id) {
            if let filename = record.captureFilename {
                ReceiptCaptureStore.delete(filename: filename)
            }
        }
        records.removeAll { ids.contains($0.id) }
        if records.count != before { save() }
    }

    /// Every row and photo, gone.
    func removeAll() {
        for record in records {
            if let filename = record.captureFilename {
                ReceiptCaptureStore.delete(filename: filename)
            }
        }
        records.removeAll()
        save()
    }

    /// Drop rows whose capture matches `filenames` — used when a batch draft is
    /// discarded (an explicit "I don't want this receipt") before it's ever
    /// exported, so a discarded import doesn't quietly stay in someone's budget.
    /// Doesn't touch the photo file itself: the caller (`ReceiptBatch`) owns
    /// that deletion.
    func removeRecords(withCaptureFilenames filenames: Set<String>) {
        guard !filenames.isEmpty else { return }
        let before = records.count
        records.removeAll { record in
            record.captureFilename.map(filenames.contains) ?? false
        }
        if records.count != before { save() }
    }

    /// Delete one receipt's photo, keeping the row — the figures stay, the JPEG
    /// doesn't.
    func clearPhoto(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let filename = records[index].captureFilename else { return }
        ReceiptCaptureStore.delete(filename: filename)
        records[index].photoClearedAt = Date()
        save()
    }

    /// Delete every photo, keeping every row — the honest successor to the old
    /// `Clear Old Receipts`: same relief, no heuristic, and every spending figure
    /// stays intact.
    func clearAllPhotos() {
        for index in records.indices where records[index].photoClearedAt == nil {
            if let filename = records[index].captureFilename {
                ReceiptCaptureStore.delete(filename: filename)
            }
            records[index].photoClearedAt = Date()
        }
        save()
    }

    // MARK: Photo state

    /// `.present` when the file is actually on disk, `.cleared` when the user
    /// cleared it, `.unavailable` when it's gone with no clear stamp — a failed
    /// capture write, an iOS storage-pressure purge, or a restore that didn't
    /// bring the backup-excluded directory. Kept as three states rather than
    /// inferred from file-absence alone: collapsing `.cleared` and
    /// `.unavailable` would make the app look broken every time the user tidied
    /// up, and `.unavailable` is worth surfacing since a re-export of that row
    /// can attach no `document:` link.
    func photoState(for record: SpendRecord) -> SpendRecord.PhotoState {
        if record.photoClearedAt != nil { return .cleared }
        guard let filename = record.captureFilename,
              FileManager.default.fileExists(atPath: ReceiptCaptureStore.url(forFilename: filename).path)
        else { return .unavailable }
        return .present
    }

    func photoURL(for record: SpendRecord) -> URL? {
        guard photoState(for: record) == .present, let filename = record.captureFilename else { return nil }
        return ReceiptCaptureStore.url(forFilename: filename)
    }

    /// Records that haven't reached any export target yet — the fast path for
    /// "back up everything I haven't yet".
    var unexportedRecords: [SpendRecord] { records.filter { !$0.isExported } }

    var exportedRecords: [SpendRecord] { records.filter(\.isExported) }

    /// When anything last reached a target, or nil if nothing ever has. What the
    /// home card's status line dates itself by — "9 filed · last export Mar 11"
    /// answers "am I up to date" in a way a bare count can't.
    var lastExportedAt: Date? { records.compactMap(\.exportedAt).max() }

    /// Every target anything has reached, in first-seen order — "GitHub",
    /// "Money Manager", or both. Read rather than assumed: the app really can
    /// file to more than one place, so the status line names what actually
    /// happened instead of whatever target happens to be selected now.
    var reachedTargets: [String] {
        var seen = Set<String>()
        var targets: [String] = []
        for record in records {
            for target in record.exportedTargets where !seen.contains(target) {
                seen.insert(target)
                targets.append(target)
            }
        }
        return targets
    }

    func totalPhotoBytes() -> Int64 {
        records.reduce(Int64(0)) { total, record in
            guard photoState(for: record) == .present, let filename = record.captureFilename else { return total }
            let url = ReceiptCaptureStore.url(forFilename: filename)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    // MARK: Storage

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        // Unlike `ReceiptBatch.load()`, a record whose photo is missing is kept
        // rather than dropped: there a photo-less draft is unusable (it still
        // has to be parsed); here the parse is already done and the numbers are
        // the asset. `photoState(for:)` reports `.unavailable` for it.
        records = stored.records
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Persisted(records: records)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

#if DEBUG
/// Log an already-interpolated line without letting its text be read as a
/// format string. Receipt text routinely contains `%` ("2% FINE-FILT"), and
/// `NSLog("\(text)")` hands that straight to the formatter — which turned that
/// item into `2 0.000000INE-FILT` in a dump while the app rendered it correctly
/// on screen. Every dump line that can carry OCR'd text goes through here.
func dumpLine(_ message: String) {
    NSLog("%@", message)
}

extension SpendStore {
    func logState(_ label: String) {
        dumpLine("[Spend] \(label): records=\(records.count) unexported=\(unexportedRecords.count)")
        for record in records {
            dumpLine("[Spend]   \(record.result.merchant)|\(record.result.total)"
                + "|id=\(record.result.beanbeaverId ?? "nil")"
                + "|exportedAt=\(record.exportedAt.map(\.description) ?? "nil")"
                + "|targets=\(record.exportedTargets.joined(separator: ","))"
                + "|excluded=\(record.isExcluded)"
                + "|photoState=\(photoState(for: record))")
        }
    }
}
#endif
