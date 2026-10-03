import SwiftUI
import BBReceiptKit

enum GiftCardDisplay {
    static func money(_ cents: Int64?, currency: String?) -> String {
        guard let cents else { return "Unknown" }
        return "\(currency ?? "Currency unknown") \(GiftCardInput.amount(cents))"
    }

    static func field(_ name: String) -> String {
        switch name {
        case "issuer": return "Issuer / program"
        case "currency": return "Currency"
        case "printed_identifier", "normalized_identifier": return "Card identifier"
        case "remaining_balance_cents": return "Reported balance"
        case "authorization_reference": return "Authorization reference"
        case "expiry", "expiry_date": return "Expiry"
        case "activation": return "Activation"
        case "reference": return "Activation reference"
        case "reference_label": return "Reference label"
        case "card_count": return "Card count"
        case "denomination_cents": return "Value per card"
        case "total_face_value_cents", "face_value_derived": return "Total face value"
        case "association": return "Association with this item"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Shared by the live scan and saved/batch receipts through ReceiptCard.
struct GiftCardDetailsCard: View {
    let result: ReceiptResult
    @State private var expanded = false

    static func hasDetails(_ result: ReceiptResult) -> Bool {
        result.tenders.contains { $0.giftCard != nil } || result.items.contains { $0.giftCard != nil }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(result.tenders.indices, id: \.self) { index in
                    if let gift = result.tenders[index].giftCard {
                        GiftCardPaymentDetails(tender: result.tenders[index], gift: gift, number: index + 1)
                    }
                }
                ForEach(result.items.indices, id: \.self) { index in
                    if let gift = result.items[index].giftCard {
                        GiftCardPurchaseDetails(item: result.items[index], gift: gift)
                    }
                }
                Text("Use Edit → Review & Fix to correct these receipt details.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        } label: {
            Label("Gift cards", systemImage: "giftcard")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
        }
        .bbCard()
    }
}

struct GiftCardPaymentDetails: View {
    let tender: ReceiptTender
    let gift: GiftCardRedemption
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment \(number) · \(gift.issuer ?? "Gift card")").font(.headline)
            GiftCardDetailRow("Card identifier", gift.printedIdentifier ?? "Unknown")
            GiftCardDetailRow("Amount used", "\(gift.currency ?? "Currency unknown") \(tender.amount)")
            GiftCardDetailRow("Reported balance", GiftCardDisplay.money(gift.remainingBalanceCents, currency: gift.currency))
            GiftCardDetailRow("Authorization", gift.authorizationReference ?? "Unknown")
            GiftCardDetailRow("Expiry", expiry)
            Text("Balance reported after this payment. It is not a live balance.")
                .font(.footnote).foregroundStyle(.secondary)
            GiftCardEvidenceView(evidence: gift.evidence, unresolved: gift.unresolvedFields, corrected: gift.correctedFields)
        }
    }

    private var expiry: String {
        switch gift.expiry {
        case .unknown: return "Unknown"
        case .noExpiry: return "Receipt says no expiry"
        case .printedDate: return gift.expiryDate ?? "Unknown"
        }
    }
}

struct GiftCardPurchaseDetails: View {
    let item: ReceiptItem
    let gift: GiftCardPurchase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.description).font(.headline)
            GiftCardDetailRow("Issuer / program", gift.issuer ?? "Unknown")
            GiftCardDetailRow("Price paid", "\(gift.currency ?? "Currency unknown") \(item.price)")
            GiftCardDetailRow("Activation", gift.activation == .activated ? "Receipt reports activated" : "Unknown")
            GiftCardDetailRow(gift.referenceLabel ?? "Reference", gift.reference ?? "Unknown")
            GiftCardDetailRow("Card count", gift.cardCount.map(String.init) ?? "Unknown")
            GiftCardDetailRow("Value per card", GiftCardDisplay.money(gift.denominationCents, currency: gift.currency))
            GiftCardDetailRow(gift.faceValueDerived ? "Total face value (calculated)" : "Total face value",
                              GiftCardDisplay.money(gift.totalFaceValueCents, currency: gift.currency))
            Text("Activation is reported by the receipt, not verified with the issuer. A pack reference does not identify its individual cards.")
                .font(.footnote).foregroundStyle(.secondary)
            GiftCardEvidenceView(evidence: gift.evidence, unresolved: gift.unresolvedFields, corrected: gift.correctedFields)
        }
    }
}

struct GiftCardDetailRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        } label: { Text(title) }
        .font(.subheadline)
    }
}

/// Original evidence remains distinct from the effective, corrected values.
struct GiftCardEvidenceView: View {
    let evidence: [GiftCardEvidence]
    let unresolved: [String]
    let corrected: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !unresolved.isEmpty {
                Label("Needs review: " + labels(unresolved), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.bbAccent)
            }
            if !corrected.isEmpty {
                Text("Corrected: " + labels(corrected)).foregroundStyle(.secondary)
            }
            if !evidence.isEmpty {
                DisclosureGroup("Original receipt evidence") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(evidence.indices, id: \.self) { index in
                            let entry = evidence[index]
                            VStack(alignment: .leading, spacing: 2) {
                                Text(GiftCardDisplay.field(entry.field)).foregroundStyle(.secondary)
                                Text(entry.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
        }
        .font(.footnote)
    }

    private func labels(_ fields: [String]) -> String {
        var seen = Set<String>()
        return fields.map(GiftCardDisplay.field).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}
