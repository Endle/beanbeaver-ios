import SwiftUI
import BBReceiptKit

/// What one category total is made of — the receipts behind it, each showing
/// only the items that landed in this category, with the full receipt one tap
/// further on.
///
/// This is the middle rung of the drill-down: a month's total asks "where did it
/// go", a category asks "which items", and only then does a receipt answer
/// "what did that purchase look like".
///
/// Grouped by receipt rather than listed flat because a category total is spread
/// over *purchases* — "$8.42 of this Costco run was dairy" is the shape of the
/// answer, and a flat list buries it by repeating the merchant on every row. The
/// grouping never answers with a whole-receipt total, which would be a figure
/// unrelated to the one tapped: each receipt leads with its **share**, and the
/// receipt's own total sits in the caption as context.
///
/// Scoped to the month it was reached from — an unscoped list would quietly
/// change what the number on the previous screen referred to.
struct CategoryItemsView: View {
    let category: SpendSummary.Category
    /// Shown as the title. Passed in rather than derived, because a root's
    /// display wording lives on `RootGroup.label` while the category itself is
    /// selected by raw tag id — see `SpendSummary.Category`.
    let title: String
    let monthID: String

    @State private var store = SpendStore.shared
    @State private var amountPrivacy = AmountPrivacy.shared

    private var groups: [SpendSummary.ReceiptGroup] {
        let records = store.records.filter { SpendSummary.monthId(for: $0) == monthID }
        return SpendSummary.receipts(category, from: records)
    }

    var body: some View {
        // Read once per render rather than per section: `groups` walks every
        // record in the month, and the summary alone reads it three times.
        let receiptGroups = groups

        List {
            summarySection(receiptGroups)

            ForEach(receiptGroups) { group in
                Section {
                    NavigationLink {
                        BatchReceiptDetailView(result: group.record.result,
                                               wallMs: group.record.wallMs,
                                               imageURL: store.photoURL(for: group.record),
                                               onClearPhoto: { store.clearPhoto(group.record.id) })
                    } label: {
                        receiptRow(group)
                    }
                    ForEach(group.entries) { entry in
                        itemRow(entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if receiptGroups.isEmpty {
                ContentUnavailableView("No Items", systemImage: "tray",
                                       description: Text("Nothing in this category for \(SpendSummary.monthLabel(for: monthID))."))
            }
        }
    }

    // MARK: - Rows

    /// The figure that was tapped, restated with the month it came from:
    /// arriving here should confirm the number, not leave it to be re-added by
    /// eye. A plain row rather than a sticky list header, because the per-receipt
    /// sections below now own that slot.
    @ViewBuilder
    private func summarySection(_ groups: [SpendSummary.ReceiptGroup]) -> some View {
        if !groups.isEmpty {
            let itemCount = groups.reduce(0) { $0 + $1.entries.count }
            let total = groups.reduce(0) { $0 + $1.amount }
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SpendSummary.monthLabel(for: monthID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(itemCount) item\(itemCount == 1 ? "" : "s") in "
                             + "\(groups.count) receipt\(groups.count == 1 ? "" : "s")")
                        Spacer(minLength: 8)
                        Text(amountPrivacy.text(PriceFormat.currency(total))).monospacedDigit()
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// One receipt's share of the category. The share leads — it's what the
    /// previous screen's figure is made of — while the receipt's own total is
    /// context in the caption, per this file's header.
    private func receiptRow(_ group: SpendSummary.ReceiptGroup) -> some View {
        let result = group.record.result
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(result.merchant.capitalized)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                // Same badge `ParsedRow` uses, so a receipt worth a second look
                // is flagged identically wherever it's listed.
                if result.needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.bbAccent)
                }
                Spacer(minLength: 8)
                Text(amountPrivacy.text(PriceFormat.currency(group.amount)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Text(subtitle(group))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Date · how many of the receipt's items landed here · what the whole
    /// receipt came to. Each clause is dropped rather than faked when its source
    /// didn't parse — an unreadable total says nothing instead of "$0.00".
    private func subtitle(_ group: SpendSummary.ReceiptGroup) -> String {
        var parts: [String] = []
        if let date = ReceiptDateFormat.friendly(group.record.result.date) { parts.append(date) }
        let onReceipt = group.record.result.items.count
        parts.append("\(group.entries.count) of \(onReceipt) item\(onReceipt == 1 ? "" : "s")")
        if let total = group.receiptTotal {
            parts.append("\(amountPrivacy.text(PriceFormat.currency(total))) total")
        }
        return parts.joined(separator: " · ")
    }

    /// An item under its receipt. No merchant or date here — the section header
    /// says both once, which is the point of grouping.
    private func itemRow(_ entry: SpendSummary.ItemEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            // `×quantity` in the label, price left as the line amount —
            // the convention `MoneyManagerExport.row` already follows, so
            // multi-quantity lines read the same in both places.
            Text(entry.item.quantity > 1
                 ? "\(entry.item.description) ×\(entry.item.quantity)"
                 : entry.item.description)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(amountPrivacy.text(PriceFormat.display(entry.item.price).text))
                .font(.subheadline)
                .monospacedDigit()
        }
        .padding(.leading, 12)
    }
}
