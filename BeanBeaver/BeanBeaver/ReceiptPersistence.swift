import Foundation
import BBReceiptKit

// MARK: - Persistence for the scan types

// UniFFI emits plain structs, so the generated scan types aren't `Codable` and
// synthesis can't reach them from here (it only works in the declaring file).
// These conformances are written out by hand so a parsed batch can be stored
// and come back whole — including `beancount`, `beanbeaverId` and
// `documentRelpath`, which `ReceiptExportJSON` drops and which a later export
// still needs.
//
// `@retroactive` because these types belong to BBReceiptKit: if the generated
// bindings ever grow their own `Codable`, this collides — loudly, at build
// time, which is the point of saying so here. The alternative, a parallel set
// of mirror structs plus two mappings, is more code to drift out of sync with
// the core for no benefit the compiler can't already police.

extension ScanTimings {
    /// Milliseconds recorded for `phase`, or 0 if the span is absent (e.g. the
    /// parse-only path, or a phase this build didn't measure).
    func ms(_ phase: Phase) -> Double { spans.first { $0.phase == phase }?.ms ?? 0 }

    /// The scan total is the sum of all phase spans (there is no separate
    /// `total` span). Kept as `totalMs` so existing call sites read naturally.
    var totalMs: Double { spans.reduce(0) { $0 + $1.ms } }
}

// ScanTimings now carries an ordered `[PhaseSpan]`; we still serialize it as a
// flat `{ decodeMs, prepMs, … , totalMs }` object so the batch/latency harness
// schema (device-latency.py) is unchanged. Missing keys decode to 0.
extension ScanTimings: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case decodeMs, prepMs, detectMs, classifyMs, recognizeMs, parseMs, totalMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double { (try? c.decode(Double.self, forKey: k)) ?? 0 }
        self.init(spans: [
            PhaseSpan(phase: .decode, ms: d(.decodeMs)),
            PhaseSpan(phase: .prep, ms: d(.prepMs)),
            PhaseSpan(phase: .detect, ms: d(.detectMs)),
            PhaseSpan(phase: .classify, ms: d(.classifyMs)),
            PhaseSpan(phase: .recognize, ms: d(.recognizeMs)),
            PhaseSpan(phase: .parse, ms: d(.parseMs)),
        ])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ms(.decode), forKey: .decodeMs)
        try c.encode(ms(.prep), forKey: .prepMs)
        try c.encode(ms(.detect), forKey: .detectMs)
        try c.encode(ms(.classify), forKey: .classifyMs)
        try c.encode(ms(.recognize), forKey: .recognizeMs)
        try c.encode(ms(.parse), forKey: .parseMs)
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

extension ItemTag: @retroactive Codable {
    enum CodingKeys: String, CodingKey { case path, display }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try c.decode(String.self, forKey: .path),
                  display: try c.decode(String.self, forKey: .display))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(display, forKey: .display)
    }
}

extension ReceiptItem: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case description, itemNumber, price, quantity, account, tagPath, tags, giftCard
        /// Pre-0.7.0 batches wrote a classifier key here, not an account.
        case category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // A batch saved by an older build is still sitting in Application
        // Support when the app updates, so both shapes have to decode or the
        // user loses an in-progress import.
        //
        // The old `category` deliberately does NOT become `account`: it held a
        // classifier key (`grocery_dairy`), not a beancount account, so copying
        // it across would fabricate a wrong account. The draft's rendered
        // beancount text is stored alongside and remains authoritative.
        let account = try c.decodeIfPresent(String.self, forKey: .account)

        let tags: [ItemTag]
        if let labelled = try? c.decode([ItemTag].self, forKey: .tags) {
            tags = labelled
        } else {
            // Old flat tags were bare segments; only the last was ever shown, so
            // a capitalized fallback keeps a legacy draft rendering sensibly.
            let legacy = (try? c.decode([String].self, forKey: .tags)) ?? []
            tags = legacy.map { ItemTag(path: $0, display: $0.capitalized) }
        }

        // Core v0.13.2 added the winning classification path. A batch written
        // before it has no such key, and nil is the honest answer there: the
        // deepest tag is not reliably the one that claimed the account, which
        // is why core stopped deriving it that way.
        let tagPath = try c.decodeIfPresent(String.self, forKey: .tagPath)

        // Core v0.14.0 added the merchant's printed item code. A batch written
        // before it has no such key, and nil is right: the code is only ever
        // read off the receipt, so it cannot be recovered from an older draft.
        let itemNumber = try c.decodeIfPresent(String.self, forKey: .itemNumber)

        self.init(giftCard: try c.decodeIfPresent(StoredGiftPurchase.self, forKey: .giftCard)?.value,
                  description: try c.decode(String.self, forKey: .description),
                  itemNumber: itemNumber,
                  price: try c.decode(String.self, forKey: .price),
                  quantity: try c.decode(Int32.self, forKey: .quantity),
                  account: account,
                  tagPath: tagPath,
                  tags: tags)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(itemNumber, forKey: .itemNumber)
        try c.encodeIfPresent(giftCard.map(StoredGiftPurchase.init), forKey: .giftCard)
        try c.encode(price, forKey: .price)
        try c.encode(quantity, forKey: .quantity)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encodeIfPresent(tagPath, forKey: .tagPath)
        try c.encode(tags, forKey: .tags)
    }
}

/// On-disk form of a parser finding. `ReceiptWarning` comes from uniffi and has
/// no `Codable`, and its kind has no raw value, so the mapping is spelled out
/// here — exhaustively, so a new core variant is a compiler error in one place
/// rather than a silently mis-stored receipt.
private struct StoredWarning: Codable {
    let kind: String
    let message: String
    let afterItemIndex: Int32

    init(_ w: ReceiptWarning) {
        kind = Self.name(for: w.kind)
        message = w.message
        afterItemIndex = w.afterItemIndex
    }

    var warning: ReceiptWarning {
        ReceiptWarning(kind: Self.kind(named: kind), message: message,
                       afterItemIndex: afterItemIndex)
    }

    private static func name(for kind: ReceiptWarningKind) -> String {
        switch kind {
        case .totalMismatch: return "totalMismatch"
        case .subtotalMismatch: return "subtotalMismatch"
        case .possibleMissedItem: return "possibleMissedItem"
        case .priceAutoCorrected: return "priceAutoCorrected"
        case .droppedImplausiblePrice: return "droppedImplausiblePrice"
        case .uncategorizedItem: return "uncategorizedItem"
        case .tenderMismatch: return "tenderMismatch"
        case .implausibleSummary: return "implausibleSummary"
        @unknown default: return "possibleMissedItem"
        }
    }

    /// An unrecognized name means the file was written by a *newer* build than
    /// this one — downgrade, or a restored backup. Land on the same fallback
    /// `WarningSeverity` gives an unknown kind: shown, quietly.
    private static func kind(named name: String) -> ReceiptWarningKind {
        switch name {
        case "totalMismatch": return .totalMismatch
        case "subtotalMismatch": return .subtotalMismatch
        case "priceAutoCorrected": return .priceAutoCorrected
        case "droppedImplausiblePrice": return .droppedImplausiblePrice
        case "uncategorizedItem": return .uncategorizedItem
        case "tenderMismatch": return .tenderMismatch
        case "implausibleSummary": return .implausibleSummary
        default: return .possibleMissedItem
        }
    }
}

extension MerchantDetails {
    /// What core returns for a receipt whose address block it found nothing in
    /// — every field absent. Spelled once because two places need to say "there
    /// were no details": the decoder below, for batch files written before core
    /// v0.12.0 carried them, and the SwiftUI previews.
    static let empty = MerchantDetails(
        streetAddress: nil, city: nil, region: nil, postalCode: nil,
        phoneNumber: nil, storeNumber: nil, rawLines: [])
}

extension ReceiptResult: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case merchant, merchantMatch, date, dateIsPlaceholder, total, tax, subtotal
        case items, tenders, warnings, beancount, beanbeaverId, documentRelpath, timings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(merchant: try c.decode(String.self, forKey: .merchant),
                  merchantMatch: try c.decode(MerchantMatch.self, forKey: .merchantMatch),
                  merchantDetails: .empty,
                  date: try c.decodeIfPresent(String.self, forKey: .date),
                  dateIsPlaceholder: try c.decode(Bool.self, forKey: .dateIsPlaceholder),
                  total: try c.decode(String.self, forKey: .total),
                  tax: try c.decodeIfPresent(String.self, forKey: .tax),
                  subtotal: try c.decodeIfPresent(String.self, forKey: .subtotal),
                  items: try c.decode([ReceiptItem].self, forKey: .items),
                  warnings: ReceiptResult.decodeWarnings(from: c),
                  // v0.3.3 (and v0.4.0's `detections`, v0.12.0's
                  // `merchantDetails` above) grew ReceiptResult with these FFI
                  // fields. No batch UI reads them yet, and the persisted batch
                  // JSON predates them, so default here rather than widen the
                  // on-disk schema for these unused fields. Missing optional
                  // fields elsewhere still keep old batch files loadable.
                  //
                  // `merchantDetails` is deliberately not persisted rather than
                  // merely not-yet-persisted: it carries a street address, a phone
                  // number and the raw lines they were read from, and this app does
                  // not write anything to disk that no screen reads. The scan that
                  // produced a receipt has the details in memory; whichever feature
                  // first needs them after a reload can widen the schema and say
                  // why.
                  rawText: "",
                  imageFilename: "receipt.jpg",
                  // Old records have no payment evidence to recover.
                  tenders: try c.decodeIfPresent([StoredTender].self, forKey: .tenders)?.map(\.value) ?? [],
                  beancount: try c.decode(String.self, forKey: .beancount),
                  beanbeaverId: try c.decodeIfPresent(String.self, forKey: .beanbeaverId),
                  documentRelpath: try c.decodeIfPresent(String.self, forKey: .documentRelpath),
                  timings: try c.decode(ScanTimings.self, forKey: .timings),
                  confidence: FieldConfidences(
                      merchant: 0, date: 0, total: 0, itemsCategorized: 0, needsReview: false),
                  detections: [])
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
        try c.encode(tenders.map(StoredTender.init), forKey: .tenders)
        try c.encode(warnings.map(StoredWarning.init), forKey: .warnings)
        try c.encode(beancount, forKey: .beancount)
        try c.encodeIfPresent(beanbeaverId, forKey: .beanbeaverId)
        try c.encodeIfPresent(documentRelpath, forKey: .documentRelpath)
        try c.encode(timings, forKey: .timings)
    }
}

extension ReceiptResult {
    /// Read the `warnings` key in either shape.
    ///
    /// Files written before core v0.8.0 hold bare strings, and a string's kind
    /// cannot be recovered without pattern-matching the English — the exact
    /// thing kinds exist to abolish, and a guess here would mis-rank a stored
    /// receipt forever. So a legacy list is dropped rather than invented.
    /// What's lost is the "Heads up" text on receipts already scanned and
    /// already reviewed; what's kept is everything that matters later — the
    /// items, the totals, and the stored beancount, whose own `; WARN:PARSER`
    /// comments still carry those messages verbatim.
    fileprivate static func decodeWarnings(
        from c: KeyedDecodingContainer<ReceiptResult.CodingKeys>
    ) -> [ReceiptWarning] {
        if let stored = try? c.decode([StoredWarning].self, forKey: .warnings) {
            return stored.map(\.warning)
        }
        return []
    }

    /// Whether this parse is worth a second look before it lands in a ledger.
    /// Drives the row's badge — never blocks an export, since the user may well
    /// be fine with it.
    ///
    /// Two clauses, both about things that are actually wrong: a finding the
    /// app ranks as `.attention` (see `WarningSeverity`), or a merchant that is
    /// only a guess. `findings` rather than `warnings`, so the app's own
    /// findings badge too — a receipt with no date is one, and it reaches every
    /// list that shows this badge without any of them knowing about dates. The
    /// third clause used to be
    /// `items.contains { $0.tags.isEmpty }` — this app deciding, on its own,
    /// that an unclassified line meant a bad parse. It reported 83 of 124
    /// corpus receipts, including every receipt carrying a *correctly parsed*
    /// discount line, which is not a product and matches no product rule. A
    /// badge that lights on two receipts in three is not a badge, so that
    /// judgment now lives in core as `UncategorizedItem` and is ranked `.info`.
    var needsAttention: Bool {
        if findings.contains(where: { $0.severity >= .attention }) { return true }
        if case .suggested = merchantMatch.status { return true }
        return false
    }
}

// MARK: - Draft
