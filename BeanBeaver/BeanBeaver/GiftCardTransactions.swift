import Foundation
import BBReceiptKit

/// A receipt search, not a tracked-card identity or a computed balance.
/// Full masked identifiers are evidence only; never merge on a suffix, amount,
/// authorization reference, or a purchase/pack reference.
enum GiftCardTransactionSource {
    case payment(GiftCardRedemption)
    case purchase(GiftCardPurchase)
}

struct GiftCardVisit: Identifiable {
    let id: String
    let recordID: UUID?
    let receipt: ReceiptResult
    let paymentIndices: [Int]
    let purchaseIndices: [Int]

    var date: String? {
        guard !receipt.dateIsPlaceholder, let date = receipt.date, !date.isEmpty else { return nil }
        return date
    }
}

enum GiftCardTransactions {
    /// Only mask glyphs are normalized. Visible digits and mask positions stay
    /// significant, including a masked final digit. Do not fuzzy-match OCR.
    static func identifier(_ printed: String?) -> String? {
        guard let printed = printed?.trimmingCharacters(in: .whitespacesAndNewlines),
              !printed.isEmpty else { return nil }
        let normalized = printed.map { "xX×*".contains($0) ? "*" : String($0) }.joined()
        guard normalized.contains(where: { $0.isNumber }) else { return nil }
        return normalized
    }

    private static func context(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.uppercased()
    }

    static func canFindOtherVisits(_ gift: GiftCardRedemption) -> Bool {
        context(gift.issuer) != nil && context(gift.currency) != nil && identifier(gift.printedIdentifier) != nil
            && !gift.unresolvedFields.contains(where: { ["printed_identifier", "normalized_identifier", "issuer", "currency", "association"].contains($0) })
    }

    private static func matches(_ candidate: GiftCardRedemption, _ source: GiftCardRedemption) -> Bool {
        canFindOtherVisits(source) && canFindOtherVisits(candidate)
            && context(candidate.issuer) == context(source.issuer)
            && context(candidate.currency) == context(source.currency)
            && identifier(candidate.printedIdentifier) == identifier(source.printedIdentifier)
    }

    static func visits(source: GiftCardTransactionSource, current: ReceiptResult,
                       records: [SpendRecord]) -> [GiftCardVisit] {
        // The currently open receipt may be a fresh batch scan whose existing
        // history record predates metadata. Use the open result for that visit,
        // without overwriting the stored record or the user's corrections.
        let currentRecord = current.beanbeaverId.flatMap { id in
            records.first { $0.result.beanbeaverId == id }
        }
        var candidates: [(UUID?, ReceiptResult, Bool)] = [(currentRecord?.id, current, true)]
        if case .payment = source {
            candidates += records.filter { $0.id != currentRecord?.id }.map { ($0.id, $0.result, false) }
        }
        var seen = Set<String>()
        var visits: [GiftCardVisit] = []
        for (recordID, receipt, isCurrent) in candidates {
            let id = receipt.beanbeaverId ?? recordID?.uuidString ?? "current"
            guard seen.insert(id).inserted else { continue }
            let payments: [Int]
            let purchases: [Int]
            switch source {
            case .payment(let gift):
                payments = receipt.tenders.indices.filter { index in
                    guard let candidate = receipt.tenders[index].giftCard else { return false }
                    return (isCurrent && candidate.sourceId == gift.sourceId) || matches(candidate, gift)
                }
                purchases = []
            case .purchase(let gift):
                payments = []
                // Pack references are not redemption identifiers. Until the
                // user can explicitly link individual cards, only this purchase
                // is known to belong here.
                purchases = receipt.items.indices.filter { receipt.items[$0].giftCard?.sourceId == gift.sourceId }
            }
            guard !payments.isEmpty || !purchases.isEmpty else { continue }
            visits.append(GiftCardVisit(id: id, recordID: recordID, receipt: receipt,
                                        paymentIndices: payments, purchaseIndices: purchases))
        }
        return visits.sorted {
            switch ($0.date, $1.date) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
    }
}
