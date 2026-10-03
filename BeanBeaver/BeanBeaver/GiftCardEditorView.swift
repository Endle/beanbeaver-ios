import SwiftUI
import BBReceiptKit

struct GiftCardRedemptionEditor: View {
    let tender: ReceiptTender
    let onApply: (ReceiptTender) -> Void
    @State private var draft: GiftCardRedemptionDraft

    init(tender: ReceiptTender, onApply: @escaping (ReceiptTender) -> Void) {
        self.tender = tender; self.onApply = onApply
        _draft = State(initialValue: GiftCardRedemptionDraft(tender))
    }

    var body: some View {
        GiftCardEditForm(title: "Gift-card payment", apply: { onApply(try draft.applied()) }) {
            Section {
                GiftCardTextField("Issuer / program", text: $draft.issuer)
                GiftCardTextField("Currency", text: $draft.currency)
                GiftCardTextField("Card identifier", text: $draft.identifier)
                GiftCardTextField("Amount used", text: $draft.amount, numeric: true)
                GiftCardTextField("Reported balance", text: $draft.balance, numeric: true)
                GiftCardTextField("Authorization reference", text: $draft.authorization)
            } footer: {
                Text("Keep the visible digits and mask positions as printed. Blank details mean unknown; 0.00 means a reported zero balance. The balance is after this payment.")
            }
            Section("Expiry") {
                Picker("Expiry", selection: $draft.expiry) {
                    Text("Unknown").tag(GiftCardExpiry.unknown)
                    Text("No expiry").tag(GiftCardExpiry.noExpiry)
                    Text("Printed date").tag(GiftCardExpiry.printedDate)
                }
                if draft.expiry == .printedDate {
                    GiftCardTextField("Date as printed", text: $draft.expiryDate)
                }
            }
            if let gift = tender.giftCard {
                Section {
                    GiftCardEvidenceView(evidence: gift.evidence, unresolved: gift.unresolvedFields, corrected: gift.correctedFields)
                }
            }
        }
    }
}

struct GiftCardPurchaseEditor: View {
    let gift: GiftCardPurchase
    let onApply: (GiftCardPurchase) -> Void
    @State private var draft: GiftCardPurchaseDraft

    init(gift: GiftCardPurchase, onApply: @escaping (GiftCardPurchase) -> Void) {
        self.gift = gift; self.onApply = onApply
        _draft = State(initialValue: GiftCardPurchaseDraft(gift))
    }

    var body: some View {
        GiftCardEditForm(title: "Gift-card purchase", apply: { onApply(try draft.applied()) }) {
            Section {
                GiftCardTextField("Issuer / program", text: $draft.issuer)
                GiftCardTextField("Currency", text: $draft.currency)
                Picker("Receipt activation", selection: $draft.activation) {
                    Text("Unknown").tag(GiftCardActivation.unknown)
                    Text("Activated").tag(GiftCardActivation.activated)
                }
                GiftCardTextField("Reference label", text: $draft.referenceLabel)
                GiftCardTextField("Reference", text: $draft.reference)
            } footer: {
                Text("Record only what the receipt reports. Missing activation means unknown. A package reference is not an individual card identifier.")
            }
            Section {
                GiftCardTextField("Card count", text: $draft.count, numeric: true)
                GiftCardTextField("Value per card", text: $draft.denomination, numeric: true)
                Toggle("Calculate total from count × value", isOn: $draft.derived)
                if draft.derived {
                    GiftCardDetailRow("Total face value", calculatedFaceValue)
                } else {
                    GiftCardTextField("Total face value", text: $draft.totalFaceValue, numeric: true)
                }
            } header: {
                Text("Face value")
            } footer: {
                Text("Face value is separate from the price paid. Leave it blank when the receipt does not establish it. Correct the price paid on the Item screen.")
            }
            Section {
                GiftCardEvidenceView(evidence: gift.evidence, unresolved: gift.unresolvedFields, corrected: gift.correctedFields)
            }
        }
    }

    private var calculatedFaceValue: String {
        guard let gift = try? draft.applied() else { return "Enter a valid count and value" }
        return GiftCardDisplay.money(gift.totalFaceValueCents, currency: gift.currency)
    }
}

private struct GiftCardTextField: View {
    let label: String
    @Binding var text: String
    var numeric = false
    init(_ label: String, text: Binding<String>, numeric: Bool = false) {
        self.label = label; _text = text; self.numeric = numeric
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            TextField(numeric ? "Unknown" : label, text: $text, axis: .vertical)
                .keyboardType(numeric ? .decimalPad : .default)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityLabel(label)
        }
    }
}

/// Apply updates only the surrounding receipt draft. The existing receipt Save
/// action remains the one path through Rust validation and durable persistence.
private struct GiftCardEditForm<Content: View>: View {
    let title: String
    let apply: () throws -> Void
    @ViewBuilder let content: () -> Content
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            content()
            Section {
                Text("Apply returns to Review & Fix. Save the receipt there to keep your corrections.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.bbCardFill)
        .scrollContentBackground(.hidden).background(Color.bbCanvas)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    do { try apply(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .alert("Check gift-card details", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
