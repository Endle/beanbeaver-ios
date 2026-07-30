import SwiftUI
import BBReceiptKit

/// What one category total is made of — the items behind it, each showing the
/// receipt it came from, with that receipt one tap further on.
///
/// This is the middle rung of the drill-down: a month's total asks "where did it
/// go", a category asks "which items", and only then does a receipt answer
/// "what did that purchase look like". Going straight from a category to a
/// receipt list would skip the rung that was actually asked about and answer
/// with whole-receipt totals unrelated to the figure tapped.
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

    private var entries: [SpendSummary.ItemEntry] {
        let records = store.records.filter { SpendSummary.monthId(for: $0) == monthID }
        return SpendSummary.items(category, from: records)
    }

    private var total: Double {
        entries.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink {
                        BatchReceiptDetailView(result: entry.record.result,
                                               wallMs: entry.record.wallMs,
                                               imageURL: store.photoURL(for: entry.record),
                                               onClearPhoto: { store.clearPhoto(entry.record.id) })
                    } label: {
                        row(entry)
                    }
                }
            } header: {
                // The figure that was tapped, restated with the month it came
                // from: arriving here should confirm the number, not leave it to
                // be re-added by eye.
                VStack(alignment: .leading, spacing: 2) {
                    Text(SpendSummary.monthLabel(for: monthID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("\(entries.count) item\(entries.count == 1 ? "" : "s")")
                        Spacer()
                        Text(PriceFormat.currency(total)).monospacedDigit()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                }
                .textCase(nil)
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Items", systemImage: "tray",
                                       description: Text("Nothing in this category for \(SpendSummary.monthLabel(for: monthID))."))
            }
        }
    }

    private func row(_ entry: SpendSummary.ItemEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
                Text(PriceFormat.display(entry.item.price).text)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                Text(entry.record.result.merchant)
                if let date = ReceiptDateFormat.friendly(entry.record.result.date) {
                    Text("·")
                    Text(date)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
