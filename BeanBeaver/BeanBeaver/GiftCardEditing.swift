import Foundation
import BBReceiptKit

/// Money at this boundary stays in cents. Never round a Double into a balance.
enum GiftCardInput {
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func optional(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func amount(_ cents: Int64?) -> String {
        guard let cents else { return "" }
        let magnitude = cents.magnitude
        return "\(cents < 0 ? "-" : "")\(magnitude / 100).\(String(format: "%02llu", magnitude % 100))"
    }

    /// Both decimal keyboard separators are accepted; grouping is deliberately
    /// not accepted, so an ambiguous value cannot silently change by 1000x.
    static func cents(_ text: String, field: String) throws -> Int64? {
        guard let text = optional(text) else { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        let digits: (Substring) -> Bool = { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
        guard parts.count <= 2, digits(parts[0]),
              parts.count == 1 || (digits(parts[1]) && parts[1].count <= 2) else {
            throw Invalid(message: "\(field) must be a nonnegative amount with at most two decimal places.")
        }
        let fraction = parts.count == 1 ? "00" : String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0)
        let raw = (String(parts[0]) + fraction).drop { $0 == "0" }
        guard let value = Int64(raw.isEmpty ? "0" : String(raw)) else {
            throw Invalid(message: "\(field) is too large.")
        }
        return value
    }

    static func count(_ text: String) throws -> UInt32? {
        guard let text = optional(text) else { return nil }
        guard text.utf8.allSatisfy({ (48...57).contains($0) }), let count = UInt32(text), count > 0 else {
            throw Invalid(message: "Card count must be a positive whole number.")
        }
        return count
    }
}

struct GiftCardRedemptionDraft: Equatable {
    private let original: ReceiptTender
    var amount: String
    var issuer: String
    var currency: String
    var identifier: String
    var balance: String
    var authorization: String
    var expiry: GiftCardExpiry
    var expiryDate: String

    init(_ tender: ReceiptTender) {
        original = tender
        let gift = tender.giftCard!
        amount = tender.amount
        issuer = gift.issuer ?? ""; currency = gift.currency ?? ""
        identifier = gift.printedIdentifier ?? ""
        balance = GiftCardInput.amount(gift.remainingBalanceCents)
        authorization = gift.authorizationReference ?? ""
        expiry = gift.expiry; expiryDate = gift.expiryDate ?? ""
    }

    func applied() throws -> ReceiptTender {
        var tender = original
        guard let amountCents = try GiftCardInput.cents(amount, field: "Amount used") else {
            throw GiftCardInput.Invalid(message: "Enter the amount used for this payment.")
        }
        tender.amount = GiftCardInput.amount(amountCents)
        var gift = tender.giftCard!
        gift.issuer = GiftCardInput.optional(issuer)
        gift.currency = GiftCardInput.optional(currency)
        gift.printedIdentifier = GiftCardInput.optional(identifier)
        gift.remainingBalanceCents = try GiftCardInput.cents(balance, field: "Reported balance")
        gift.authorizationReference = GiftCardInput.optional(authorization)
        gift.expiry = expiry
        gift.expiryDate = expiry == .printedDate ? GiftCardInput.optional(expiryDate) : nil
        if expiry == .printedDate && gift.expiryDate == nil {
            throw GiftCardInput.Invalid(message: "Enter the expiry date as printed, or choose Unknown.")
        }
        // Rust normalizes the identifier and records changed fields on Save.
        tender.giftCard = gift
        return tender
    }
}

struct GiftCardPurchaseDraft: Equatable {
    private let original: GiftCardPurchase
    var issuer: String
    var currency: String
    var activation: GiftCardActivation
    var referenceLabel: String
    var reference: String
    var count: String
    var denomination: String
    var totalFaceValue: String
    var derived: Bool

    init(_ gift: GiftCardPurchase) {
        original = gift
        issuer = gift.issuer ?? ""; currency = gift.currency ?? ""
        activation = gift.activation
        referenceLabel = gift.referenceLabel ?? ""; reference = gift.reference ?? ""
        count = gift.cardCount.map(String.init) ?? ""
        denomination = GiftCardInput.amount(gift.denominationCents)
        totalFaceValue = GiftCardInput.amount(gift.totalFaceValueCents)
        derived = gift.faceValueDerived
    }

    func applied() throws -> GiftCardPurchase {
        var gift = original
        gift.issuer = GiftCardInput.optional(issuer); gift.currency = GiftCardInput.optional(currency)
        gift.activation = activation
        gift.referenceLabel = GiftCardInput.optional(referenceLabel)
        gift.reference = GiftCardInput.optional(reference)
        gift.cardCount = try GiftCardInput.count(count)
        gift.denominationCents = try GiftCardInput.cents(denomination, field: "Value per card")
        gift.faceValueDerived = derived
        if derived {
            guard let count = gift.cardCount, let value = gift.denominationCents else {
                throw GiftCardInput.Invalid(message: "Enter card count and value per card to calculate face value.")
            }
            let product = value.multipliedReportingOverflow(by: Int64(count))
            guard !product.overflow else { throw GiftCardInput.Invalid(message: "Total face value is too large.") }
            gift.totalFaceValueCents = product.partialValue
        } else {
            gift.totalFaceValueCents = try GiftCardInput.cents(totalFaceValue, field: "Total face value")
        }
        return gift
    }
}
