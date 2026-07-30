import SwiftUI
import BBReceiptKit

/// Where a month's money went, computed from scanned receipts' *items* rather
/// than their totals (see `SpendSummary`). A spend tracker first: the headline
/// is everything tracked, and the breakdown is every category the classifier
/// reached, largest first. A monthly target is an optional overlay — when
/// `BudgetPrefs.monthlyAmount` is unset, nothing budget-shaped renders at all
/// and the screen is complete without it.
///
/// Read-only over receipts: nothing here edits one, only the target.
struct SpendingView: View {
    /// Opens the scanner — the empty state's action, since a spending screen
    /// reached with nothing scanned has nothing else useful to offer.
    var onScan: () -> Void = {}
    /// Forwarded to `ReceiptsView`, so its bulk-export footer has a working
    /// exporter without owning its own.
    var exporter: LedgerExporter
    var onConfigure: () -> Void = {}

    @State private var store = SpendStore.shared
    @State private var selectedMonthID: String?
    @State private var monthlyAmount: Double? = BudgetPrefs.monthlyAmount
    @State private var showBudgetAmountSheet = false

    /// The root a target applies to, if one is set. Only ever used to decorate
    /// one group — never to decide what the screen counts.
    private var targetRoot: String { BudgetPrefs.root }
    private var monthIDs: [String] { SpendSummary.monthIds(from: store.records) }
    private var currentMonthID: String { SpendSummary.currentMonthId() }
    private var activeMonthID: String {
        selectedMonthID ?? SpendSummary.defaultMonthId(from: store.records)
    }
    private var isCurrentMonth: Bool { activeMonthID == currentMonthID }
    private var summary: SpendSummary.Month {
        SpendSummary.month(activeMonthID, from: store.records)
    }

    var body: some View {
        Group {
            if store.records.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Tracked Yet", systemImage: "chart.bar")
                } description: {
                    Text("Scan a receipt and its items show up here, sorted into categories.")
                } actions: {
                    Button(action: onScan) {
                        Label("Scan a Receipt", systemImage: "camera.viewfinder")
                            .font(.headline)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.bbAccent)
                    .controlSize(.large)
                }
            } else {
                content
            }
        }
        // The screen's name, not the month it happens to be showing — the
        // stepper below says which month, and it can page away from this one.
        .navigationTitle("Spending")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ReceiptsView(exporter: exporter, onConfigure: onConfigure)
                    } label: {
                        Label("All Receipts", systemImage: "list.bullet.rectangle")
                    }
                }
            }
        }
        .tint(.bbAccent)
        .sheet(isPresented: $showBudgetAmountSheet, onDismiss: {
            monthlyAmount = BudgetPrefs.monthlyAmount
        }) {
            BudgetAmountSheet()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                monthStepper
                headline

                ForEach(summary.roots) { group in
                    rootCard(group)
                }

                footerSection

                if monthlyAmount == nil {
                    setBudgetRow
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Month stepper

    private func monthIndex(of id: String) -> Int? { monthIDs.firstIndex(of: id) }

    /// `monthIDs` is newest-first, so "older" moves to a higher index and
    /// "newer" moves to a lower one.
    private var canGoOlder: Bool {
        guard let idx = monthIndex(of: activeMonthID) else { return false }
        return monthIDs.indices.contains(idx + 1)
    }
    private var canGoNewer: Bool {
        guard let idx = monthIndex(of: activeMonthID) else { return false }
        return monthIDs.indices.contains(idx - 1)
    }
    private func goOlder() {
        guard let idx = monthIndex(of: activeMonthID), monthIDs.indices.contains(idx + 1) else { return }
        selectedMonthID = monthIDs[idx + 1]
    }
    private func goNewer() {
        guard let idx = monthIndex(of: activeMonthID), monthIDs.indices.contains(idx - 1) else { return }
        selectedMonthID = monthIDs[idx - 1]
    }

    private var monthStepper: some View {
        HStack {
            Button { goOlder() } label: { Image(systemName: "chevron.left") }
                .disabled(!canGoOlder)
            Spacer()
            Text(summary.label).font(.headline)
            Spacer()
            Button { goNewer() } label: { Image(systemName: "chevron.right") }
                .disabled(!canGoNewer)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Headline

    /// Everything tracked this month, and the way through to the receipts behind
    /// it. The count is the tap target rather than inert text — it's the most
    /// natural place to reach for when you want to see what made up the number.
    private var headline: some View {
        VStack(spacing: 4) {
            Text(PriceFormat.currency(summary.tracked))
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Color.bbAccent)
            Text("tracked spend")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NavigationLink {
                ReceiptsView(monthFilter: activeMonthID, exporter: exporter, onConfigure: onConfigure)
            } label: {
                HStack(spacing: 4) {
                    Text("\(summary.records.count) receipt\(summary.records.count == 1 ? "" : "s")")
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.caption)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Category breakdown

    /// One top-level category: its total, then the leaves beneath it. The group
    /// carrying a monthly target — and only that one — also draws the target's
    /// bar and pace line, so a budget reads as an annotation on the spending
    /// rather than as the point of the screen.
    private func rootCard(_ group: SpendSummary.RootGroup) -> some View {
        let hasTarget = group.id == targetRoot && monthlyAmount != nil
        return VStack(alignment: .leading, spacing: 12) {
            // Header and leaves both drill into the items behind the figure —
            // the question a tapped total actually raises. Selected by raw tag
            // id for a root, by display label for a leaf; see
            // `SpendSummary.Category`.
            NavigationLink {
                CategoryItemsView(category: .root(group.id), title: group.label,
                                  monthID: activeMonthID)
            } label: {
                HStack {
                    Image(systemName: CategoryDisplay.style(for: group.label).icon)
                        .foregroundStyle(Color.bbAccent)
                        .frame(width: 22)
                    Text(group.label)
                        .font(.headline)
                    Spacer()
                    Text(PriceFormat.currency(group.amount))
                        .font(.headline)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if hasTarget, let target = monthlyAmount {
                targetBar(spent: group.amount, target: target)
            }

            if !group.leaves.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.leaves) { leaf in
                        NavigationLink {
                            CategoryItemsView(category: .leaf(leaf.label), title: leaf.label,
                                              monthID: activeMonthID)
                        } label: {
                            leafRow(leaf)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .bbCard()
    }

    /// Leaf bars scale to `summary.maxLeafAmount` — the largest leaf anywhere in
    /// the month — so a bar means the same thing in every card on the screen.
    private func leafRow(_ leaf: SpendSummary.Leaf) -> some View {
        let maxAmount = summary.maxLeafAmount
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(leaf.label)
                    .font(.subheadline)
                Spacer()
                Text(PriceFormat.currency(leaf.amount))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .contentShape(.rect)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.bbAccentSoft)
                    Capsule()
                        .fill(Color.bbAccent)
                        .frame(width: geo.size.width * (maxAmount > 0 ? leaf.amount / maxAmount : 0))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - The optional target

    private func targetBar(spent: Double, target: Double) -> some View {
        let remaining = target - spent
        let fraction = target > 0 ? spent / target : 0
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fraction > 1 ? Color.red : Color.bbAccent)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 10)
            HStack {
                Text(remaining >= 0
                     ? "\(PriceFormat.currency(remaining)) left"
                     : "\(PriceFormat.currency(-remaining)) over")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    showBudgetAmountSheet = true
                } label: {
                    Text("of \(PriceFormat.currency(target))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isCurrentMonth {
                paceLine(spent: spent, target: target)
            }
        }
    }

    /// Spend-to-date against day-of-month — what makes a target actionable
    /// rather than retrospective. Current month only; for a past month the
    /// month's own total is the whole answer.
    private func paceLine(spent: Double, target: Double) -> some View {
        let calendar = Calendar.current
        let now = Date()
        let day = calendar.component(.day, from: now)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let expectedByNow = target * Double(day) / Double(daysInMonth)
        let delta = expectedByNow - spent
        let text = delta >= 0
            ? "day \(day) of \(daysInMonth) · \(PriceFormat.currency(delta)) ahead of pace"
            : "day \(day) of \(daysInMonth) · \(PriceFormat.currency(-delta)) behind pace"
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Offered once, quietly, at the bottom — a target is opt-in and the screen
    /// is complete without one.
    private var setBudgetRow: some View {
        Button {
            showBudgetAmountSheet = true
        } label: {
            HStack {
                Label("Set a Monthly Budget", systemImage: "target")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
        }
        .buttonStyle(.plain)
        .bbCard()
    }

    // MARK: - Reconciliation

    /// How the headline relates to what was actually printed on the receipts.
    /// Stated rather than hidden: `items + tax` should land on `receiptTotal`,
    /// and when it doesn't, the gap gets its own named row and a sentence saying
    /// what it usually is — a scan that missed a discount line will otherwise
    /// look like arithmetic the app got wrong.
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            footerRow("Items", PriceFormat.currency(summary.itemsTotal))
            if summary.tax > 0 {
                footerRow("Tax", PriceFormat.currency(summary.tax))
            }
            footerRow("Receipt total", PriceFormat.currency(summary.receiptTotal))
            if let gap = summary.unaccounted {
                footerRow("Unaccounted", PriceFormat.currency(gap))
                Text("Items and tax don't add up to what the receipts say — usually a discount or a line the scan didn't read.")
                    .font(.caption2)
                    .padding(.top, 2)
            }
            if summary.excludedCount > 0 {
                footerRow("Excluded", "\(summary.excludedCount) receipt\(summary.excludedCount == 1 ? "" : "s")")
            }
            if summary.unreadablePriceCount > 0 {
                footerRow("Unreadable prices", "\(summary.unreadablePriceCount)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .bbCard()
    }

    private func footerRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit() }
    }

}

/// Editor for `BudgetPrefs.monthlyAmount` — the one budget thing `SpendingView`
/// itself changes; which root the target applies to stays a Settings concern
/// (`BudgetPrefs.root`), same store, so the two can't drift.
private struct BudgetAmountSheet: View {
    @State private var text: String = BudgetPrefs.monthlyAmount.map { String(format: "%.2f", $0) } ?? ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $text)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("A monthly target for tracked \(BudgetPrefs.root.capitalized) spend, computed from your scanned receipts' items. Leave blank to track spend with no target.")
                }
            }
            .navigationTitle("Monthly Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        BudgetPrefs.monthlyAmount = Double(text)
                        dismiss()
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Spending") {
    NavigationStack { SpendingView(exporter: LedgerExporter()) }
}
#endif
