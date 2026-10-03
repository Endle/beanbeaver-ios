import SwiftUI
import BBReceiptKit

struct GiftCardTransactionsView: View {
    let source: GiftCardTransactionSource
    let currentReceipt: ReceiptResult
    @State private var store: SpendStore

    init(source: GiftCardTransactionSource, currentReceipt: ReceiptResult, store: SpendStore? = nil) {
        self.source = source; self.currentReceipt = currentReceipt
        _store = State(initialValue: store ?? .shared)
    }

    var body: some View {
        let visits = GiftCardTransactions.visits(source: source, current: currentReceipt, records: store.records)
        List {
            Section {
                switch source {
                case .payment(let gift):
                    Text(gift.issuer ?? "Gift card").font(.headline)
                    Text(gift.printedIdentifier ?? "Identifier unknown").textSelection(.enabled)
                    Text(GiftCardTransactions.canFindOtherVisits(gift)
                         ? "Visits with the same issuer, currency and printed card identifier. Masked identifiers may refer to different cards."
                         : "Only this receipt is shown. A readable issuer, currency and card identifier are needed to find other visits.")
                        .font(.footnote).foregroundStyle(Color.bbInkSecondary)
                case .purchase(let gift):
                    Text(gift.issuer ?? "Gift-card purchase").font(.headline)
                    Text("Individual cards have not been linked to this purchase. Its activation or pack reference cannot identify later payments.")
                        .font(.footnote).foregroundStyle(Color.bbInkSecondary)
                }
            }
            .listRowBackground(Color.bbCardFill)

            Section("Merchant visits (\(visits.count))") {
                ForEach(visits) { visit in
                    NavigationLink {
                        GiftCardVisitDetailView(visit: visit)
                    } label: {
                        GiftCardVisitRow(visit: visit)
                    }
                }
            }
            .listRowBackground(Color.bbCardFill)
            Section {
                Text("Balances are reported after each payment, not live balances. Visits with unknown dates appear last; their order is unknown.")
                    .font(.footnote).foregroundStyle(Color.bbInkSecondary)
            }
            .listRowBackground(Color.bbCardFill)
        }
        .scrollContentBackground(.hidden).background(Color.bbCanvas)
        .navigationTitle("Transactions").navigationBarTitleDisplayMode(.inline)
    }
}

private struct GiftCardVisitRow: View {
    let visit: GiftCardVisit
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(visit.receipt.merchant.capitalized).font(.headline)
                Spacer()
                Text(visit.date ?? "Date unknown").font(.subheadline)
            }
            ForEach(visit.paymentIndices, id: \.self) { index in
                let tender = visit.receipt.tenders[index]
                if let gift = tender.giftCard {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Used: \(gift.currency ?? "Currency unknown") \(tender.amount)")
                        Text("Reported balance: \(GiftCardDisplay.money(gift.remainingBalanceCents, currency: gift.currency))")
                    }
                    .font(.subheadline).foregroundStyle(Color.bbInkSecondary)
                }
            }
            ForEach(visit.purchaseIndices, id: \.self) { index in
                let item = visit.receipt.items[index]
                Text(item.description).font(.subheadline)
                Text("Price paid: \(item.giftCard?.currency ?? "Currency unknown") \(item.price)")
                    .font(.subheadline).foregroundStyle(Color.bbInkSecondary)
            }
        }
        .foregroundStyle(Color.bbInk).padding(.vertical, 4)
    }
}

/// Read-only visit drill-down. Corrections stay on the owning receipt screen.
private struct GiftCardVisitDetailView: View {
    let visit: GiftCardVisit
    @State private var store = SpendStore.shared

    var body: some View {
        if let id = visit.recordID, let record = store.recordsById[id.uuidString] {
            BatchReceiptDetailView(result: visit.receipt, wallMs: record.wallMs,
                                   imageURL: store.photoURL(for: record),
                                   exportedAt: record.exportedAt, exportedTargets: record.exportedTargets)
        } else {
            BatchReceiptDetailView(result: visit.receipt)
        }
    }
}
