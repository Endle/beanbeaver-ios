import Foundation
import Observation
import CryptoKit
import BBReceiptKit
#if DEBUG
import UIKit
#endif

// MARK: - Persistence for the scan types

// UniFFI emits plain structs, so the generated scan types aren't `Codable` and
// synthesis can't reach them from here (it only works in the declaring file).
// These conformances are written out by hand so a parsed batch can be stored
// and come back whole — including `beancount`, `beanbeaverId` and
// `documentRelpath`, which `ReceiptExportJSON` drops and which a later sync
// still needs.
//
// `@retroactive` because these types belong to BBReceiptKit: if the generated
// bindings ever grow their own `Codable`, this collides — loudly, at build
// time, which is the point of saying so here. The alternative, a parallel set
// of mirror structs plus two mappings, is more code to drift out of sync with
// the core for no benefit the compiler can't already police.

extension ScanTimings: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case prepMs, detectMs, classifyMs, recognizeMs, parseMs, totalMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(prepMs: try c.decode(Double.self, forKey: .prepMs),
                  detectMs: try c.decode(Double.self, forKey: .detectMs),
                  classifyMs: try c.decode(Double.self, forKey: .classifyMs),
                  recognizeMs: try c.decode(Double.self, forKey: .recognizeMs),
                  parseMs: try c.decode(Double.self, forKey: .parseMs),
                  totalMs: try c.decode(Double.self, forKey: .totalMs))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(prepMs, forKey: .prepMs)
        try c.encode(detectMs, forKey: .detectMs)
        try c.encode(classifyMs, forKey: .classifyMs)
        try c.encode(recognizeMs, forKey: .recognizeMs)
        try c.encode(parseMs, forKey: .parseMs)
        try c.encode(totalMs, forKey: .totalMs)
    }
}

extension MerchantMatchStatus: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "exact": self = .exact
        case "corrected": self = .corrected
        case "suggested": self = .suggested
        default: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .exact: try c.encode("exact")
        case .corrected: try c.encode("corrected")
        case .suggested: try c.encode("suggested")
        case .unknown: try c.encode("unknown")
        }
    }
}

extension MerchantMatch: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case raw, canonical, status, score }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(raw: try c.decode(String.self, forKey: .raw),
                  canonical: try c.decodeIfPresent(String.self, forKey: .canonical),
                  status: try c.decode(MerchantMatchStatus.self, forKey: .status),
                  score: try c.decode(Double.self, forKey: .score))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(raw, forKey: .raw)
        try c.encodeIfPresent(canonical, forKey: .canonical)
        try c.encode(status, forKey: .status)
        try c.encode(score, forKey: .score)
    }
}

extension ReceiptItem: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case description, price, quantity, category, tags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(description: try c.decode(String.self, forKey: .description),
                  price: try c.decode(String.self, forKey: .price),
                  quantity: try c.decode(Int32.self, forKey: .quantity),
                  category: try c.decodeIfPresent(String.self, forKey: .category),
                  tags: try c.decode([String].self, forKey: .tags))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .description)
        try c.encode(price, forKey: .price)
        try c.encode(quantity, forKey: .quantity)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encode(tags, forKey: .tags)
    }
}

extension ReceiptResult: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case merchant, merchantMatch, date, dateIsPlaceholder, total, tax, subtotal
        case items, warnings, beancount, beanbeaverId, documentRelpath, timings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(merchant: try c.decode(String.self, forKey: .merchant),
                  merchantMatch: try c.decode(MerchantMatch.self, forKey: .merchantMatch),
                  date: try c.decodeIfPresent(String.self, forKey: .date),
                  dateIsPlaceholder: try c.decode(Bool.self, forKey: .dateIsPlaceholder),
                  total: try c.decode(String.self, forKey: .total),
                  tax: try c.decodeIfPresent(String.self, forKey: .tax),
                  subtotal: try c.decodeIfPresent(String.self, forKey: .subtotal),
                  items: try c.decode([ReceiptItem].self, forKey: .items),
                  warnings: try c.decode([String].self, forKey: .warnings),
                  // v0.3.3 grew ReceiptResult with these FFI fields. No batch UI
                  // reads them yet, and the persisted batch JSON predates them, so
                  // default here rather than widen the on-disk schema (CodingKeys /
                  // encode stay unchanged, keeping old batch files loadable).
                  warningAfterItemIndices: [],
                  rawText: "",
                  imageFilename: "receipt.jpg",
                  tenders: [],
                  beancount: try c.decode(String.self, forKey: .beancount),
                  beanbeaverId: try c.decodeIfPresent(String.self, forKey: .beanbeaverId),
                  documentRelpath: try c.decodeIfPresent(String.self, forKey: .documentRelpath),
                  timings: try c.decode(ScanTimings.self, forKey: .timings),
                  confidence: FieldConfidences(
                      merchant: 0, date: 0, total: 0, itemsCategorized: 0, needsReview: false))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(merchant, forKey: .merchant)
        try c.encode(merchantMatch, forKey: .merchantMatch)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encode(dateIsPlaceholder, forKey: .dateIsPlaceholder)
        try c.encode(total, forKey: .total)
        try c.encodeIfPresent(tax, forKey: .tax)
        try c.encodeIfPresent(subtotal, forKey: .subtotal)
        try c.encode(items, forKey: .items)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(beancount, forKey: .beancount)
        try c.encodeIfPresent(beanbeaverId, forKey: .beanbeaverId)
        try c.encodeIfPresent(documentRelpath, forKey: .documentRelpath)
        try c.encode(timings, forKey: .timings)
    }
}

extension ReceiptResult {
    /// Whether this parse is worth a second look before it lands in a ledger:
    /// the parser flagged something, the merchant is only a guess, or an item
    /// came back with no classification. Drives the row's badge — never blocks
    /// a sync, since the user may well be fine with it.
    var needsAttention: Bool {
        if !warnings.isEmpty { return true }
        if case .suggested = merchantMatch.status { return true }
        return items.contains { $0.tags.isEmpty }
    }
}

// MARK: - Draft

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
}

// MARK: - Batch

/// The pending photo-library import: a queue of receipts to parse, review, and
/// sync in one go. Survives relaunch (see `ReceiptBatch.fileURL`), so the
/// interesting states are the ones that outlive a process.
///
/// Separate from `ReceiptPipeline`, which drives the single camera scan — they
/// share the OCR session and `ReceiptCaptureStore`, but nothing else. Photos
/// are never deleted here; `ReceiptCaptureStore.clearOld` owns that, and a
/// draft leaving the batch is what makes its photo eligible.
@Observable
@MainActor
final class ReceiptBatch {
    private(set) var drafts: [ReceiptDraft] = []
    private(set) var isParsing = false

    /// When the oldest receipt still here was added; nil when empty.
    ///
    /// Derived rather than stored, because a stored stamp outlives its own
    /// batch: syncing drains what parsed but leaves failures behind, so a stamp
    /// pinned to the original import would go on dating a pile that is by then
    /// mostly new photos. Taking it from the drafts keeps it true by
    /// construction.
    var createdAt: Date? { drafts.map(\.addedAt).min() }

    /// Default credit-card account for the placeholder posting, mirroring
    /// `ReceiptPipeline`.
    var creditCardAccount = "Liabilities:CreditCard"

    private var parseTask: Task<Void, Never>?

    /// Alongside the photos it names, in the backup-excluded support directory.
    /// Kept together deliberately: a batch restored without its photos would
    /// point at nothing, so both are excluded or neither is.
    private static var fileURL: URL {
        ReceiptCaptureStore.directory.appendingPathComponent("batch.json")
    }

    private struct Persisted: Codable {
        let drafts: [ReceiptDraft]
    }

    init() {
        load()
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

    /// Parsed receipts the user probably wants to look at before syncing.
    var needsAttentionCount: Int {
        drafts.filter { $0.state.result?.needsAttention == true }.count
    }

    /// Every parsed receipt as a ledger entry, oldest first. The photo is read
    /// back off disk here so its `document:` link resolves on the far side.
    var syncableEntries: [LedgerEntry] {
        drafts.compactMap { draft in
            guard let result = draft.state.result else { return nil }
            return LedgerEntry.make(from: result,
                                    imageURL: ReceiptCaptureStore.url(forFilename: draft.captureFilename),
                                    wallMs: draft.wallMs)
        }
    }

    func url(for draft: ReceiptDraft) -> URL {
        ReceiptCaptureStore.url(forFilename: draft.captureFilename)
    }

    /// Filenames the batch still needs, so `Clear Old Receipts` doesn't delete
    /// the photos out from under a pending import.
    var liveCaptureFilenames: Set<String> {
        Set(drafts.map(\.captureFilename))
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
        let hash = Self.contentHash(imageData)
        guard !drafts.contains(where: { $0.contentHash == hash }) else { return .duplicate }
        let url = ReceiptCaptureStore.newCaptureURL()
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

    /// Drop a draft, photo and all. Removing a row means the user doesn't want
    /// it: nothing else refers to the photo, and it's their storage.
    func remove(_ id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        deleteCapture(drafts.remove(at: index))
        save()
    }

    /// Throw the whole batch away — the only bulk exit other than syncing, and
    /// the one that makes a batch of receipts that will never parse endable.
    /// Cancels any scan in flight: no point finishing one for a draft that's
    /// going anyway.
    func discardAll() {
        stopParsing()
        drafts.forEach(deleteCapture)
        drafts = []
        save()
    }

    /// Drop everything that parsed — what a successful sync drains.
    ///
    /// Photos deliberately stay for `Clear Old Receipts`: they're in the ledger
    /// now, and what to keep after a sync is the cleanup workflow that hasn't
    /// been designed yet. Leaving the batch is what makes them collectable.
    func removeParsed() {
        drafts.removeAll { $0.state.result != nil }
        save()
    }

    private func deleteCapture(_ draft: ReceiptDraft) {
        try? FileManager.default.removeItem(
            at: ReceiptCaptureStore.url(forFilename: draft.captureFilename))
    }

    func retry(_ id: UUID) {
        setState(.queued, for: id)
        startParsing()
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
            let url = ReceiptCaptureStore.url(forFilename: draft.captureFilename)
            guard let data = try? Data(contentsOf: url) else {
                setState(.failed("This receipt's photo is no longer on this device."), for: draft.id)
                continue
            }
            let account = creditCardAccount
            do {
                let session = try OcrSessionProvider.loaded()
                let started = Date()
                // OCR is CPU-heavy; keep it off the main actor.
                let result = try await Task.detached(priority: .userInitiated) {
                    try session.scan(imageData: data, creditCardAccount: account)
                }.value
                let wallMs = Date().timeIntervalSince(started) * 1000
                setState(.parsed(result), for: draft.id, wallMs: wallMs)
                DebugInfoStore.recordSuccess(result: result, wallMs: wallMs)
            } catch {
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
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        let fm = FileManager.default
        drafts = stored.drafts.compactMap { draft in
            // The photo is the source of truth, so a draft without one is
            // unusable — and syncing it anyway would write a `document:` link
            // to a file that never gets uploaded. Only reachable if the support
            // directory was cleared out from under us (a restore, say), in
            // which case the originals are still in the user's photo library.
            guard fm.fileExists(atPath: ReceiptCaptureStore
                .url(forFilename: draft.captureFilename).path) else { return nil }
            var draft = draft
            // Killed mid-scan; nothing else can leave a draft in this state.
            if isScanning(draft.state) { draft.state = .interrupted }
            return draft
        }
    }

    private func save() {
        guard !drafts.isEmpty else {
            try? FileManager.default.removeItem(at: Self.fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(Persisted(drafts: drafts)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
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
