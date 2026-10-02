import SwiftUI
import BBReceiptKit

struct ItemsView: View {
    @State private var store = SpendStore.shared
    @State private var query = ""

    var body: some View {
        let histories = store.itemHistories.filter { $0.matches(query) }
        List {
            Section {
                Text("What you paid, from saved receipts. Amounts are as printed, before separate discounts. Compare matching package sizes, currencies and tax treatment.")
                    .font(.footnote).foregroundStyle(Color.bbInkSecondary)
            }
            ForEach(histories, id: \.historyID) { history in
                NavigationLink {
                    ItemHistoryView(historyID: history.historyID)
                } label: {
                    HistoryListRow(history: history)
                }
                .listRowBackground(Color.bbCardFill)
            }
            if histories.isEmpty {
                Text(query.isEmpty ? "Scan a receipt to start your item history." : "No matching items.")
                    .foregroundStyle(Color.bbInkSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bbCanvas)
        .navigationTitle("Items")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Name, code or merchant")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Undo last item change", action: store.undoHistoryChange)
                        .disabled(store.previousHistoryLinks == nil)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) { AmountPrivacyEye() }
        }
    }
}

private struct HistoryListRow: View {
    let history: SpendItemHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(history.name).foregroundStyle(Color.bbInk)
            Text(history.merchants.map(\.merchant).joined(separator: " · "))
                .font(.subheadline).foregroundStyle(Color.bbInkSecondary)
            Text(history.purchaseCountLabel)
                .font(.caption).foregroundStyle(Color.bbInkSecondary)
        }
        .padding(.vertical, 3)
    }
}

private struct ItemHistoryView: View {
    @State private var historyID: HistoryID
    @State private var store = SpendStore.shared
    @State private var privacy = AmountPrivacy.shared
    @State private var showRename = false
    @State private var name = ""
    @State private var showLink = false
    @Environment(\.dismiss) private var dismiss

    init(historyID: HistoryID) {
        _historyID = State(initialValue: historyID)
    }

    var body: some View {
        if let history = store.itemHistories.first(where: { $0.historyID == historyID }) {
            let occasions = history.purchaseOccasions
            List {
                Section {
                    Text("Amounts as printed, before separate discounts. Package size, currency and tax treatment must match to compare prices.")
                        .font(.footnote).foregroundStyle(Color.bbInkSecondary)
                }
                ForEach(history.merchants, id: \.merchant) { merchant in
                    Section(merchant.merchant) {
                        merchantSummary(merchant, occasions: occasions.filter {
                            $0.lines.first?.merchant == merchant.merchant
                        })
                    }
                    .listRowBackground(Color.bbCardFill)
                }
                Section("Purchases") {
                    ForEach(occasions) { occasion in
                        if let record = store.recordsById[occasion.id] {
                            NavigationLink {
                                BatchReceiptDetailView(result: record.result, wallMs: record.wallMs,
                                                       imageURL: store.photoURL(for: record),
                                                       exportedAt: record.exportedAt,
                                                       exportedTargets: record.exportedTargets,
                                                       onClearPhoto: { store.clearPhoto(record.id) },
                                                       onSaveEdits: { store.updateResult(record.id, to: $0) })
                            } label: { purchaseRow(occasion) }
                        } else {
                            purchaseRow(occasion)
                        }
                    }
                    .listRowBackground(Color.bbCardFill)
                }
                Section {
                    Button("Rename item") { name = history.name; showRename = true }
                    Button("Link same item…") { showLink = true }
                    if history.productID != nil {
                        Button("Reset grouping and name") {
                            store.resetHistory(history)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bbCanvas)
            .navigationTitle(history.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AmountPrivacyEye() } }
            .alert("Rename item", isPresented: $showRename) {
                TextField("Item name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    historyID = store.linkHistory(history, name: name)
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sheet(isPresented: $showLink) {
                NavigationStack {
                    LinkItemView(history: history) { other in
                        historyID = store.linkHistory(history, with: other, name: history.name)
                        showLink = false
                    }
                }
            }
        } else {
            ContentUnavailableView("Item no longer available", systemImage: "basket",
                                   description: Text("Its receipts or grouping changed. Return to Items to see the current history."))
        }
    }

    private func money(_ value: Double?) -> String {
        value.map { privacy.text(PriceFormat.currency($0)) } ?? "Amount unreadable"
    }

    @ViewBuilder
    private func merchantSummary(_ merchant: SpendMerchantPrices, occasions: [HistoryPurchaseOccasion]) -> some View {
        if occasions.count == 1 {
            Text("One purchase so far")
                .foregroundStyle(Color.bbInkSecondary)
        } else if HistoryPurchaseOccasion.pricedReceiptCount(in: occasions) < 2 {
            Text("Not enough prices to compare")
                .foregroundStyle(Color.bbInkSecondary)
        } else {
            switch merchant.pricing {
            case .steady:
                LabeledContent("Typical unit price", value: money(merchant.typical))
                if let latest = merchant.latest {
                    LabeledContent("Latest · \(latest.purchaseDateLabel)", value: money(latest.unitPrice))
                }
            case .varies:
                Text("Amounts vary — no price trend")
                    .foregroundStyle(Color.bbInkSecondary)
            case .single:
                Text("Not enough prices to compare")
                    .foregroundStyle(Color.bbInkSecondary)
            }
            if merchant.pricing != .single {
                LabeledContent("Lowest unit amount", value: money(merchant.lowest))
                LabeledContent("Highest unit amount", value: money(merchant.highest))
            }
        }
    }

    private func purchaseRow(_ occasion: HistoryPurchaseOccasion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let purchase = occasion.lines.first {
                Text("\(purchase.merchant) · \(purchase.purchaseDateLabel)")
                    .font(.caption).foregroundStyle(Color.bbInkSecondary)
            }
            ForEach(occasion.lines, id: \.purchaseID) { purchase in
                Text(purchase.description).foregroundStyle(Color.bbInk)
                Text("Line amount: \(money(purchase.amount))")
                    .font(.bbMono(14)).foregroundStyle(Color.bbInk)
                if purchase.basis != .assumed {
                    Text("\(purchase.units) × \(money(purchase.unitPrice)) · \(purchase.basis == .inferred ? "inferred quantity" : "recorded quantity")")
                        .font(.caption).foregroundStyle(Color.bbInkSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LinkItemView: View {
    let history: SpendItemHistory
    let onLink: (SpendItemHistory) -> Void
    @State private var store = SpendStore.shared
    @State private var query = ""
    @State private var candidate: SpendItemHistory?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Choose the same product and package size. Each merchant keeps its own prices. You can undo this from Items.")
                    .font(.footnote).foregroundStyle(Color.bbInkSecondary)
            }
            ForEach(store.itemHistories.filter { $0.historyID != history.historyID && $0.matches(query) }, id: \.historyID) { other in
                Button { candidate = other } label: { HistoryListRow(history: other) }
            }
        }
        .navigationTitle("Link same item")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Name, code or merchant")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .alert("Link these items?", isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } })) {
            Button("Cancel", role: .cancel) { candidate = nil }
            Button("Link") { if let candidate { onLink(candidate) } }
        } message: {
            Text("\(history.name) and \(candidate?.name ?? "") will share one history. Confirm that they are the same product and package size.")
        }
    }
}
