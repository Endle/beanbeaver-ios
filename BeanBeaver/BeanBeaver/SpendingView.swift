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
/// below answers instead.
///
/// The **per-leaf progress bars are gone too**: a dozen neutral capsules, each
/// measured against the largest leaf anywhere in the month, answering a
/// comparison nobody makes and costing every row a second line. A share
/// percentage in a 30pt column replaced them — see `rootCard`. `BudgetPrefs` and the three `spend_*_budget_root`
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
    /// Which roots have had their leaf tail expanded. View-local and reset on
    /// entry, like `trendScope`: it is a way of looking at the month, not a
    /// preference worth persisting.
    @State private var expandedRoots: Set<String> = []
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
                    // The same control Home's slip carries, and the same single
                    // piece of state the Settings toggle writes.
                    AmountPrivacyEye(size: 17)
                }
            }
        }
        .tint(.bbAccent)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSlip

                // Only for the month in progress. The series is six weeks back
                // from *today*, so beside a March total viewed in August it
                // would be answering a question nobody asked — the same reason
                // the old pace line was current-month only.
                //
                // Behind `SpendSummary.showWeeklyTrend`, which gates this card
                // and Home's together — one flag rather than three comment
                // blocks, which is the point of it.
                if SpendSummary.showWeeklyTrend, isCurrentMonth {
                    weekOverWeekCard
                }

                ForEach(summary.roots) { group in
                    rootCard(group)
                }

                footerSection
            }
            .padding(.horizontal, 16)
            // Same clearance Home uses, and for the same reason: the bar is in
            // the safe area, the raised button is not.
            .padding(.bottom, BBLayout.scanButtonClearance)
        }
        .background(Color.bbCanvas)
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

    /// The month stepper, on the slip's eyebrow line.
    ///
    /// **This is what replaced "tracked spend".** That subhead named the metric,
    /// which is the one thing a spending screen doesn't need to say — the app
    /// tracks, and the 44pt figure above it is obviously money. What a reader
    /// actually can't tell is *which* month and *how many receipts* are behind
    /// it, so the line says that instead, and carries the paging with it rather
    /// than spending another row on a control.
    private var monthStepper: some View {
        HStack(spacing: 10) {
            stepperArrow("chevron.left", enabled: canGoOlder, action: goOlder)
            Spacer(minLength: 0)
            Text("\(summary.label) · \(summary.receiptCount) receipt\(summary.receiptCount == 1 ? "" : "s")")
                .bbEyebrow()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            stepperArrow("chevron.right", enabled: canGoNewer, action: goNewer)
        }
    }

    private func stepperArrow(_ symbol: String,
                              enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                // Tertiary is a non-text token, and a chevron is not text.
                .foregroundStyle(enabled ? Color.bbInkSecondary : Color.bbInkTertiary)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Header slip

    /// This month's unfiled receipts — the same `isExported` split the Receipts
    /// screen's dots and chips draw, scoped to the month on screen.
    private var monthBacklog: Int {
        summary.records.filter { !$0.isExported }.count
    }

    /// The month's total, the window it covers, and the way through to the
    /// receipts behind it.
    ///
    /// Same construction as Home's slip, and deliberately so: two screens whose
    /// headers are built differently read as two apps. Centred here rather than
    /// leading-aligned because this screen's job is the single figure and the
    /// stepper flanking it, while Home's slip has an eye in the corner to hang a
    /// left edge on.
    ///
    /// The figure is ink, not accent: red on a 44pt money total reads as an
    /// alarm, and a month's spending is not an alarm. Accent is kept for things
    /// that can be tapped and for the trend delta, which is the one figure here
    /// that genuinely is a signal.
    private var headerSlip: some View {
        ReceiptSlip {
            VStack(spacing: 12) {
                monthStepper

                DisplayAmount(amount: summary.tracked, size: 44, tracking: -1.5)

                metaLine
            }
        }
    }

    /// One line under the total: what it averages per day, and the month's
    /// backlog if it has one.
    ///
    /// The backlog half is the tap target rather than inert text — "13 unfiled"
    /// is the most natural thing to reach for when you want to see which ones,
    /// and it is the only place on this screen that says so.
    @ViewBuilder
    private var metaLine: some View {
        let facts = SpendSummary.facts(activeMonthID, from: store.records)
        HStack(spacing: 8) {
            Text("\(amountPrivacy.text(PriceFormat.currency(facts.dailyAverage)))/day over \(facts.days) day\(facts.days == 1 ? "" : "s")")

            if monthBacklog > 0 {
                Rectangle()
                    .fill(Color.bbInk.opacity(0.2))
                    .frame(width: 1, height: 11)

                NavigationLink {
                    ReceiptsView(monthFilter: activeMonthID, exporter: exporter,
                                 onConfigure: onConfigure)
                } label: {
                    HStack(spacing: 5) {
                        ExportStatusDot(status: .notExported, size: 7)
                        Text("\(monthBacklog) unfiled")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.bbUnexported)
            }
        }
        .font(.bbMono(12))
        .foregroundStyle(Color.bbInkSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: - Week over week

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
                Text("Week over week").bbEyebrow().lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                TrendDeltaLabel(trend: trend)
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
                                .background(selected ? Color.bbAccent : Color.bbInk.opacity(0.07),
                                            in: Capsule())
                                .foregroundStyle(selected ? Color.white : Color.bbInk)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }

            // Bars, matching Home. A line here and bars there would be two
            // shapes for one series, and the argument for bars is the same on
            // both screens: six weekly buckets are discrete totals, and the
            // newest one is a partial week that a line hides.
            if amountPrivacy.isMasked {
                TrendChart.masked(height: 72)
            } else {
                TrendBars(amounts: trend.amounts, labels: trend.weekLabels, height: 72)

                // The mean, as a caption rather than a dashed rule across the
                // bars. On a line it was a reference to read against; over bars
                // it is one more horizontal edge competing with six of them.
                Text("avg \(amountPrivacy.text(PriceFormat.currency(trend.mean)))/wk")
                    .font(.bbMono(11))
                    .foregroundStyle(Color.bbInkSecondary)
            }

            Text("Pick any category to trend on its own — Meat alone, or Dairy, not just the total.")
                .font(.system(size: 12))
                .foregroundStyle(Color.bbInkSecondary)
        }
        .padding()
        .bbCard()
    }

    // MARK: - Category breakdown

    /// How many leaves a card shows before collapsing the rest.
    ///
    /// Six is the design's own card. It is enough that the long tail of a real
    /// grocery month — a dozen leaves, several of them under a dollar — doesn't
    /// turn one root into a screenful, and few enough that the tail control is
    /// visible without scrolling the card off.
    private static let visibleLeaves = 6

    /// One top-level category: its total, then the leaves beneath it.
    ///
    /// **The per-row progress bars are gone.** Every leaf used to draw a bar
    /// measured against the largest leaf anywhere in the month — a dozen neutral
    /// capsules that answered a question nobody asked (how does Dairy compare to
    /// the single biggest thing you bought?) and cost every row a second line.
    /// What replaced them is a share percentage, which is the comparison people
    /// actually make, in a column that costs 30pt instead of a row.
    private func rootCard(_ group: SpendSummary.RootGroup) -> some View {
        let leaves = group.leaves
        let expanded = expandedRoots.contains(group.id)
        let shown = expanded ? leaves : Array(leaves.prefix(Self.visibleLeaves))
        let hidden = leaves.count - shown.count

        return VStack(spacing: 0) {
            rootRow(group)

            ForEach(shown) { leaf in
                hairline
                NavigationLink {
                    CategoryItemsView(category: .leaf(leaf.label), title: leaf.label,
                                      monthID: activeMonthID)
                } label: {
                    leafRow(leaf, of: group)
                }
                .buttonStyle(.plain)
            }

            if hidden > 0 {
                tailRow(count: hidden,
                        amount: leaves.suffix(hidden).reduce(0) { $0 + $1.amount },
                        root: group.id)
            }
        }
        .bbCard(padding: 0)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.bbHairline)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    /// The card's own header: icon, name, total, share of the month, chevron.
    private func rootRow(_ group: SpendSummary.RootGroup) -> some View {
        NavigationLink {
            CategoryItemsView(category: .root(group.id), title: group.label,
                              monthID: activeMonthID)
        } label: {
            HStack(spacing: 12) {
                // A tinted square rather than a bare glyph: it gives the root
                // rows one shared left edge down the screen, which is what makes
                // a stack of cards read as one list of categories.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.bbAccentSoft)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: CategoryDisplay.style(for: group.label).icon)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.bbAccent)
                    }

                Text(group.label)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.bbInk)

                Spacer(minLength: 8)

                Text(amountPrivacy.text(PriceFormat.currency(group.amount)))
                    .font(.bbMono(17, .semibold))
                    .foregroundStyle(Color.bbInk)

                sharePercent(group.amount, of: summary.tracked)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.bbInkTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            // Padding before `contentShape` so the padded frame is what gets
            // hit, not just the glyphs: the text band alone is well under the
            // 44pt touch minimum.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// A leaf. **Chevron on every row**, so the row reads as the way into its
    /// items rather than as a line in a table that happens to be tappable.
    private func leafRow(_ leaf: SpendSummary.Leaf,
                         of group: SpendSummary.RootGroup) -> some View {
        HStack(spacing: 8) {
            Text(leaf.label)
                .font(.system(size: 16))
                .foregroundStyle(Color.bbInk)

            Spacer(minLength: 8)

            Text(amountPrivacy.text(PriceFormat.currency(leaf.amount)))
                .font(.bbMono(15))
                .foregroundStyle(Color.bbInk)

            // Of its own root, not of the month: "Milk is 31% of Grocery" is the
            // comparison the row sits inside. A share of the month would make
            // every leaf a small number and say nothing about the card.
            sharePercent(leaf.amount, of: group.amount)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.bbInkTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    /// The share column: fixed width and right-aligned, so the percentages line
    /// up down the card whether they are one digit or three.
    ///
    /// Blank while masked. A percentage is not a dollar figure, but `4%` of a
    /// hidden total next to `62%` of it still describes the month, and the point
    /// of the eye is that a glance over your shoulder learns nothing.
    private func sharePercent(_ amount: Double, of total: Double) -> some View {
        Text(amountPrivacy.isMasked || total <= 0
             ? ""
             : "\(Int((amount / total * 100).rounded()))%")
            .font(.bbMono(12))
            .foregroundStyle(Color.bbInkSecondary)
            .frame(width: 30, alignment: .trailing)
    }

    /// The collapsed tail, as a **control rather than a caption**.
    ///
    /// The grey "10 more items · $203.05" line this replaces read as a footnote,
    /// and footnotes don't get tapped. Accent label, the hidden sum beside it,
    /// and a chevron — the same treatment the scan result's "Show all 14 items"
    /// uses, so one pattern covers both places the app collapses a list.
    private func tailRow(count: Int, amount: Double, root: String) -> some View {
        VStack(spacing: 0) {
            // Full-bleed, unlike the row dividers above: it separates the list
            // from a control, not one row from the next.
            Rectangle().fill(Color.bbHairline).frame(height: 1)

            Button {
                withAnimation(.snappy) { _ = expandedRoots.insert(root) }
            } label: {
                HStack(spacing: 8) {
                    Text("Show \(count) more")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.bbAccent)
                    Spacer(minLength: 8)
                    Text(amountPrivacy.text(PriceFormat.currency(amount)))
                        .font(.bbMono(15))
                        .foregroundStyle(Color.bbInkSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.bbAccent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
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
