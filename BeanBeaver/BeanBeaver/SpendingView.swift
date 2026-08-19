import SwiftUI
import BBReceiptKit

/// Where a month's money went, computed from scanned receipts' *items* rather
/// than their totals (see `SpendSummary`). A spend tracker first: the headline
/// is everything tracked, and the breakdown is every category the classifier
/// reached, largest first.
///
/// The monthly budget that used to overlay one category is **gone** — target
/// bar, pace line, the "Set a Monthly Budget" row and its editor sheet. A
/// target answers "am I allowed to spend this?", and the product's question is
/// now "what am I spending, and is it climbing?", which the week-over-week card
/// below answers instead. `BudgetPrefs` and the three `spend_*_budget_root`
/// functions behind it are left in place, unused, until Android drops its own
/// budget UI — it pins its own tag, so nothing there breaks meanwhile.
///
/// Read-only over receipts: nothing here edits one.
struct SpendingView: View {
    /// Opens the scanner — the empty state's action, since a spending screen
    /// reached with nothing scanned has nothing else useful to offer.
    var onScan: () -> Void = {}
    /// Forwarded to `ReceiptsView`, so its bulk-export footer has a working
    /// exporter without owning its own.
    var exporter: LedgerExporter
    var onConfigure: () -> Void = {}

    @State private var store = SpendStore.shared
    @State private var amountPrivacy = AmountPrivacy.shared
    @State private var selectedMonthID: String?
    /// Which category the week-over-week chart is trending. Nil is all
    /// spending. View-local and reset on entry, by design — it is a way of
    /// looking at the month, not a preference.
    @State private var trendScope: SpendSummary.Category?
    @State private var showReconciliation = false

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
                // The same single state the home card's eye and the Settings
                // toggle write — three places, one value, so they agree.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        amountPrivacy.toggle()
                    } label: {
                        Label(amountPrivacy.hideAmounts ? "Show Amounts" : "Hide Amounts",
                              systemImage: amountPrivacy.hideAmounts ? "eye" : "eye.slash")
                    }
                }
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
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                monthStepper
                headline

                // Only for the month in progress. The series is six weeks back
                // from *today*, so beside a March total viewed in August it
                // would be answering a question nobody asked — the same reason
                // the old pace line was current-month only.
                if isCurrentMonth {
                    weekOverWeekCard
                }

                ForEach(summary.roots) { group in
                    rootCard(group)
                }

                footerSection
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

    /// This month's unfiled receipts — the same `isExported` split the Receipts
    /// screen's dots and chips draw, scoped to the month on screen.
    private var monthBacklog: Int {
        summary.records.filter { !$0.isExported }.count
    }

    /// Everything tracked this month, and the way through to the receipts behind
    /// it. The count is the tap target rather than inert text — it's the most
    /// natural place to reach for when you want to see what made up the number,
    /// and it's where the month's backlog says so.
    ///
    /// The figure is label colour, not accent: red on a 44pt money total reads
    /// as an alarm, and "tracked spend" is not an alarm. Accent is reserved for
    /// things you can tap — the link below it — and for the trend delta, which
    /// is the one figure here that *is* a signal.
    private var headline: some View {
        VStack(spacing: 4) {
            Text(amountPrivacy.text(PriceFormat.currency(summary.tracked)))
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text("tracked spend")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // The rolling figure beside the month, not instead of it: a month
            // is the frame people budget in, and 30 days is the truer reading
            // of "lately" — most of all on the 2nd, when the month total is a
            // day old. Current month only; for a past month it would be a
            // figure from a different window entirely.
            if isCurrentMonth {
                Text("\(amountPrivacy.text(PriceFormat.currency(allSpendingTrend.rolling))) in the last 30 days")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                ReceiptsView(monthFilter: activeMonthID, exporter: exporter, onConfigure: onConfigure)
            } label: {
                HStack(spacing: 4) {
                    Text("\(summary.records.count) receipt\(summary.records.count == 1 ? "" : "s")")
                    if monthBacklog > 0 {
                        ExportStatusDot(status: .notExported, size: 7)
                            .padding(.leading, 2)
                        Text("\(monthBacklog) not exported")
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.caption)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Week over week

    /// The unscoped series, which the hero's rolling figure reads. Kept separate
    /// from the card's own scoped series so changing a chip can't move the
    /// headline above it.
    private var allSpendingTrend: SpendTrend {
        SpendSummary.trend(from: store.records)
    }

    /// Every scope the chips offer: all spending, then each root with its own
    /// leaves under it.
    ///
    /// Derived from the month on screen rather than from a fixed list, so a
    /// category that only appears once you scan a hardware store appears here
    /// the same day. Nil is "All spending".
    private var trendScopes: [(label: String, scope: SpendSummary.Category?)] {
        var out: [(String, SpendSummary.Category?)] = [("All spending", nil)]
        for root in summary.roots {
            out.append((root.label, .root(root.id)))
            for leaf in root.leaves {
                out.append((leaf.label, .leaf(leaf.label)))
            }
        }
        return out
    }

    private func isSelected(_ scope: SpendSummary.Category?) -> Bool {
        switch (scope, trendScope) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs == rhs
        default: return false
        }
    }

    /// Six weeks of spending, scoped to whichever chip is selected — the card
    /// that replaced "Set a Monthly Budget".
    ///
    /// Scoping is the point rather than a refinement: "am I spending more?" is
    /// a different question for meat than for the total, and a household run
    /// that lands in one week hides a grocery trend inside an all-categories
    /// line. The delta, the mean line and the caption all re-scope with it.
    private var weekOverWeekCard: some View {
        let trend = SpendSummary.trend(trendScope, from: store.records)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Week over week")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(deltaText(trend))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(trend.isFlat ? Color.secondary : Color.bbAccent)
                    .monospacedDigit()
            }

            // Mirrors `ReceiptsView`'s chip row — same metrics, same scroll
            // behaviour — so the two read as one control the app uses twice.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(trendScopes.enumerated()), id: \.offset) { _, entry in
                        let selected = isSelected(entry.scope)
                        Button {
                            trendScope = entry.scope
                        } label: {
                            Text(entry.label)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(selected ? Color.bbAccent : Color(.tertiarySystemFill),
                                            in: Capsule())
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }

            if amountPrivacy.isMasked {
                TrendChart.masked(height: 96)
            } else {
                TrendChart(amounts: trend.amounts,
                           height: 96,
                           mean: trend.mean,
                           leadingLabel: weekStartLabel(trend),
                           trailingLabel: "this week",
                           meanLabel: "avg \(PriceFormat.currency(trend.mean))")
            }

            Text("Pick any category to trend on its own — Meat alone, or Dairy, not just the total.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .bbCard()
    }

    /// The oldest week's start date, as the chart's leading axis label.
    private func weekStartLabel(_ trend: SpendTrend) -> String {
        guard let first = trend.points.first else { return "" }
        var components = DateComponents()
        components.year = Int(first.range.start.year)
        components.month = Int(first.range.start.month)
        components.day = Int(first.range.start.day)
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Rust rounds to cents, so "no change" is an exact test rather than an
    /// epsilon — and it gets words, since `↑ $0.00` is what an unrounded float
    /// would otherwise have rendered forever.
    private func deltaText(_ trend: SpendTrend) -> String {
        if trend.isFlat { return "No change" }
        let arrow = trend.delta > 0 ? "↑" : "↓"
        return "\(arrow) \(amountPrivacy.text(PriceFormat.currency(abs(trend.delta))))"
    }

    // MARK: - Category breakdown

    /// One top-level category: its total, then the leaves beneath it. The group
    /// carrying a monthly target — and only that one — also draws the target's
    /// bar and pace line, so a budget reads as an annotation on the spending
    /// rather than as the point of the screen.
    private func rootCard(_ group: SpendSummary.RootGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text(group.label)
                        .font(.headline)
                    Spacer()
                    Text(amountPrivacy.text(PriceFormat.currency(group.amount)))
                        .font(.headline)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                // Padding before `contentShape` so the padded frame is what gets
                // hit, not just the glyphs: the header's own text band is only
                // ~17pt tall, well under the 44pt touch minimum.
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if !group.leaves.isEmpty {
                // No spacing of its own: each row carries its gap as padding
                // instead, so the space between two leaves is *tappable* and
                // belongs to one of them rather than being a dead band.
                VStack(alignment: .leading, spacing: 0) {
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
    ///
    /// Neutral fill, not accent. Every category on the screen drawn in alarm red
    /// makes the one bar that *is* a judgement — the target bar above, which can
    /// actually go over — indistinguishable from a dozen bars that are just
    /// measurements.
    ///
    /// The whole row is one touch target: label, bar, and the padding around
    /// them. Shaping only the text line (which is what this did) left a ~25pt
    /// strip broken by a dead gap above the bar — a row that looks comfortably
    /// tappable but isn't, on a card where neighbouring rows lead to *different*
    /// categories and a near miss is a wrong answer rather than a no-op.
    private func leafRow(_ leaf: SpendSummary.Leaf) -> some View {
        let maxAmount = summary.maxLeafAmount
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(leaf.label)
                    .font(.subheadline)
                Spacer()
                Text(amountPrivacy.text(PriceFormat.currency(leaf.amount)))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.secondary)
                        .frame(width: geo.size.width * (maxAmount > 0 ? leaf.amount / maxAmount : 0))
                }
            }
            .frame(height: 6)
        }
        .foregroundStyle(.primary)
        // Padding *then* `contentShape`, so the hit region is the padded frame
        // rather than the drawn glyphs and capsules. Replaces the spacing the
        // enclosing stack used to add, so this buys hit area rather than height.
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    // MARK: - Reconciliation

    /// How the headline relates to what was actually printed on the receipts.
    /// Stated rather than hidden: `items + tax` should land on `receiptTotal`,
    /// and when it doesn't, the gap gets its own named row and a sentence saying
    /// what it usually is — a scan that missed a discount line will otherwise
    /// look like arithmetic the app got wrong.
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { showReconciliation.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(reconciliationSummary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(showReconciliation ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showReconciliation {
                reconciliationDetail
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .bbCard()
    }

    /// The one line the card shows closed. Says the same three figures the full
    /// breakdown leads with, so opening it is a request for the *rest* rather
    /// than the only way to learn there is a gap at all.
    private var reconciliationSummary: String {
        var parts = ["Items \(amountPrivacy.text(PriceFormat.currency(summary.itemsTotal)))"]
        if summary.tax > 0 {
            parts.append("tax \(amountPrivacy.text(PriceFormat.currency(summary.tax)))")
        }
        if let gap = summary.unaccounted {
            parts.append("\(amountPrivacy.text(PriceFormat.currency(gap))) unaccounted")
        }
        return parts.joined(separator: " · ")
    }

    private var reconciliationDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            footerRow("Items", amountPrivacy.text(PriceFormat.currency(summary.itemsTotal)))
            if summary.tax > 0 {
                footerRow("Tax", amountPrivacy.text(PriceFormat.currency(summary.tax)))
            }
            footerRow("Receipt total", amountPrivacy.text(PriceFormat.currency(summary.receiptTotal)))
            if let gap = summary.unaccounted {
                footerRow("Unaccounted", amountPrivacy.text(PriceFormat.currency(gap)))
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
    }

    private func footerRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit() }
    }

}

#if DEBUG
#Preview("Spending") {
    NavigationStack { SpendingView(exporter: LedgerExporter()) }
}
#endif
