import SwiftUI
import VisionKit
import BBReceiptKit

/// The home screen: the one number the app exists to produce, the state of the
/// backlog, and the way into everything else.
///
/// # What changed, and why
///
/// This used to be a **launcher** — a card, then five pills, and everything else
/// behind a toolbar button. Two complaints followed from that, and both are
/// answered here rather than by moving things around:
///
/// 1. **The top of the screen was empty.** The month card sat below a large
///    blank band under the nav bar. The header slip now starts at the top of the
///    content area, so the first thing on screen is the total.
/// 2. **There was no bottom navigation.** Spending, Receipts, Import and
///    Settings were all pushes or toolbar buttons off this one screen. Scan and
///    Settings moved into a real tab bar (`RootTabView`), and what is left here
///    is a destinations card — four rows, each saying what is behind it *and*
///    its current count, which a pill never did.
///
/// The nav bar is hidden on this screen deliberately: the slip is the header,
/// and a second empty bar above it would put back the blank band that started
/// this. Pushed screens keep their own bars.
struct HomeView: View {
    var batch: ReceiptBatch
    var exporter: LedgerExporter
    var onOpenSpending: () -> Void
    var onOpenReceipts: () -> Void
    var onOpenImport: () -> Void
    var onOpenSync: () -> Void
    /// The empty state's own Scan button. Nil where the camera isn't available.
    var onScan: (() -> Void)?

    @State private var store = SpendStore.shared
    @State private var amountPrivacy = AmountPrivacy.shared

    private var records: [SpendRecord] { store.records }
    private var monthId: String { SpendSummary.defaultMonthId(from: records) }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if records.isEmpty {
                        emptyState
                    } else {
                        loaded
                    }

                    // Pinned to the bottom of the column rather than floating
                    // under the last card: a footnote that lands mid-screen on
                    // a short list reads as a caption for whatever is above it.
                    Spacer(minLength: 28)
                    privacyFootnote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                // The bar itself is in the safe area, so this only has to keep
                // the footnote out from under the raised Scan button.
                .padding(.bottom, BBLayout.scanButtonClearance)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.bbCanvas)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Loaded

    @ViewBuilder
    private var loaded: some View {
        let month = SpendSummary.month(monthId, from: records)
        let facts = SpendSummary.facts(monthId, from: records)

        headerSlip(month, facts)

        VStack(spacing: 14) {
            if SpendSummary.showWeeklyTrend {
                weeklyCard
            }
            destinationsCard(month)
        }
        .padding(.top, 18)
    }

    /// The slip: the window, the total, and two measured figures.
    ///
    /// **Both figures are things nothing else on the screen carries.** What they
    /// replaced was two lines that said what was already said — "in the last 30
    /// days" differs from the month total only in the first days of a month, and
    /// "vs last week" repeated the chart directly below it.
    ///
    /// A projected "on pace for $3,900" was tried here and **cut**. It is the
    /// only figure on the screen that isn't measured, and it swings wildly for
    /// the first week of every month. What sits in its place is what the same
    /// stretch of last month actually came to, which answers the same question
    /// with a number that already happened.
    private func headerSlip(_ month: SpendSummary.Month,
                            _ facts: SpendMonthFacts) -> some View {
        ReceiptSlip {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 0) {
                    // The window and the count, not the word "Tracked" — the app
                    // tracks, which isn't news. What a reader doesn't know is
                    // *which days* the number below covers.
                    Text("\(facts.window.shortLabel) · \(month.receiptCount) receipt\(month.receiptCount == 1 ? "" : "s")")
                        .bbEyebrow()
                    Spacer(minLength: 8)
                    AmountPrivacyEye()
                        // Cancels the 44pt target's own padding so the glyph
                        // sits in the slip's corner rather than inset from it.
                        .padding(.trailing, -12)
                        .padding(.vertical, -12)
                }

                Button(action: onOpenSpending) {
                    DisplayAmount(amount: month.tracked)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)

                HStack(alignment: .center, spacing: 8) {
                    Text("Avg \(amountPrivacy.text(PriceFormat.currency(facts.dailyAverage)))/day")
                    Rectangle()
                        .fill(Color.bbInk.opacity(0.2))
                        .frame(width: 1, height: 11)
                    Text("\(facts.previousWindow.shortLabel) \(amountPrivacy.text(PriceFormat.currency(facts.previousTotal)))")
                }
                .font(.bbMono(13))
                .foregroundStyle(Color.bbInkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
    }

    // MARK: - Weekly spend

    private var weeklyCard: some View {
        let trend = SpendSummary.trend(from: records)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Weekly spend").bbEyebrow().lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                TrendDeltaLabel(trend: trend)
            }

            // The bars encode dollars in their heights, so masking hides the
            // chart rather than only the figures beside it.
            if amountPrivacy.isMasked {
                TrendChart.masked(height: 62)
            } else {
                TrendBars(amounts: trend.amounts, labels: trend.weekLabels)
            }
        }
        .bbCard()
    }

    // MARK: - Destinations

    /// One card, four rows — where the five pills went.
    ///
    /// A row says what is behind it *and* how much is there, which a pill could
    /// not: "Receipts 22", "20 waiting to export". That count is the reason the
    /// row exists, and it is why Export is a row here rather than a button —
    /// it was a status readout wearing a button before.
    private func destinationsCard(_ month: SpendSummary.Month) -> some View {
        VStack(spacing: 0) {
            destinationRow(title: "Spending",
                           trailing: .init(text: "by category", accented: false),
                           action: onOpenSpending)
            hairline
            destinationRow(title: "Receipts",
                           trailing: .init(text: "\(records.count)", accented: false),
                           action: onOpenReceipts)
            hairline
            exportRow
            hairline
            destinationRow(title: "Import from Photos",
                           trailing: batch.isEmpty
                               ? nil
                               : .init(text: "\(batch.drafts.count) waiting", accented: true),
                           action: onOpenImport)
        }
        .bbCard(padding: 0)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.bbHairline)
            .frame(height: 1)
            // Inset from the leading edge only, the way a grouped list sets a
            // separator: it reads as "these rows are one group" rather than as a
            // rule drawn across a card.
            .padding(.leading, 16)
    }

    private struct RowTrailing {
        let text: String
        let accented: Bool
    }

    private func destinationRow(title: String,
                                leading: AnyView? = nil,
                                trailing: RowTrailing?,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leading { leading }
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.bbInk)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing.text)
                        .font(.bbMono(13))
                        .foregroundStyle(trailing.accented ? Color.bbAccent : Color.bbInkSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.bbInkTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            // Padding *then* `contentShape`, so the hit region is the padded
            // frame rather than the glyphs. A row leading somewhere different
            // from its neighbour makes a near miss a wrong answer, not a no-op.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The backlog row, in the three states it has to carry.
    ///
    /// It is a destination rather than a button because that is what it always
    /// was: "20 waiting to export" is a readout, and the tap is "show me them".
    /// A backlog wants the receipts in front of you before a batch goes out;
    /// anything else wants the destination page.
    private var exportRow: some View {
        let backlog = store.unexportedRecords.count
        let dot: AnyView? = {
            if backlog > 0 { return AnyView(ExportStatusDot(status: .notExported)) }
            if store.lastExportedAt != nil { return AnyView(ExportStatusDot(status: .exported)) }
            return nil
        }()

        return destinationRow(
            title: exportRowTitle,
            leading: dot,
            trailing: .init(text: backlog > 0 ? "Export"
                                : (exporter.selectedTargetReady ? "Change" : "Set Up"),
                            accented: true),
            action: { backlog > 0 ? onOpenReceipts() : onOpenSync() }
        )
    }

    private var exportRowTitle: String {
        let backlog = store.unexportedRecords.count
        if backlog > 0 {
            return "\(backlog) waiting to export"
        }
        if store.lastExportedAt != nil {
            return "All receipts filed"
        }
        // Nothing filed and nothing waiting: the setup prompt, and the only
        // route to Sync from this screen.
        return exporter.selectedTargetReady
            ? "Exports to \(exporter.exportIndicator)"
            : "No export destination yet"
    }

    // MARK: - Empty

    /// Nothing scanned: the slip and the cards are hidden and scanning is the
    /// whole screen. A slip reading `$0.00` over an empty chart is worse than no
    /// slip at all, and the first move is the camera anyway.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.bbAccent)

            Text("Scan your first receipt")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.bbInk)

            Text("Its items are read, sorted into categories, and added to the month — on this phone.")
                .font(.system(size: 15))
                .foregroundStyle(Color.bbInkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let onScan {
                Button(action: onScan) {
                    Label("Scan a Receipt", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.bbAccent)
                .controlSize(.large)
                .padding(.top, 4)
            }

            Button(action: onOpenImport) {
                Text(batch.isEmpty ? "Import from Photos"
                                   : "Import from Photos · \(batch.drafts.count) waiting")
                    .font(.subheadline)
                    .foregroundStyle(Color.bbAccent)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }

    private var privacyFootnote: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
            Text("Scanned and parsed on your device. Nothing leaves it unless you export.")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.bbInkSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
    }
}
