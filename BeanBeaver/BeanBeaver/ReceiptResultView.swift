import SwiftUI
import BBReceiptKit

// MARK: - Result card

/// The generated ledger entry and what reconciles it — subtotal, tax, total,
/// and the beancount posting itself.
///
/// **Its own view so the two screens that show it can place it differently.**
/// `BatchReceiptDetailView` keeps it directly under the receipt, where it is the
/// reason you opened the row. The scan result puts it *below* its buttons: what
/// you want immediately after a scan is the next scan or the export, and the
/// posting is reference material you reach for when a figure looks wrong.
///
/// A view rather than a computed property on `ReceiptCard` because the
/// disclosure owns `@State`. Read off a `ReceiptCard` value that is never
/// installed in the hierarchy, that state has nowhere to live and the section
/// closes itself again on the next render.
struct AccountingDetailsCard: View {
    let result: ReceiptResult
    var wallMs: Double?
    var capturedImageURL: URL?
    @State private var expandAccounting = false

    private func subtotalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(PriceFormat.display(value).text).font(.bbMono(13))
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expandAccounting) {
            VStack(alignment: .leading, spacing: 12) {
                if result.subtotal != nil || result.tax != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        if let subtotal = result.subtotal {
                            subtotalRow("Subtotal", subtotal)
                        }
                        if let tax = result.tax {
                            subtotalRow("Tax", tax)
                        }
                        subtotalRow("Total", result.total)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Text(result.beancount)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

#if DEBUG
                ScanTimingsView(timings: result.timings, wallMs: wallMs)
                if let url = capturedImageURL {
                    ShareLink(item: url) {
                        Label("Debug: Export captured image", systemImage: "photo.badge.arrow.down")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
#endif
            }
            .padding(.top, 12)
        } label: {
            Label("Accounting details", systemImage: "text.alignleft")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .tint(.secondary)
        .bbCard()
        .id("beancount")
#if DEBUG
        // Screenshot scaffold: `-expandAccounting` opens the beancount
        // disclosure so a `simctl` capture can show the generated ledger.
        .task {
            if ProcessInfo.processInfo.arguments.contains("-expandAccounting") {
                expandAccounting = true
            }
        }
#endif
    }
}


/// The parsed receipt itself — merchant, totals, items, warnings, and the
/// generated beancount. Shared by the single-scan result screen and the batch
/// detail, which differ only in the actions sitting under it: a batch exports as
/// a whole, so its rows have no export button of their own.
struct ReceiptCard: View {
    let result: ReceiptResult
    var wallMs: Double?
    var capturedImageURL: URL?
    /// Show this many items, then collapse the rest behind a "Show all N items"
    /// control. Nil lists everything.
    ///
    /// **Only the scan result passes one.** There, the card is a *summary* of
    /// what just happened and the actions under it — Scan Another, Export — are
    /// the point; a 30-item Costco run pushed all of them off the screen. A
    /// receipt opened from the list is the opposite: inspecting the items is the
    /// entire reason you tapped it, so `BatchReceiptDetailView` lists them all.
    var collapseItemsAfter: Int?
    /// Draw the sawtooth strip along the card's bottom edge. The scan result's
    /// one torn edge; nothing else on that screen gets one.
    var showsTornEdge = false
    /// Whether the accounting disclosure is drawn inline, under the card. The
    /// scan result turns this off and places `accountingDetails` itself, below
    /// its buttons.
    var includesAccountingDetails = true
    @AppStorage(GiftCardPrefs.enabledKey) private var trackGiftCard = false
    @State private var expandAccounting = false
    @State private var showAllItems = false

    private var friendlyDate: String? { ReceiptDateFormat.friendly(result.date) }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    header
                    if !result.items.isEmpty {
                        Divider()
                        itemsList
                    }
                    taxFootnote
                }
                // Rounded on top only when a tear follows, so the two read as
                // one piece of paper rather than a card with a strip under it.
                .modifier(BBCard(padding: 16,
                                 corners: showsTornEdge
                                     ? .init(topLeading: 20, bottomLeading: 0,
                                             bottomTrailing: 0, topTrailing: 20)
                                     : .init(topLeading: 20, bottomLeading: 20,
                                             bottomTrailing: 20, topTrailing: 20)))

                if showsTornEdge {
                    TornEdge()
                        .fill(Color.bbCardFill)
                        .frame(height: TornEdge.height)
                        .shadow(color: Color.bbCardShadow, radius: 6, y: 4)
                }
            }

            if !result.findings.isEmpty {
                warningsBanner
            }

            if trackGiftCard && GiftCardDetailsCard.hasDetails(result) {
                GiftCardDetailsCard(result: result)
            }

            if includesAccountingDetails {
                AccountingDetailsCard(result: result, wallMs: wallMs,
                                      capturedImageURL: capturedImageURL)
            }
        }
    }

    /// Merchant, when and how many, and the total — one row, so the question
    /// "what did this cost?" is answered without scanning down the card.
    ///
    /// The total is 28pt label colour rather than 32pt accent red. Red is the
    /// tap-me colour here and a receipt total is not an action. Subtotal moved
    /// into "Accounting details" — it reconciles the parse, which is what that
    /// section is for; tax is repeated small at the card's foot, see
    /// `taxFootnote`.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.merchant.capitalized)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.bbInk)
                // A `Suggested` match isn't trusted enough to replace the OCR'd
                // name (that stays in `result.merchant`), so offer the canonical
                // guess quietly in grey rather than silently rewriting it.
                if case .suggested = result.merchantMatch.status,
                   let guess = result.merchantMatch.canonical {
                    Text("Did you mean \(guess.capitalized)?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Mono: this line is entirely a date and a count — labels
                // about numbers, which is the half of the type rule mono owns.
                Text(subheadline)
                    .font(.bbMono(12))
                    .foregroundStyle(Color.bbInkSecondary)
            }
            Spacer(minLength: 8)
            Text(PriceFormat.display(result.total).text)
                .font(.bbMono(28, .semibold))
                .tracking(-1)
                .foregroundStyle(Color.bbInk)
        }
    }

    /// "Mar 1, 2026 · 14 items", dropping either half when there isn't one.
    private var subheadline: String {
        var parts: [String] = []
        if let friendlyDate {
            parts.append(friendlyDate + (result.dateIsPlaceholder ? " (estimated)" : ""))
        }
        if !result.items.isEmpty {
            parts.append("\(result.items.count) item\(result.items.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// Tax, small and quiet at the card's bottom right — where a paper receipt
    /// prints it, and below the items it is charged on.
    ///
    /// Deliberately *not* a promotion of the reconciliation block: subtotal and
    /// total stay in "Accounting details" (see `header`), because those two
    /// exist to check the parse, while tax is a figure people look for on the
    /// receipt itself. One line, secondary ink, mono only on the figure so it
    /// sits under the item prices above it.
    ///
    /// Absent when the parser found no tax — a zero would be a claim, and "no
    /// tax line was read" and "$0.00 of tax" are not the same thing.
    @ViewBuilder
    private var taxFootnote: some View {
        if let tax = result.tax {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text("Tax")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bbInkSecondary)
                Text(PriceFormat.display(tax).text)
                    .font(.bbMono(12))
                    .foregroundStyle(Color.bbInkSecondary)
            }
        }
    }

    /// The items shown, and what is being held back.
    private var itemSplit: (shown: [ReceiptItem], hidden: [ReceiptItem]) {
        guard let limit = collapseItemsAfter, !showAllItems, result.items.count > limit else {
            return (result.items, [])
        }
        return (Array(result.items.prefix(limit)), Array(result.items.dropFirst(limit)))
    }

    private var itemsList: some View {
        let split = itemSplit
        return VStack(spacing: 10) {
            ForEach(Array(split.shown.enumerated()), id: \.offset) { _, item in
                itemRow(item)
            }
            if !split.hidden.isEmpty {
                itemTailRow(split.hidden)
            }
        }
    }

    /// The collapsed tail as a **control, not a caption**.
    ///
    /// A grey "10 more items · $203.05" line reads as a footnote, and footnotes
    /// don't get tapped — which is how a card could hold back two thirds of a
    /// receipt without anyone noticing there was more. Accent label with the
    /// count *in* it, the hidden sum beside it, and a chevron. Same treatment as
    /// the Spending card's leaf tail, so one pattern covers both.
    private func itemTailRow(_ hidden: [ReceiptItem]) -> some View {
        let sum = hidden.reduce(0.0) { $0 + (PriceFormat.value($1.price) ?? 0) }
        return VStack(spacing: 10) {
            // Full-bleed, unlike the gaps between rows: it separates the list
            // from a control rather than one row from the next.
            Rectangle().fill(Color.bbHairline).frame(height: 1)

            Button {
                withAnimation(.snappy) { showAllItems = true }
            } label: {
                HStack(spacing: 8) {
                    Text("Show all \(result.items.count) items")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.bbAccent)
                    Spacer(minLength: 8)
                    Text("+" + PriceFormat.currency(sum))
                        .font(.bbMono(15))
                        .foregroundStyle(Color.bbInkSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.bbAccent)
                }
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func itemRow(_ item: ReceiptItem) -> some View {
        // NOTE: intentionally no leading category icon — tried it, but the
        // per-row icons didn't look good enough to keep for now.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.description.capitalized)
                    .lineLimit(1)
                    .font(.subheadline)
                tagRow(for: item)
            }

            Spacer()

            if item.quantity > 1 {
                Text("×\(item.quantity)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let priceDisplay = PriceFormat.display(item.price)
            Text(priceDisplay.text)
                .font(.bbMono(15))
                .foregroundStyle(priceDisplay.isNegative ? Color.bbImpactText : Color.bbInk)
        }
    }

    /// The item's classification, straight from the beanbeaver-internal tags:
    /// the most-specific tag as an accent chip, then the broader tags as quiet
    /// context on the same line. No tags → a plain "Uncategorized".
    @ViewBuilder
    private func tagRow(for item: ReceiptItem) -> some View {
        let display = CategoryDisplay.tagDisplay(for: item.tags)
        if let primary = display.primary {
            HStack(spacing: 5) {
                // The most specific tag is what the item *is*; the broader ones
                // are where it sits. Same chip shape for both so the row reads
                // as one classification, accent on the first so it is obvious
                // which one is the answer.
                tagChip(primary, accented: true)
                ForEach(display.rest.reversed(), id: \.self) { label in
                    tagChip(label, accented: false)
                }
            }
            .lineLimit(1)
        } else {
            tagChip("Uncategorized", accented: false)
        }
    }

    private func tagChip(_ label: String, accented: Bool) -> some View {
        Text(label)
            .font(.bbMono(10, .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(accented ? Color.bbAccent : Color.bbInkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(accented ? Color.bbAccentSoft : Color.bbInk.opacity(0.06),
                        in: Capsule())
    }

    /// The findings worth reading, each in its own rank's color. The banner as
    /// a whole takes the loudest one — a receipt whose only finding is a
    /// possible missed item shouldn't wear the same red as one that cannot
    /// balance. `.info` findings never reach here: an uncategorized line is
    /// already labelled "Uncategorized" on its own row.
    ///
    /// `result.findings`, not `result.warnings`: a missing date is the app's
    /// own finding rather than one of core's, and it is the only thing saying
    /// so — the header's subheadline simply omits a date it hasn't got.
    private var warningsBanner: some View {
        let shown = result.findings
        let top = shown.highestSeverity ?? .notice
        return VStack(alignment: .leading, spacing: 6) {
            Label(top == .attention ? "Heads up" : "Worth a look", systemImage: top.symbol)
                .font(.subheadline.bold())
                .foregroundStyle(top.tint)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, finding in
                Text(finding.message)
                    .font(.caption)
                    .foregroundStyle(finding.severity.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(top == .attention ? Color.bbAccentSoft : Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The single-scan result screen: the receipt card, plus the actions for the one
/// receipt just scanned.
struct ReceiptResultView: View {
    let result: ReceiptResult
    var wallMs: Double?
    var capturedImageURL: URL?
    var exporter: LedgerExporter
    var onConfigure: () -> Void = {}
    var onExportMoneyManager: () -> Void = {}
    /// Straight back to the camera. The filled button on this screen now, since
    /// the answer to "I just scanned one" is usually "here's the next one".
    var onScanAnother: (() -> Void)?
    @State private var showJSONPreview = false

    /// Four, which is the design's own card. The point is that the actions under
    /// this card stay on screen after a big shop, and four rows plus the tail
    /// control is what fits with them.
    private static let itemsBeforeCollapse = 4

    var body: some View {
        VStack(spacing: 16) {
            // The screen's one torn edge, along the bottom of the receipt
            // itself. Nothing below it gets one — see `ReceiptSlip` for why the
            // effect is spent exactly once per screen.
            ReceiptCard(result: result, wallMs: wallMs,
                        capturedImageURL: capturedImageURL,
                        collapseItemsAfter: Self.itemsBeforeCollapse,
                        showsTornEdge: true,
                        includesAccountingDetails: false)

            VStack(spacing: 8) {
                if let onScanAnother {
                    Button(action: onScanAnother) {
                        Label("Scan Another", systemImage: "camera.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.bbAccent)
                    .controlSize(.large)
                }

                // Tinted when Scan Another is the filled action, so the screen
                // has one primary rather than two. Filled when there is no
                // scanner to go back to (an imported receipt), where export is
                // the only thing left to do.
                //
                // The label says what `primaryExport` will do — export, set up,
                // or unlock — rather than naming a destination the tap may not
                // reach. See `LedgerExporter.exportActionLabel`.
                Group {
                    if onScanAnother == nil {
                        Button {
                            Task { await primaryExport() }
                        } label: {
                            ExportButtonLabel(idleLabel: exporter.exportActionLabel(),
                                              exporter: exporter)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await primaryExport() }
                        } label: {
                            ExportButtonLabel(idleLabel: exporter.exportActionLabel(),
                                              exporter: exporter)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .tint(exporter.exportTint)
                .controlSize(.large)
                // See the batch page's export button: staying enabled keeps the
                // fill and the white spinner legible while it runs.
                .allowsHitTesting(exporter.runningKind == nil)

                // Secondary escape hatch: other configured destinations, Share/Copy,
                // and Export Settings — the primary button above fires the first
                // configured destination directly, no picker in the way. Always
                // shown, even with nothing configured yet, so Share/Copy and
                // Set Up Export… stay reachable.
                Menu {
                    LedgerExportButtons(result: result,
                                        imageURL: capturedImageURL,
                                        wallMs: wallMs,
                                        exporter: exporter,
                                        onConfigure: onConfigure,
                                        onViewJSON: { showJSONPreview = true },
                                        onExportMoneyManager: onExportMoneyManager)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .buttonStyle(BBQuietButtonStyle())
            }

            // Last, under the actions. The ledger posting is reference material
            // you open when a figure looks wrong; what you want immediately
            // after a scan is the next scan or the export.
            AccountingDetailsCard(result: result, wallMs: wallMs,
                                  capturedImageURL: capturedImageURL)
        }
        .sheet(isPresented: $showJSONPreview) {
            ReceiptJSONView(result: result, wallMs: wallMs)
        }
    }

    /// Sends the receipt to the selected target: an append to its ledger
    /// destination, or — for Money Manager — the share-sheet Excel export. Falls
    /// back to opening the Export page when the target isn't ready (destination
    /// unconfigured, or premium locked).
    private func primaryExport() async {
        if let kind = exporter.selectedTarget.ledgerKind {
            guard exporter.destination(for: kind).isConfigured else { onConfigure(); return }
            let entry = LedgerEntry.make(from: result, imageURL: capturedImageURL, wallMs: wallMs)
            await exporter.export([entry], to: kind)
        } else {
            guard Entitlements.shared.isPremium else { onConfigure(); return }
            onExportMoneyManager()
        }
    }
}
