import Foundation
import BBReceiptKit

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

/// Persist the full receipt observation, including uncertainty and correction
/// provenance. A sourceId identifies an extraction occurrence, not a card.
struct StoredGiftRedemption: Codable {
    let sourceId: String
    let issuer: String?
    let currency: String?
    let printedIdentifier: String?
    let normalizedIdentifier: String?
    let remainingBalanceCents: Int64?
    let authorizationReference: String?
    let expiry: String
    let expiryDate: String?
    let evidence: [StoredGiftPurchase.Evidence]
    let unresolvedFields: [String]
    let correctedFields: [String]

    init(_ gift: GiftCardRedemption) {
        sourceId = gift.sourceId; issuer = gift.issuer; currency = gift.currency
        printedIdentifier = gift.printedIdentifier; normalizedIdentifier = gift.normalizedIdentifier
        remainingBalanceCents = gift.remainingBalanceCents
        authorizationReference = gift.authorizationReference
        switch gift.expiry {
        case .unknown: expiry = "unknown"
        case .noExpiry: expiry = "noExpiry"
        case .printedDate: expiry = "printedDate"
        }
        expiryDate = gift.expiryDate
        evidence = gift.evidence.map { .init(field: $0.field, lineIndex: $0.lineIndex, text: $0.text) }
        unresolvedFields = gift.unresolvedFields; correctedFields = gift.correctedFields
    }

    var value: GiftCardRedemption {
        let state: GiftCardExpiry
        switch expiry {
        case "noExpiry": state = .noExpiry
        case "printedDate": state = .printedDate
        default: state = .unknown
        }
        return GiftCardRedemption(
            sourceId: sourceId, issuer: issuer, currency: currency,
            printedIdentifier: printedIdentifier, normalizedIdentifier: normalizedIdentifier,
            remainingBalanceCents: remainingBalanceCents,
            authorizationReference: authorizationReference, expiry: state, expiryDate: expiryDate,
            evidence: evidence.map { .init(field: $0.field, lineIndex: $0.lineIndex, text: $0.text) },
            unresolvedFields: unresolvedFields, correctedFields: correctedFields)
    }
}

/// All tenders stay in printed order, including ordinary payments in a split.
/// Used by both on-disk receipts and the structured export sidecar.
struct StoredTender: Codable {
    let amount: String
    let account: String?
    let kind: String
    let rawLabel: String
    let giftCard: StoredGiftRedemption?

    init(_ tender: ReceiptTender) {
        amount = tender.amount; account = tender.account
        kind = tender.kind; rawLabel = tender.rawLabel
        giftCard = tender.giftCard.map(StoredGiftRedemption.init)
    }

    var value: ReceiptTender {
        ReceiptTender(giftCard: giftCard?.value, amount: amount, account: account,
                      kind: kind, rawLabel: rawLabel)
    }
}
