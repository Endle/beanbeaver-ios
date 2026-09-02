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

/// Everything derived from `SpendStore.records`, held until the records change.
///
/// # Why this exists
///
/// Every `SpendSummary` entry point projects the whole corpus into `[SpendInput]`
/// and crosses the FFI, and every caller is a SwiftUI **computed property** —
/// which is re-evaluated on each access, not once per body pass. Measured on a
/// Release build in the simulator (`SpendPerf`, 200 receipts, 8 months, the
/// bundled 7-item sample):
///
/// | Screen | One body pass, uncached |
/// |---|---|
/// | `HomeView` | 3.3 ms |
/// | `SpendingView` | 34.2 ms |
/// | `ReceiptsView` | 132.3 ms |
///
/// At 800 receipts those become 14.1 / 180.3 / 542.1 ms. A 60 Hz frame is
/// 16.7 ms. The work is identical every time — the corpus has not changed
/// between two reads inside one body — so it is all avoidable.
///
/// # Why a separate object
///
/// `@ObservationIgnored` in `SpendStore`: reading a memo *writes* to it, and an
/// observed write during a view update is how you get a re-render loop. Nothing
/// here is state a view should ever depend on — the dependency is `records`,
/// which stays observed.
///
/// # Invalidation
///
/// One `revision` counter, bumped by `SpendStore.didChange()`, which every
/// mutator already funnels through. `facts` and `trend` are additionally
/// clock-relative, so they also carry the calendar day they were computed for —
/// an app left open past midnight recomputes them rather than reporting
/// yesterday's window.
@MainActor
private final class SpendCache {
    private var revision = -1
    private var day: SpendDate?

    var inputs: [SpendInput] = []
    var byId: [String: SpendRecord] = [:]
    var monthIdByRecordId: [UUID: String] = [:]
    var recordsByMonth: [String: [SpendRecord]] = [:]
    var monthIds: [String]?
    var defaultMonthId: String?
    var months: [String: SpendSummary.Month] = [:]
    var facts: [String: SpendMonthFacts] = [:]
    var trends: [String: SpendTrend] = [:]
    var receiptGroups: [String: [SpendSummary.ReceiptGroup]] = [:]
    var itemEntries: [String: [SpendSummary.ItemEntry]] = [:]

    /// Drop everything derived from a corpus that is no longer current, or from
    /// a day that has ended. Returns having left the cache valid for
    /// `(revision, today)`.
    func validate(revision: Int, today: SpendDate) {
        if revision != self.revision {
            self.revision = revision
            inputs = []
            byId = [:]
            monthIdByRecordId = [:]
            recordsByMonth = [:]
            monthIds = nil
            defaultMonthId = nil
            months = [:]
            receiptGroups = [:]
            itemEntries = [:]
            facts = [:]
            trends = [:]
            day = today
            return
        }
        if today != day {
            day = today
            // `month` is pure over records and takes no date; only these two
            // read the clock.
            facts = [:]
            trends = [:]
        }
    }
}

extension SpendDate: @retroactive Equatable {
    public static func == (lhs: SpendDate, rhs: SpendDate) -> Bool {
        lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
    }
}

/// Every receipt ever scanned, kept indefinitely until the user removes it —
/// the substrate the budget and the Receipts screen are both views over. Owns
/// the lifetime of each receipt's captured photo: deleting a record deletes its
/// photo, and clearing a photo leaves the record (and every spending figure it
/// contributes to) untouched. This is what let `ReceiptCaptureStore.clearOld`
/// go away — nothing here ages out on its own.
///
/// It is also where every spending figure is *read* from — see "Derived
/// figures" below and `SpendCache` for why the screens must not call
/// `SpendSummary` over the corpus themselves.
@Observable
@MainActor
final class SpendStore {
    static let shared = SpendStore()

    private(set) var records: [SpendRecord] = []   // newest first

    /// Bumped by `didChange()`. The whole invalidation story for `cache`.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let cache = SpendCache()

    private static var fileURL: URL {
        ReceiptCaptureStore.directory.appendingPathComponent("spend.json")
    }

    private struct Persisted: Codable {
        let records: [SpendRecord]
    }

    /// False for a store that must never reach disk — `SpendPerf`'s synthetic
    /// corpus, and any preview that wants a populated store. Every mutator
    /// still works; only `didChange()` is a no-op.
    private let persists: Bool

    init() {
        persists = true
        load()
    }

    /// A store over `records` that never reads or writes `spend.json`.
    init(ephemeralRecords records: [SpendRecord]) {
        persists = false
        self.records = records
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
        didChange()
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
        didChange()
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
        didChange()
    }

    func setExcluded(_ excluded: Bool, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isExcluded = excluded
        didChange()
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
        if changed { didChange() }
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
        didChange()
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
        if records.count != before { didChange() }
    }

    /// Every row and photo, gone.
    func removeAll() {
        for record in records {
            if let filename = record.captureFilename {
                ReceiptCaptureStore.delete(filename: filename)
            }
        }
        records.removeAll()
        didChange()
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
        if records.count != before { didChange() }
    }

    /// Delete one receipt's photo, keeping the row — the figures stay, the JPEG
    /// doesn't.
    func clearPhoto(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let filename = records[index].captureFilename else { return }
        ReceiptCaptureStore.delete(filename: filename)
        records[index].photoClearedAt = Date()
        didChange()
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
        didChange()
    }

    // MARK: Derived figures
    //
    // The screens read spending through these, never through `SpendSummary.…(from:
    // records)` directly — see `SpendCache` for the measurements that made that a
    // rule. Each is the same value `SpendSummary` would return; the only
    // difference is that the projection and the FFI crossing happen once per
    // change to `records` rather than once per property access.
    //
    // `SpendSummary`'s `[SpendRecord]` entry points are still the right call for
    // a *subset* — one month's records, or a single one — where there is nothing
    // corpus-wide to memoize (`CategoryItemsView`, the scan result's impact
    // chip).

    /// The corpus as the shared crate reads it.
    var inputs: [SpendInput] {
        validated()
        if cache.inputs.isEmpty && !records.isEmpty {
            cache.inputs = records.map(\.spendInput)
        }
        return cache.inputs
    }

    /// The re-attachment index for results Rust keys by record id.
    var recordsById: [String: SpendRecord] {
        validated()
        if cache.byId.isEmpty && !records.isEmpty {
            cache.byId = records.byRecordId
        }
        return cache.byId
    }

    /// Every month with at least one record, newest first.
    var monthIds: [String] {
        validated()
        if let cached = cache.monthIds { return cached }
        let value = SpendSummary.monthIds(fromInputs: inputs)
        cache.monthIds = value
        return value
    }

    /// The month a screen opens on — the newest with receipts in it.
    var defaultMonthId: String {
        validated()
        if let cached = cache.defaultMonthId { return cached }
        let value = SpendSummary.defaultMonthId(fromInputs: inputs)
        cache.defaultMonthId = value
        return value
    }

    /// Which month a record belongs to.
    ///
    /// **A dictionary lookup, not an FFI crossing.** `SpendSummary.monthId(for:)`
    /// costs one crossing per call, and the list screens call it inside `filter`
    /// closures — once per record, per chip, per body pass. The whole corpus is
    /// bucketed here in a single pass instead, off the already-cached projection
    /// so no record is re-projected.
    func monthId(for record: SpendRecord) -> String {
        buildMonthIndex()
        return cache.monthIdByRecordId[record.id] ?? SpendSummary.monthId(for: record)
    }

    /// The records in one month, newest first — the store's own order, filtered.
    func records(inMonth id: String) -> [SpendRecord] {
        buildMonthIndex()
        return cache.recordsByMonth[id] ?? []
    }

    private func buildMonthIndex() {
        validated()
        guard cache.monthIdByRecordId.isEmpty, !records.isEmpty else { return }
        let projected = inputs
        var byRecord: [UUID: String] = [:]
        var byMonth: [String: [SpendRecord]] = [:]
        byRecord.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            let month = SpendSummary.monthId(forInput: projected[index])
            byRecord[record.id] = month
            byMonth[month, default: []].append(record)
        }
        cache.monthIdByRecordId = byRecord
        cache.recordsByMonth = byMonth
    }

    func month(_ id: String) -> SpendSummary.Month {
        validated()
        if let cached = cache.months[id] { return cached }
        let value = SpendSummary.month(id, fromInputs: inputs, byId: recordsById)
        cache.months[id] = value
        return value
    }

    func facts(_ id: String) -> SpendMonthFacts {
        validated()
        if let cached = cache.facts[id] { return cached }
        let value = SpendSummary.facts(id, fromInputs: inputs)
        cache.facts[id] = value
        return value
    }

    func trend(_ scope: SpendSummary.Category? = nil) -> SpendTrend {
        validated()
        let key = Self.key(for: scope)
        if let cached = cache.trends[key] { return cached }
        let value = SpendSummary.trend(scope, fromInputs: inputs)
        cache.trends[key] = value
        return value
    }

    func receipts(_ category: SpendSummary.Category) -> [SpendSummary.ReceiptGroup] {
        validated()
        let key = Self.key(for: category)
        if let cached = cache.receiptGroups[key] { return cached }
        let value = SpendSummary.receipts(category, fromInputs: inputs, byId: recordsById)
        cache.receiptGroups[key] = value
        return value
    }

    func items(_ category: SpendSummary.Category) -> [SpendSummary.ItemEntry] {
        validated()
        let key = Self.key(for: category)
        if let cached = cache.itemEntries[key] { return cached }
        let value = SpendSummary.items(category, fromInputs: inputs, byId: recordsById)
        cache.itemEntries[key] = value
        return value
    }

    /// A cache key for a scope. `root:` / `leaf:` prefixed because a root tag and
    /// a leaf label can be the same string and must not collide.
    private static func key(for category: SpendSummary.Category?) -> String {
        switch category {
        case nil: return "all"
        case .root(let id): return "root:\(id)"
        case .leaf(let label): return "leaf:\(label)"
        }
    }

    private func validated() {
        cache.validate(revision: revision, today: Date().spendDate)
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

    /// One mutation happened. Invalidates every derived figure and schedules the
    /// write.
    ///
    /// Every mutator funnels through here rather than calling `persist()`
    /// directly, which is what makes `revision` a complete description of when
    /// `cache` is stale — a mutator that forgot to bump it would serve figures
    /// from before its own change.
    private func didChange() {
        revision &+= 1
        persist()
    }

    /// The encode and the write, off the main actor.
    ///
    /// The encode is the expensive half — the whole corpus, every time, and it
    /// used to run on the main actor between a tap and the next frame. What
    /// crosses to the queue is a snapshot of `records`, which is O(1): an array
    /// of structs is copy-on-write, and nothing mutates it afterwards.
    ///
    /// **Serial, so the last write wins.** Two mutations in quick succession
    /// enqueue two encodes; a concurrent queue could land them out of order and
    /// leave the older corpus on disk.
    private func persist() {
        guard persists else { return }
        let snapshot = Persisted(records: records)
        let url = Self.fileURL
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let ioQueue = DispatchQueue(
        label: "com.beanbeaver.SpendStore.persist", qos: .utility)

    /// Block until every scheduled write has landed.
    ///
    /// Called when the app leaves the foreground (`BeanBeaverApp`). Without it
    /// the move off the main actor would trade a hitch for a durability window:
    /// iOS can suspend the process between the enqueue and the write, and the
    /// mutation the user just made would be gone on next launch. On the
    /// background transition there is time to spend and no frame to miss, so
    /// this is where the old synchronous behaviour belongs.
    func flushPendingWrites() {
        guard persists else { return }
        Self.ioQueue.sync {}
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
