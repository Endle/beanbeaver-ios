import Foundation
import Observation
import CryptoKit
import BBReceiptKit
#if DEBUG
import UIKit
#endif

/// One imported photo on its way to becoming a ledger transaction.
///
/// The photo is the durable thing here and the parse is a cache of it: the
/// result is stored so reopening the page doesn't re-run OCR over the whole
/// pile, but it's always re-derivable from the JPEG. That's what lets a draft
/// be retried, and what makes removing and re-adding a photo a re-parse.
struct ReceiptDraft: Identifiable, Codable {
    enum State: Codable {
        case queued
        case scanning
        case parsed(ReceiptResult)
        case failed(String)
        /// Persisted as `.scanning` but seen at load: the app was killed while
        /// this one was being parsed. Parsed again like `.queued`, but named
        /// separately so the row can say what happened.
        case interrupted

        /// `.failed` is deliberately absent: a scan is deterministic in the
        /// bytes, the models, and the settings, so re-running a failure just
        /// spends 2.4s arriving at the same message. Failures get a per-row
        /// Retry instead, for when the user has reason to think it'll differ.
        var needsParsing: Bool {
            switch self {
            case .queued, .interrupted: return true
            case .scanning, .parsed, .failed: return false
            }
        }

        var result: ReceiptResult? {
            if case .parsed(let result) = self { return result }
            return nil
        }
    }

    let id: UUID
    /// Bare filename in `ReceiptCaptureStore.directory`, never a URL: the app
    /// container's path changes across updates and reinstalls, so a stored
    /// absolute URL goes stale.
    let captureFilename: String
    /// SHA-256 of the JPEG, used to reject a photo already in this batch —
    /// cheaper than `beanbeaverId`, which only exists after a scan has run.
    let contentHash: String
    var state: State
    /// Swift-observed scan time, kept for the `.json` sidecar's timings.
    var wallMs: Double?
    let addedAt: Date
    /// Stable app identity; absent in older batch archives.
    var recordID: UUID?
}

// MARK: - Batch

/// The pending photo-library import: a queue of receipts to parse, review, and
/// export in one go. Survives relaunch through its JSON archive, so the
/// interesting states are the ones that outlive a process.
///
/// Separate from `ReceiptPipeline`, which drives the single camera scan — they
/// share the OCR session and `ReceiptCaptureStore`, but nothing else. A photo
/// is deleted here only when its own draft is explicitly removed or discarded
/// — never by leaving the batch (`removeParsed`) or by any age-based sweep;
/// once a draft parses, its `SpendRecord` (`SpendStore`) owns the photo.
@Observable
@MainActor
final class ReceiptBatch {
    private(set) var drafts: [ReceiptDraft] = []
    private(set) var isParsing = false

    /// When the oldest receipt still here was added; nil when empty.
    ///
    /// Derived rather than stored, because a stored stamp outlives its own
    /// batch: exporting drains what parsed but leaves failures behind, so a stamp
    /// pinned to the original import would go on dating a pile that is by then
    /// mostly new photos. Taking it from the drafts keeps it true by
    /// construction.
    var createdAt: Date? { drafts.map(\.addedAt).min() }

    /// Default credit-card account for the placeholder posting, mirroring
    /// `ReceiptPipeline`.
    var creditCardAccount = "Liabilities:CreditCard"

    private var parseTask: Task<Void, Never>?

    private let storage: JSONFile<Persisted>
    private let store: SpendStore
    private let scanner: any ReceiptScanning
    private let captureDirectory: URL
    var storageIssue: String? { storage.issue }
    var canModify: Bool { !storage.loadFailed && store.canModify }

    private struct Persisted: Codable {
        let drafts: [ReceiptDraft]
    }

    init(directory: URL = ReceiptCaptureStore.directory, store: SpendStore? = nil,
         scanner: any ReceiptScanning = ReceiptScanService.shared) {
        storage = JSONFile(url: directory.appendingPathComponent("batch.json"))
        captureDirectory = directory
        self.store = store ?? .shared
        self.scanner = scanner
        load()
    }

    private func captureURL(_ filename: String) -> URL {
        captureDirectory.appendingPathComponent(filename)
    }

    // MARK: Derived

    var isEmpty: Bool { drafts.isEmpty }

    /// Drafts still waiting on OCR — what entering the page resumes. Excludes
    /// the one being read right now, since this is the loop's "is there work
    /// left" test; for a count to show someone, use `remainingParseCount`.
    var pendingParseCount: Int { drafts.filter(\.state.needsParsing).count }

    /// Receipts not done yet: the queue plus whatever is being read right now.
    /// This is what a person counting unfinished rows on screen would say.
    var remainingParseCount: Int {
        drafts.filter { $0.state.needsParsing || isScanning($0.state) }.count
    }

    var parsedCount: Int { drafts.filter { $0.state.result != nil }.count }

    var failedCount: Int {
        drafts.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    /// Parsed receipts the user probably wants to look at before exporting.
    var needsAttentionCount: Int {
        drafts.filter { $0.state.result?.needsAttention == true }.count
    }

    /// Every parsed receipt as a ledger entry, oldest first. The photo is read
    /// back off disk here so its `document:` link resolves on the far side.
    var exportableEntries: [LedgerEntry] {
        drafts.compactMap { draft in
            guard let result = draft.state.result else { return nil }
            return LedgerEntry.make(from: result,
                                    imageURL: captureURL(draft.captureFilename),
                                    wallMs: draft.wallMs)
        }
    }

    /// Every parsed receipt's result, oldest first — the raw parses a Money
    /// Manager export turns into spreadsheet rows. Unlike ``exportableEntries`` this
    /// needs no ledger entry or photo, and exporting it doesn't drain the batch.
    var parsedResults: [ReceiptResult] {
        drafts.compactMap { $0.state.result }
    }

    func url(for draft: ReceiptDraft) -> URL {
        captureURL(draft.captureFilename)
    }

    // MARK: Mutation

    enum AddOutcome {
        case added
        /// Already in this batch, by content hash.
        case duplicate
        case failed
    }

    /// Take one photo into the batch. Called per photo rather than per
    /// selection so only one image is ever held in memory, however many the
    /// user picked.
    @discardableResult
    func add(_ imageData: Data) -> AddOutcome {
        guard canModify else { return .failed }
        let hash = Self.contentHash(imageData)
        guard !drafts.contains(where: { $0.contentHash == hash }) else { return .duplicate }
        let url = captureURL("\(ReceiptCaptureStore.filenamePrefix)\(UUID().uuidString).jpg")
        do {
            try imageData.write(to: url, options: .atomic)
        } catch {
            return .failed
        }
        drafts.append(ReceiptDraft(id: UUID(), captureFilename: url.lastPathComponent,
                                   contentHash: hash, state: .queued, wallMs: nil,
                                   addedAt: Date()))
        save()
        return .added
    }

    /// Drop a draft, photo and all — an explicit "I don't want this receipt".
    /// Also drops the matching `SpendRecord`, if this draft had already parsed
    /// and recorded one, so a discarded import doesn't quietly stay in someone's
    /// budget.
    func remove(_ id: UUID) {
        guard canModify else { return }
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let draft = drafts.remove(at: index)
        store.removeRecords(withCaptureFilenames: [draft.captureFilename])
        deleteCapture(draft)
        save()
    }

    /// Throw the whole batch away — the only bulk exit other than exporting, and
    /// the one that makes a batch of receipts that will never parse endable.
    /// Rejects any in-flight completion after removing its draft. Also drops any `SpendRecord`s the discarded drafts had
    /// already parsed and recorded, same reasoning as `remove(_:)`.
    func discardAll() {
        guard canModify else { return }
        stopParsing()
        store.removeRecords(withCaptureFilenames: Set(drafts.map(\.captureFilename)))
        drafts.forEach(deleteCapture)
        drafts = []
        save()
    }

    /// Drop everything that parsed — what a successful export drains.
    ///
    /// Photos deliberately stay: each parsed receipt already recorded a
    /// `SpendRecord` when it finished parsing (see `parseLoop`), and that record
    /// now owns the photo's lifetime — not a future sweep. Leaving the batch
    /// just clears the review queue; the receipt itself lives on in
    /// `SpendStore`/`ReceiptsView`.
    func removeParsed() {
        guard canModify else { return }
        drafts.removeAll { $0.state.result != nil }
        save()
    }

    private func deleteCapture(_ draft: ReceiptDraft) {
        try? FileManager.default.removeItem(
            at: captureURL(draft.captureFilename))
    }

    func retry(_ id: UUID) {
        guard canModify else { return }
        setState(.queued, for: id)
        startParsing()
    }

    /// Replace one parsed draft's result with a corrected one
    /// (`ReceiptEditorView`).
    ///
    /// **Two places hold this parse, and both have to move.** A draft records
    /// its `SpendRecord` the moment it parses (see `parseLoop`), so correcting
    /// only the draft would leave the budget — and the Receipts list, and any
    /// later export — reading the misparse the user just fixed. The record is
    /// found by its stable app UUID, even when the edit changes its export ID.
    ///
    /// Only a `.parsed` draft can be corrected: there is nothing to re-render
    /// for one that is still queued, scanning, or failed.
    func updateResult(_ id: UUID, to result: ReceiptResult) {
        guard canModify else { return }
        guard let index = drafts.firstIndex(where: { $0.id == id }),
              drafts[index].state.result != nil else { return }
        drafts[index].state = .parsed(result)
        save()
        if let recordID = drafts[index].recordID { store.updateResult(recordID, to: result) }
    }

    // MARK: Parsing

    /// Parse whatever is queued or interrupted, one at a time. Idempotent, so
    /// the page can just call it on appear: these are receipts the user already
    /// asked to have parsed, so resuming needs no ceremony.
    ///
    /// Serial on purpose — OCR already saturates the CPU, a second session
    /// would load the models twice, and a pile parsed back to back throttles
    /// thermally as it is.
    func startParsing() {
        guard canModify else { return }
        guard parseTask == nil, pendingParseCount > 0 else { return }
        isParsing = true
        parseTask = Task { [weak self] in
            await self?.parseLoop()
        }
    }

    /// Stop after the scan in flight. That scan's result is kept — it's already
    /// paid for — and anything not yet started goes back to interrupted.
    ///
    /// `parseTask` is deliberately left in place for the loop's own `defer` to
    /// clear: nilling it here would let a fast Resume start a second loop while
    /// the current scan is still running, and two concurrent `scan` calls share
    /// one `OcrSession`. Until the loop actually exits, `isParsing` stays true,
    /// which is honest — it is still parsing.
    func stopParsing() {
        parseTask?.cancel()
        for index in drafts.indices where isScanning(drafts[index].state) {
            drafts[index].state = .interrupted
        }
        save()
    }

    private func parseLoop() async {
        defer {
            parseTask = nil
            isParsing = false
        }
        while !Task.isCancelled,
              let draft = drafts.first(where: \.state.needsParsing) {
            setState(.scanning, for: draft.id)
            let url = captureURL(draft.captureFilename)
            guard let data = try? Data(contentsOf: url) else {
                setState(.failed("This receipt's photo is no longer on this device."), for: draft.id)
                continue
            }
            let account = creditCardAccount
            let currency = LedgerFormatPrefs.currency
            let taxAccount = LedgerFormatPrefs.taxAccount
            let opts = ItemRuleStore.shared.parseOptions
            do {
                let started = Date()
                let result = try await scanner.scan(ReceiptScanRequest(
                    imageData: data, creditCardAccount: account, currency: currency,
                    taxAccount: taxAccount, options: opts))
                // Stop keeps the current result, but removal/discard invalidates it.
                // Never record a result after its draft (and photo) was deleted.
                guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { continue }
                let wallMs = Date().timeIntervalSince(started) * 1000
                drafts[index].recordID = store.record(result: result,
                    captureFilename: draft.captureFilename, wallMs: wallMs)
                setState(.parsed(result), for: draft.id, wallMs: wallMs)
                DebugInfoStore.recordSuccess(result: result, wallMs: wallMs)
            } catch {
                guard drafts.contains(where: { $0.id == draft.id }) else { continue }
                setState(.failed(String(describing: error)), for: draft.id)
                DebugInfoStore.recordFailure(error)
            }
        }
    }

    private func isScanning(_ state: ReceiptDraft.State) -> Bool {
        if case .scanning = state { return true }
        return false
    }

    private func setState(_ state: ReceiptDraft.State, for id: UUID, wallMs: Double? = nil) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].state = state
        if let wallMs { drafts[index].wallMs = wallMs }
        save()
    }

    // MARK: Storage

    private static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func load() {
        guard let stored = storage.load() else { return }
        drafts = stored.drafts.compactMap { draft in
            guard FileManager.default.fileExists(atPath: captureURL(draft.captureFilename).path)
            else { return nil }
            var draft = draft
            if isScanning(draft.state) { draft.state = .interrupted }
            // Upgrade old archives using photo identity first. Export IDs can
            // change after a date correction, and can legitimately be absent.
            if draft.recordID == nil {
                draft.recordID = store.records.first(where: {
                    $0.captureFilename == draft.captureFilename
                })?.id
                if draft.recordID == nil, let exportedID = draft.state.result?.beanbeaverId {
                    draft.recordID = store.records.first(where: {
                        $0.result.beanbeaverId == exportedID
                    })?.id
                }
            }
            return draft
        }
    }

    func retryPersistence() {
        if storage.loadFailed { load() } else { save() }
    }

    private func save() {
        // Persist an empty snapshot as well: deleting the file used to swallow
        // deletion failures, allowing discarded drafts to return on restart.
        storage.save(Persisted(drafts: drafts))
    }

}

#if DEBUG
/// Headless scaffolding for the batch flow. The simulator has no camera and the
/// photo picker is out-of-process, so `-seedPhotoBatch <n>` is the only way to
/// drive an import without hands — the same trick `-autoRunSample` plays for a
/// single scan. Pair it with `-dumpBatch` on a second launch to prove a parsed
/// batch survives relaunch.
extension ReceiptBatch {
    /// Seed from the bundled sample, each copy redrawn a pixel narrower than the
    /// last so it's genuinely different bytes and lands as its own draft —
    /// identical copies would (correctly) be rejected by the content-hash dedup.
    /// Nudging JPEG quality instead isn't enough: neighbouring quality values
    /// encode to byte-identical output.
    func seedFromBundledSample(count: Int) async {
        guard let url = Bundle.main.url(forResource: "costco_20260301_redact", withExtension: "jpg"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            NSLog("[PhotoBatch] bundled sample not found")
            return
        }
        for i in 0..<count {
            let size = CGSize(width: image.size.width - CGFloat(i), height: image.size.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let variant = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let encoded = variant.jpegData(compressionQuality: 0.9) else { continue }
            NSLog("[PhotoBatch] add #\(i) -> \(add(encoded))")
        }
        await parseLoop()
        logState("after seed+parse")
    }

    func logState(_ label: String) {
        NSLog("[PhotoBatch] \(label): drafts=\(drafts.count) parsed=\(parsedCount) "
            + "failed=\(failedCount) pending=\(pendingParseCount) "
            + "needsAttention=\(needsAttentionCount) createdAt=\(createdAt.map(\.description) ?? "nil")")
        for draft in drafts {
            let state: String
            switch draft.state {
            case .queued: state = "queued"
            case .scanning: state = "scanning"
            case .interrupted: state = "interrupted"
            case .failed(let message): state = "failed(\(message.prefix(40)))"
            case .parsed(let result):
                state = "parsed(\(result.merchant)|\(result.total)|items=\(result.items.count)"
                    + "|attn=\(result.needsAttention)|bcLines=\(result.beancount.split(separator: "\n").count)"
                    + "|id=\(result.beanbeaverId ?? "nil"))"
            }
            NSLog("[PhotoBatch]   \(draft.contentHash.prefix(8)) \(state)")
        }
    }
}
#endif
