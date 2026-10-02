import Foundation
import BBReceiptKit

enum PriceHistoryPrefs {
    static let enabledKey = "priceHistoryEnabled"
}

/// Persist only the user's links. Purchases and item indices are rebuilt from
/// the current receipts, so inserting or removing a line cannot move an alias.
struct HistoryMember: Codable, Hashable {
    enum Kind: String, Codable { case code, name }
    let merchant: String
    let kind: Kind
    let value: String

    init(_ key: SpendItemKey) {
        merchant = key.merchant
        kind = key.kind == .code ? .code : .name
        value = key.value
    }

    var input: SpendItemKey {
        SpendItemKey(merchant: merchant, kind: kind == .code ? .code : .name, value: value)
    }
}

struct HistoryLink: Codable {
    let id: String
    let name: String
    let members: [HistoryMember]

    var input: SpendProductLink {
        SpendProductLink(id: id, name: name, members: members.map(\.input))
    }
}

extension SpendRecord {
    var historyInput: SpendHistoryReceipt {
        SpendHistoryReceipt(
            id: id.uuidString, merchant: result.merchant,
            merchantFamily: result.merchantMatch.canonical,
            dateIso: result.date, dateIsPlaceholder: result.dateIsPlaceholder,
            items: result.items.map {
                SpendHistoryItem(description: $0.description, itemNumber: $0.itemNumber,
                                 price: $0.price, quantity: $0.quantity,
                                 tags: $0.tags.map { SpendTag(path: $0.path, display: $0.display) },
                                 isGiftCard: $0.giftCard != nil)
            })
    }
}

enum HistoryID: Hashable {
    case product(String)
    case item(HistoryMember)
}

extension SpendItemHistory {
    var purchaseCountLabel: String {
        receiptCount == 1 ? "Purchased once" : "Purchased \(receiptCount) times"
    }

    /// Rust returns line observations. Present one shopping occasion per receipt,
    /// keeping its lines together and preserving the core's newest-first order.
    var purchaseOccasions: [HistoryPurchaseOccasion] {
        var occasions: [HistoryPurchaseOccasion] = []
        var indices: [String: Int] = [:]
        for purchase in purchases {
            if let index = indices[purchase.receiptId] {
                occasions[index].lines.append(purchase)
            } else {
                indices[purchase.receiptId] = occasions.count
                occasions.append(HistoryPurchaseOccasion(id: purchase.receiptId, lines: [purchase]))
            }
        }
        return occasions
    }

    var historyID: HistoryID {
        switch key {
        case .product(let id): return .product(id)
        case .item(let key): return .item(HistoryMember(key))
        }
    }

    var productID: String? {
        if case .product(let id) = key { return id }
        return nil
    }

    func matches(_ query: String) -> Bool {
        func folded(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased()
        }
        let needle = folded(query)
        // Foundation's String.contains("") is false, unlike Rust's str::contains.
        guard !needle.isEmpty else { return true }
        let fields = [name] + members.flatMap { [$0.merchant, $0.value] }
            + purchases.flatMap { [$0.description, $0.merchant] }
        return fields.contains { folded($0).contains(needle) }
    }
}

struct HistoryPurchaseOccasion: Identifiable {
    let id: String
    var lines: [SpendPurchase]

    /// Multiple lines in one transaction do not establish a price history.
    static func pricedReceiptCount(in occasions: [Self]) -> Int {
        occasions.filter { $0.lines.contains { $0.unitPrice != nil } }.count
    }
}

extension SpendPurchase {
    var purchaseID: String { "\(receiptId):\(itemIndex)" }
    var purchaseDateLabel: String {
        guard let date else { return "Date unknown" }
        return String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
}

/// Stable storage for purchase metadata is needed even without a gift-card UI:
/// otherwise a restart turns excluded gift-card lines into product prices.
struct StoredGiftPurchase: Codable {
    struct Evidence: Codable {
        let field: String
        let lineIndex: UInt32
        let text: String
    }
    let sourceId: String
    let issuer: String?
    let currency: String?
    let activation: String
    let referenceLabel: String?
    let reference: String?
    let cardCount: UInt32?
    let denominationCents: Int64?
    let totalFaceValueCents: Int64?
    let faceValueDerived: Bool
    let evidence: [Evidence]
    let unresolvedFields: [String]
    let correctedFields: [String]

    init(_ gift: GiftCardPurchase) {
        sourceId = gift.sourceId; issuer = gift.issuer; currency = gift.currency
        activation = gift.activation == .activated ? "activated" : "unknown"
        referenceLabel = gift.referenceLabel; reference = gift.reference
        cardCount = gift.cardCount; denominationCents = gift.denominationCents
        totalFaceValueCents = gift.totalFaceValueCents; faceValueDerived = gift.faceValueDerived
        evidence = gift.evidence.map { Evidence(field: $0.field, lineIndex: $0.lineIndex, text: $0.text) }
        unresolvedFields = gift.unresolvedFields; correctedFields = gift.correctedFields
    }

    var value: GiftCardPurchase {
        GiftCardPurchase(sourceId: sourceId, issuer: issuer, currency: currency,
                         activation: activation == "activated" ? .activated : .unknown,
                         referenceLabel: referenceLabel, reference: reference, cardCount: cardCount,
                         denominationCents: denominationCents, totalFaceValueCents: totalFaceValueCents,
                         faceValueDerived: faceValueDerived,
                         evidence: evidence.map { GiftCardEvidence(field: $0.field, lineIndex: $0.lineIndex, text: $0.text) },
                         unresolvedFields: unresolvedFields, correctedFields: correctedFields)
    }
}
