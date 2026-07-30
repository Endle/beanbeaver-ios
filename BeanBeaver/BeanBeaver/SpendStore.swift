import Foundation
import Observation
import BBReceiptKit

/// One scanned receipt's persisted record: its parsed data, the state of its
/// photo, and whether it's reached an export target yet. This — not the
/// receipt total — is what a monthly budget is computed from (`Budget.swift`),
/// and what `ReceiptsView` lists. See `SpendStore` for the store that owns
/// these.
struct SpendRecord: Identifiable, Codable {
    let id: UUID
    let result: ReceiptResult
    let scannedAt: Date
    /// Bare filename in `ReceiptCaptureStore.directory`, never a URL — container
    /// paths go stale across updates. Nil when the capture write itself failed.
    let captureFilename: String?
    var wallMs: Double?
    /// Kept out of every budget total — returned, business, not mine. Budget-scoped
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
}

/// Every receipt ever scanned, kept indefinitely until the user removes it —
/// the substrate the budget and the Receipts screen are both views over. Owns
/// the lifetime of each receipt's captured photo: deleting a record deletes its
/// photo, and clearing a photo leaves the record (and every budget figure it
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
    /// `Clear Old Receipts`: same relief, no heuristic, and every budget figure
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
extension SpendStore {
    func logState(_ label: String) {
        NSLog("[Spend] \(label): records=\(records.count) unexported=\(unexportedRecords.count)")
        for record in records {
            NSLog("[Spend]   \(record.result.merchant)|\(record.result.total)"
                + "|id=\(record.result.beanbeaverId ?? "nil")"
                + "|exportedAt=\(record.exportedAt.map(\.description) ?? "nil")"
                + "|targets=\(record.exportedTargets.joined(separator: ","))"
                + "|excluded=\(record.isExcluded)"
                + "|photoState=\(photoState(for: record))")
        }
    }
}
#endif
