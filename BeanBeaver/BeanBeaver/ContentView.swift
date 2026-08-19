import SwiftUI
import VisionKit
import BBReceiptKit

struct ContentView: View {
    @State private var pipeline = ReceiptPipeline()
    @State private var exporter = LedgerExporter()
    /// The pending photo-library import. Owned here rather than by the page that
    /// shows it so backing out of that page doesn't throw the work away, and so
    /// the home button can show what's still waiting.
    @State private var batch = ReceiptBatch()
    @State private var showScanner = false
    /// Also opened by the `-showBatchImport` DEBUG deep-link.
    @State private var showBatchImport = false
    /// Also opened by the `-showSpending` DEBUG deep-link.
    @State private var showSpending = false
    /// Also opened by the `-showReceipts` DEBUG deep-link.
    @State private var showReceipts = false
    @State private var showOriginReceipt = false
    @State private var showSettings = false
    /// Also opened by the `-showLedgerSettings` DEBUG deep-link, so it can be
    /// screenshotted headlessly (previews render only in Xcode).
    @State private var showLedgerSettings = false
    /// DEBUG deep-link: `-showDataDump` opens the data-dump debug screen on
    /// launch so it can be screenshotted headlessly.
    @State private var debugShowDataDump = false
    /// DEBUG deep-link: `-showPrivacy` opens the bundled privacy policy, whose
    /// Markdown rendering is otherwise only checkable by hand in Xcode.
    @State private var debugShowPrivacy = false
    /// DEBUG deep-link: `-showDebugInfoList` opens "Stored Debug Info" on
    /// launch so what `DebugInfoStore` captured can be screenshotted headlessly.
    @State private var debugShowDebugInfoList = false
    @State private var showJSONPreview = false
    /// The Money Manager `.xlsx` awaiting the share sheet — one presentation point
    /// for both the toolbar menu and the result card's menu.
    @State private var moneyManagerShare: ShareFile?
    /// Masks the money figures on the home card and the spending screens when
    /// the user has asked for it — see `AmountPrivacy`.
    @State private var amountPrivacy = AmountPrivacy.shared
    @Environment(\.openURL) private var openURL

    /// Bundled sample receipt (a redacted Costco fixture), offered in Settings so
    /// the app can be tried without a receipt to hand.
    private let sampleName = "costco_20260301_redact"

    /// The result screen has its own toolbar (home + more-options) that
    /// already orients the user, so the "BeanBeaver" title would be redundant
    /// there — unlike the home screen/scanning/failed states, which have no
    /// other chrome.
    private var isDone: Bool {
        if case .done = pipeline.status { return true }
        return false
    }

    private var doneResult: ReceiptResult? {
        if case .done(let result) = pipeline.status { return result }
        return nil
    }

    /// Build the Money Manager `.xlsx` for `results` and present its share sheet.
    /// A failure here is a rare temp-file write error and non-fatal — captured for
    /// support rather than surfaced, matching the ledger exporter's error handling.
    private func presentMoneyManager(for results: [ReceiptResult]) {
        guard Entitlements.shared.isPremium else { return }
        do {
            moneyManagerShare = ShareFile(url: try MoneyManagerExport.makeFile(for: results))
            // Marked at presentation, not confirmed delivery — the share sheet
            // that follows may be cancelled — which is why the row says
            // "Shared", never "Filed".
            SpendStore.shared.markShared(results: results)
        } catch {
            DebugInfoStore.recordExportFailure(context: "Money Manager export",
                                               message: error.localizedDescription)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        switch pipeline.status {
                        case .idle:
                            homeView
                        case .scanning:
                            scanningView
                        case .failed(let message):
                            failedView(message)
                        case .done(let result):
                            ReceiptResultView(result: result, wallMs: pipeline.lastWallMs,
                                              capturedImageURL: pipeline.capturedImageURL,
                                              exporter: exporter,
                                              onConfigure: { showLedgerSettings = true },
                                              onExportMoneyManager: { presentMoneyManager(for: [result]) })
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
#if DEBUG
                    // Screenshot scaffold: with `-expandAccounting`, bring the opened
                    // beancount disclosure to the top of the viewport — its clean
                    // postings, above the raw-text/debug tail below.
                    .onChange(of: isDone) { _, done in
                        guard done,
                              ProcessInfo.processInfo.arguments.contains("-expandAccounting")
                        else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(700))
                            proxy.scrollTo("beancount", anchor: .top)
                        }
                    }
#endif
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isDone ? "" : "BeanBeaver")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.bbAccent)
            .toolbar {
                if isDone {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            pipeline.reset()
                        } label: {
                            Image(systemName: "house")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showOriginReceipt = true
                            } label: {
                                Label("Show Original Receipt", systemImage: "photo")
                            }
                            .disabled(pipeline.capturedImageURL == nil)

                            if let result = doneResult {
                                Section("Export") {
                                    LedgerExportButtons(result: result,
                                                        imageURL: pipeline.capturedImageURL,
                                                        wallMs: pipeline.lastWallMs,
                                                        exporter: exporter,
                                                        onConfigure: { showLedgerSettings = true },
                                                        onViewJSON: { showJSONPreview = true },
                                                        onExportMoneyManager: { presentMoneyManager(for: [result]) })
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                } else {
                    // Settings was a full-width pill in a stack of five, which
                    // made an app preference look like one of the app's main
                    // actions. The nav bar is where iOS users look for it, and
                    // it costs the home screen no vertical space.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $showBatchImport) {
                BatchImportView(batch: batch, exporter: exporter,
                                onConfigure: { showLedgerSettings = true })
            }
            .navigationDestination(isPresented: $showSpending) {
                SpendingView(onScan: { showScanner = true }, exporter: exporter,
                             onConfigure: { showLedgerSettings = true })
            }
            .navigationDestination(isPresented: $showReceipts) {
                ReceiptsView(exporter: exporter, onConfigure: { showLedgerSettings = true })
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerWithHint(
                    onScan: { data in
                        Task { await pipeline.scan(imageData: data) }
                    },
                    onFinish: { showScanner = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showOriginReceipt) {
                OriginReceiptView(imageURL: pipeline.capturedImageURL)
            }
            .sheet(isPresented: $showLedgerSettings) {
                NavigationStack { LedgerSettingsView(exporter: exporter) }
            }
            .sheet(isPresented: $showJSONPreview) {
                if let result = doneResult {
                    ReceiptJSONView(result: result, wallMs: pipeline.lastWallMs)
                }
            }
            .sheet(item: $moneyManagerShare) { share in
                ActivityView(items: [share.url])
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(exporter: exporter) {
                    Task { await pipeline.scanBundledSample(named: sampleName) }
                }
            }
#if DEBUG
            .sheet(isPresented: $debugShowDataDump) {
                NavigationStack { DataDumpView() }
            }
            .sheet(isPresented: $debugShowPrivacy) {
                NavigationStack { PrivacyPolicyView() }
            }
            .sheet(isPresented: $debugShowDebugInfoList) {
                NavigationStack { DebugInfoListView() }
            }
            .task {
                // Lets `simctl launch … -autoRunSample` exercise the pipeline
                // headlessly for screenshots/verification.
                if ProcessInfo.processInfo.arguments.contains("-autoRunSample") {
                    await pipeline.scanBundledSample(named: sampleName)
                }
                // `-showOriginReceipt` (paired with `-autoRunSample`): open the
                // zoomable receipt-review sheet so a headless run can screenshot
                // it — the pinch gesture itself still needs a real finger.
                if ProcessInfo.processInfo.arguments.contains("-showOriginReceipt") {
                    showOriginReceipt = true
                }
                // `-dumpMoneyManager` (paired with `-autoRunSample`): after the
                // sample scan, write its Money Manager `.xlsx` to Documents so a
                // headless `simctl` run can pull and validate the real export end
                // to end — the share sheet can't be driven from a script.
                if ProcessInfo.processInfo.arguments.contains("-dumpMoneyManager"),
                   case .done(let result) = pipeline.status,
                   let src = try? MoneyManagerExport.makeFile(for: [result]) {
                    let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("moneymanager-dump.xlsx")
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: src, to: dest)
                    NSLog("[MoneyManager] dumped export to \(dest.path)")
                }
                if ProcessInfo.processInfo.arguments.contains("-showLedgerSettings") {
                    showLedgerSettings = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showSettings") {
                    showSettings = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showBatchImport") {
                    showBatchImport = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showSpending") {
                    showSpending = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showReceipts") {
                    showReceipts = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showDataDump") {
                    debugShowDataDump = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showPrivacy") {
                    debugShowPrivacy = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showDebugInfoList") {
                    debugShowDebugInfoList = true
                }
                // `-dumpSpend`: every SpendRecord, so the two explicit states
                // (photo, export) and the exclusion flag are greppable rather
                // than eyeballed on a screenshot.
                if ProcessInfo.processInfo.arguments.contains("-dumpSpend") {
                    SpendStore.shared.logState("dump")
                }
                // `-dumpSpending`: each month's arithmetic, by hand-checkable
                // line — the same numbers `SpendingView` renders. `tracked`
                // should land on `receiptTotal`, and every root and leaf is
                // listed so a category total can be checked against the receipt
                // it came from.
                if ProcessInfo.processInfo.arguments.contains("-dumpSpending") {
                    let records = SpendStore.shared.records
                    for id in SpendSummary.monthIds(from: records) {
                        let month = SpendSummary.month(id, from: records)
                        dumpLine("[Spending] \(month.label) | tracked=\(month.tracked) items=\(month.itemsTotal) "
                            + "tax=\(month.tax) receiptTotal=\(month.receiptTotal) "
                            + "receipts=\(month.receiptCount) excluded=\(month.excludedCount) "
                            + "unreadable=\(month.unreadablePriceCount)")
                        for group in month.roots {
                            dumpLine("[Spending]   root \(group.id) \"\(group.label)\"=\(group.amount) "
                                + "(\(group.itemCount) items)")
                            for leaf in group.leaves {
                                dumpLine("[Spending]     leaf \(leaf.label)=\(leaf.amount) (\(leaf.itemCount) items)")
                                // The drill-down's own query, not a re-derivation:
                                // these are the rows `CategoryItemsView` lists, so a
                                // leaf whose entries don't sum to its total is
                                // greppable rather than only visible by tapping.
                                // Grouped by receipt the way the screen groups them,
                                // and the flat sum kept alongside so a grouping that
                                // dropped or double-counted an item shows up as the
                                // two numbers disagreeing.
                                let entries = SpendSummary.items(.leaf(leaf.label), from: month.records)
                                let sum = entries.reduce(0) { $0 + $1.amount }
                                dumpLine("[Spending]       items sum=\(sum) count=\(entries.count)")
                                for group in SpendSummary.receipts(.leaf(leaf.label), from: month.records) {
                                    let merchant: String = group.record.result.merchant
                                    let receiptTotal: String = group.receiptTotal.map { "\($0)" } ?? "unparsed"
                                    let here: Int = group.entries.count
                                    let onReceipt: Int = group.record.result.items.count
                                    dumpLine("[Spending]       receipt \(merchant) share=\(group.amount) "
                                        + "of \(receiptTotal) (\(here) of \(onReceipt) items)")
                                    for entry in group.entries {
                                        let description: String = entry.item.description
                                        dumpLine("[Spending]         · \(description)=\(entry.amount)")
                                    }
                                }
                            }
                        }
                    }
                }
                // `-autoRunBatch`: headless E2E over Documents/batch_in/*.jpg → batch_out.json.
                if BatchRunner.isRequested {
                    await BatchRunner.run()
                }
                // Photo-import batch, headless: `-dumpBatch` logs what came back
                // off disk (run it alone on a second launch to check a parsed
                // batch survived), `-seedPhotoBatch <n>` fills one and parses it.
                if ProcessInfo.processInfo.arguments.contains("-dumpBatch") {
                    batch.logState("loaded")
                }
                if let count = BatchRunner.argValue("-seedPhotoBatch").flatMap(Int.init) {
                    await batch.seedFromBundledSample(count: count)
                }
                if ProcessInfo.processInfo.arguments.contains("-fakeExportProgress") {
                    Task { await exporter.simulateProgress() }
                }
                if ProcessInfo.processInfo.arguments.contains("-discardBatch") {
                    batch.discardAll()
                    batch.logState("after discard")
                }
            }
#endif
            // Headless launch-latency probe (process start → first frame); a no-op
            // unless launched with `-logLaunchTiming`. Not DEBUG-gated so a Release
            // build can be measured against Debug on a real device.
            .task { LaunchTiming.recordFirstFrame() }
        }
        // Outside the NavigationStack on purpose. Attached to the stack's content
        // it anchors to the home screen, so an export started from the pushed batch
        // page tried to present from a covered view and the confirmation arrived
        // seconds late — long after the page had reacted to the export finishing.
        .alert(exporter.result?.title ?? "", isPresented: Binding(
            get: { exporter.result != nil },
            set: { if !$0 { exporter.result = nil } }
        ), presenting: exporter.result) { result in
            if let url = result.openURL {
                Button("Open") { openURL(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result.message)
        }
    }

    // MARK: - Home

    private var homeView: some View {
        VStack(spacing: 20) {
            // The tagline is gone: the trend chart now occupies that vertical
            // space, and the privacy footnote at the bottom says the same thing
            // in the place a footnote belongs.
            spendCard
            receiptsCard

            // Scan and Import side by side: same OCR job, two sources, so they
            // belong in one row rather than stacked as equals with Receipts and
            // Settings. Scan is the only filled button on the screen now, which
            // is what it should always have been — five same-size pills made
            // everything equally important, and "Export: GitHub" was a status
            // readout wearing a button.
            HStack(spacing: 10) {
                if VNDocumentCameraViewController.isSupported {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan", systemImage: "camera.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.bbAccent)
                    .controlSize(.large)
                }

                // A workspace rather than a picker: importing from the library
                // means working through a pile, which wants somewhere to come
                // back to. The camera button beside it stays the one-receipt
                // path. Driven through `navigationDestination` rather than a
                // NavigationLink so the `-showBatchImport` DEBUG deep-link can
                // open it headlessly for screenshots.
                Button {
                    showBatchImport = true
                } label: {
                    VStack(spacing: 2) {
                        // Text, not a Label: the icon plus the word didn't fit
                        // the fixed width below and wrapped "Import" onto two
                        // lines. Scan keeps its icon — it's the primary action
                        // and has the room.
                        Text("Import")
                            .font(.headline)
                        if !batch.isEmpty {
                            Text("\(batch.drafts.count) waiting")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.bbAccent)
                .controlSize(.large)
                // Sized on the *button*, not its label: constraining the label
                // leaves the bordered background to take whatever share the
                // HStack proposes, which made the secondary action nearly as
                // wide as the primary one. Dropped when there's no camera, so
                // Import isn't a narrow button next to empty space.
                .frame(maxWidth: VNDocumentCameraViewController.isSupported ? 124 : .infinity)
            }

            exportCaptionRow

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("Scanned and parsed on your device. Nothing leaves it unless you export.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        .padding(.top, 28)
    }

    /// The current month's tracked spend, right on the home screen — the one
    /// number the app exists to produce, and the way through to `SpendingView`.
    /// A button labelled "Spending" would hide it behind a tap for no gain.
    ///
    /// Hidden until something has been scanned: a card reading `$0.00` is worse
    /// than no card, and a new user's first move is the scanner below anyway.
    /// Which month it shows comes from `SpendSummary.defaultMonthId` — the same
    /// rule `SpendingView` opens on, so the card can't advertise one month and
    /// hand you another.
    @ViewBuilder
    private var spendCard: some View {
        if !SpendStore.shared.records.isEmpty {
            let records = SpendStore.shared.records
            let month = SpendSummary.month(SpendSummary.defaultMonthId(from: records),
                                           from: records)
            // Two sibling buttons, not one nested in the other: an eye laid over
            // the card's own Button loses the hit test to it, so tapping the eye
            // pushed Spending instead of unmasking. Side by side, each owns its
            // taps outright.
            let trend = SpendSummary.trend(from: records)
            VStack(alignment: .leading, spacing: 14) {
                // Two sibling buttons, not one nested in the other: an eye laid
                // over the card's own Button loses the hit test to it, so
                // tapping the eye pushed Spending instead of unmasking. Side by
                // side, each owns its taps outright.
                // Top-aligned so the eye sits in the card's top-right corner
                // rather than floating halfway down beside a 40pt figure.
                HStack(alignment: .top, spacing: 0) {
                    Button {
                        showSpending = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(month.label) · \(month.receiptCount) receipt\(month.receiptCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            // Grown from 28pt: the app is a spending tracker
                            // that happens to scan receipts, so this is the
                            // headline rather than one card among equals. Still
                            // not accent red — red reads as "alert" on a money
                            // figure, and the filled Scan button below stays the
                            // loudest thing on the screen.
                            Text(amountPrivacy.text(PriceFormat.currency(month.tracked)))
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(.primary)
                                .monospacedDigit()

                            // The rolling figure rides along as a second line
                            // rather than replacing the month: the month is the
                            // frame people think in, and 30 days is the truer
                            // reading early in one.
                            Text("\(amountPrivacy.text(PriceFormat.currency(trend.rolling))) in the last 30 days")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    // Always present, not just while masked: it's a toggle now,
                    // so hiding it after a reveal would strand the user with no
                    // way back short of Settings.
                    Button {
                        amountPrivacy.toggle()
                    } label: {
                        Image(systemName: amountPrivacy.hideAmounts ? "eye" : "eye.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(amountPrivacy.hideAmounts ? "Show amounts" : "Hide amounts")
                }

                // Masking hides the line, not just the numbers: its height
                // encodes dollars, so a visible line beside a masked figure
                // would give away exactly what the mask is for.
                if amountPrivacy.isMasked {
                    TrendChart.masked()
                } else {
                    TrendChart(amounts: trend.amounts,
                               leadingLabel: "6 wks ago",
                               trailingLabel: "this week")
                }

                Divider()

                Button {
                    showSpending = true
                } label: {
                    HStack(spacing: 6) {
                        Text(trendDeltaText(trend))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(trend.isFlat ? Color.secondary : Color.bbAccent)
                            .monospacedDigit()
                        Text(trendDeltaCaption(trend))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .bbCard()
        }
    }

    /// The delta figure. Rust rounds to cents, so "no change" is an exact test
    /// rather than an epsilon — and it gets words rather than `↑ $0.00`, which
    /// is what an unrounded float would otherwise have rendered forever.
    private func trendDeltaText(_ trend: SpendTrend) -> String {
        if trend.isFlat { return "No change" }
        let arrow = trend.delta > 0 ? "↑" : "↓"
        return "\(arrow) \(amountPrivacy.text(PriceFormat.currency(abs(trend.delta))))"
    }

    /// What the delta is measured against. Says "so far" because the comparison
    /// is week-to-date against the same span of last week — a partial week
    /// against a whole one would read as a fall every Monday.
    private func trendDeltaCaption(_ trend: SpendTrend) -> String {
        trend.isFlat ? "vs the same point last week" : "vs last week, so far"
    }

    /// The way through to the receipt list, and now the only thing this card
    /// carries.
    ///
    /// It used to hold the backlog row and the sync destination too — three rows
    /// and two pill buttons, which put a ledger chore at the same weight as the
    /// spending above it. Both moved into `exportCaptionRow`, which is one quiet
    /// line above the Scan button. Nothing was dropped: the backlog is still
    /// counted, the export flow is still one tap, and the per-receipt status
    /// dots in `ReceiptsView` are untouched.
    @ViewBuilder
    private var receiptsCard: some View {
        let store = SpendStore.shared
        if !store.records.isEmpty {
            Button {
                showReceipts = true
            } label: {
                HStack {
                    Text("Receipts").font(.headline)
                    Spacer()
                    Text("\(store.records.count)").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .bbCard()
        }
    }

    /// The whole export card, demoted to one caption row above the Scan button.
    ///
    /// The backlog and the sync destination were three rows and two pill
    /// buttons, which gave a ledger chore equal billing with the spending the
    /// app is now about. Nothing is removed: the state is still said, the export
    /// flow is still one tap, and the per-receipt dots in `ReceiptsView` are
    /// untouched. It is just quiet.
    ///
    /// Three states, because the row has to carry the first-run case too — with
    /// the card gone this is the only route to Sync from home, and setting up a
    /// ledger before scanning anything is a real first-run order, one an App
    /// Store reviewer takes.
    @ViewBuilder
    private var exportCaptionRow: some View {
        let store = SpendStore.shared
        let backlog = store.unexportedRecords.count

        Button {
            // A backlog wants the receipts in front of you before a batch goes
            // out; anything else wants the destination page.
            if backlog > 0 { showReceipts = true } else { showLedgerSettings = true }
        } label: {
            HStack(spacing: 8) {
                if backlog > 0 {
                    ExportStatusDot(status: .notExported)
                } else if store.lastExportedAt != nil {
                    ExportStatusDot(status: .exported)
                }

                Text(exportCaptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                Text(backlog > 0 ? "Export" : (exporter.selectedTargetReady ? "Change" : "Set Up"))
                    .font(.caption)
                    .foregroundStyle(Color.bbAccent)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Color.bbAccent)
            }
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// What the caption row says, in the three states it has to cover.
    private var exportCaptionText: String {
        let store = SpendStore.shared
        let backlog = store.unexportedRecords.count
        if backlog > 0 {
            return "\(backlog) receipt\(backlog == 1 ? "" : "s") not yet in your ledger"
        }
        if let last = store.lastExportedAt {
            return "All receipts filed · last export "
                + last.formatted(date: .abbreviated, time: .omitted)
        }
        // Nothing filed and nothing waiting: this is the setup prompt, and the
        // only one on the screen.
        return exporter.selectedTargetReady
            ? "Exports to \(exporter.exportIndicator)"
            : "No export destination yet"
    }


    // MARK: - Scanning

    @State private var pulse = false

    private var scanningView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.bbAccentSoft)
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.15 : 0.9)
                    .opacity(pulse ? 0.4 : 0.9)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.bbAccent)
            }
            Text("Reading your receipt…")
                .font(.title3.bold())

            ProgressView(value: pipeline.scanProgress)
                .tint(Color.bbAccent)
                .frame(maxWidth: 220)
            Text(pipeline.scanStepLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.default, value: pipeline.scanStepLabel)
        }
        .padding(.top, 60)
        .onAppear { pulse = true }
    }

    // MARK: - Failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.bbAccentSoft)
                    .frame(width: 88, height: 88)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.bbAccent)
            }
            Text("Couldn't read that receipt")
                .font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Button {
                pipeline.reset()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.bbAccent)
            .controlSize(.large)
            .padding(.top, 8)

#if DEBUG
            if let url = pipeline.capturedImageURL {
                ShareLink(item: url) {
                    Label("Debug: Export captured image", systemImage: "photo.badge.arrow.down")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
#endif
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
        .bbCard()
    }
}

/// The exact photo the OCR saw, shown on request so a user can verify a scan
/// against the original receipt. Pinch or double-tap to zoom in on fine print —
/// see `ZoomableImageView`.
struct OriginReceiptView: View {
    let imageURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed || imageURL == nil {
                    ContentUnavailableView("No Photo Available", systemImage: "photo")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Original Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: imageURL) {
            guard let imageURL else { return }
            // The capture is a JPEG already on disk; decode it off the main
            // thread so opening the sheet never hitches.
            let decoded = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: imageURL.path)
            }.value
            if let decoded { image = decoded } else { loadFailed = true }
        }
    }
}

/// Per-device ledger output settings that aren't tied to any one exporter:
/// the operating currency and the tax account applied to every generated
/// beancount entry. Configured in `SettingsView`, read by the scan pipeline.
///
/// Per the Sync-vs-Settings rule in CLAUDE.md, these are *cross-cutting* output
/// prefs (they shape the beancount every backend emits), so they live in the
/// general Settings page, not the per-exporter Sync page.
enum LedgerFormatPrefs {
    static let currencyKey = "ledgerCurrency"
    static let taxAccountKey = "ledgerTaxAccount"

    /// Fallbacks used when the locale can't offer a currency and the user
    /// hasn't picked one — matches the app's historical Canadian defaults.
    static let defaultCurrency = "CAD"
    static let defaultTaxAccount = "Expenses:Tax:HST"

    /// The device locale's ISO 4217 currency, if it exposes one.
    static var localeCurrency: String? { Locale.current.currency?.identifier }

    /// Effective operating currency: the user's stored choice, else the device
    /// locale's currency, else `defaultCurrency`. Read at scan time so a change
    /// in Settings takes effect on the next scan.
    static var currency: String {
        let stored = UserDefaults.standard.string(forKey: currencyKey)
        if let stored, !stored.isEmpty { return stored }
        return localeCurrency ?? defaultCurrency
    }

    /// Effective tax account: the user's stored choice, else `defaultTaxAccount`.
    static var taxAccount: String {
        let stored = UserDefaults.standard.string(forKey: taxAccountKey)
        if let stored, !stored.isEmpty { return stored }
        return defaultTaxAccount
    }
}

/// A menu picker over `presets` (each a display title + the value it stores)
/// plus a "Custom…" escape hatch that reveals a free-text field. Binds to a
/// single stored `String` — the value used downstream — so a preset and a
/// hand-typed value are the same setting.
private struct PresetOrCustomPicker: View {
    let title: String
    let presets: [(label: String, value: String)]
    let customPlaceholder: String
    var uppercaseField = false
    @Binding var value: String

    private static let customTag = "\u{0}custom"
    private var isPreset: Bool { presets.contains { $0.value == value } }

    var body: some View {
        Picker(title, selection: Binding(
            get: { isPreset ? value : Self.customTag },
            set: { selected in
                if selected == Self.customTag {
                    if isPreset { value = "" } // start the custom field empty
                } else {
                    value = selected
                }
            }
        )) {
            ForEach(presets, id: \.value) { Text($0.label).tag($0.value) }
            Text("Custom…").tag(Self.customTag)
        }
        if !isPreset {
            TextField(customPlaceholder, text: $value)
                .autocorrectionDisabled()
                .textInputAutocapitalization(uppercaseField ? .characters : .never)
        }
    }
}

struct SettingsView: View {
    /// Whether a `.json` details sidecar is written next to each exported receipt.
    /// Shares its key with `LedgerFileOptions.includeDetailsJSON`, which the
    /// export path reads. Default on.
    @AppStorage("includeDetailsJSON") private var includeDetailsJSON = true
    /// "Store detailed debug info" (Settings › Debug). Off by default — see
    /// `DebugInfoStore` for what turning it on actually keeps around.
    @AppStorage(DebugInfoStore.enabledKey) private var storeDetailedDebugInfo = false
    /// Operating currency for every generated beancount amount. Defaults to the
    /// device locale's currency (falling back to CAD); the picker + pipeline
    /// share `LedgerFormatPrefs`, so this and the scan output stay in step.
    @AppStorage(LedgerFormatPrefs.currencyKey) private var ledgerCurrency =
        LedgerFormatPrefs.localeCurrency ?? LedgerFormatPrefs.defaultCurrency
    /// Account the tax posting lands on (HST/GST/PST/VAT/Sales or a custom
    /// beancount account). Defaults to the historical `Expenses:Tax:HST`.
    @AppStorage(LedgerFormatPrefs.taxAccountKey) private var ledgerTaxAccount =
        LedgerFormatPrefs.defaultTaxAccount
    /// Common tax regimes → their beancount account. "Custom…" (in the picker)
    /// covers anything else, including combined regimes.
    private let taxPresets: [(label: String, value: String)] = [
        (label: "HST (Canada)", value: "Expenses:Tax:HST"),
        (label: "GST", value: "Expenses:Tax:GST"),
        (label: "PST", value: "Expenses:Tax:PST"),
        (label: "VAT", value: "Expenses:Tax:VAT"),
        (label: "Sales tax", value: "Expenses:Tax:Sales"),
    ]
    /// A short common-currency list, with the device locale's own currency
    /// pinned first so it isn't buried under "Custom…".
    private var currencyPresets: [(label: String, value: String)] {
        var codes = ["CAD", "USD", "EUR", "GBP", "AUD", "JPY", "CNY"]
        if let local = LedgerFormatPrefs.localeCurrency, !codes.contains(local) {
            codes.insert(local, at: 0)
        }
        return codes.map { (label: $0, value: $0) }
    }
    /// Only so the promoted Sync group can show its state and push its page.
    var exporter: LedgerExporter
    var onRunSample: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var spendStore = SpendStore.shared
    @State private var amountPrivacy = AmountPrivacy.shared
    @State private var confirmClearAllPhotos = false
    @State private var confirmDeleteAllReceipts = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                // First, above every section header. Where receipts go is the
                // one setting here with a *state* worth reporting, and it used
                // to be reachable only from the home screen's export card —
                // which no longer exists. Its own group rather than a row under
                // "Ledger": it spans beancount and the Money Manager workbook
                // both, and tracking works with none of it configured.
                Section {
                    NavigationLink {
                        LedgerSettingsView(exporter: exporter)
                    } label: {
                        HStack(spacing: 10) {
                            if exporter.selectedTargetReady {
                                ExportStatusDot(status: .exported)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sync")
                                Text(syncSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Where receipts go when you export them: a beancount destination, or the Money Manager workbook. Tracking works with nothing set up here.")
                }

                trackingSection

                Section {
                    PresetOrCustomPicker(
                        title: "Currency",
                        presets: currencyPresets,
                        customPlaceholder: "Currency code (e.g. USD)",
                        uppercaseField: true,
                        value: $ledgerCurrency
                    )
                    PresetOrCustomPicker(
                        title: "Sales tax",
                        presets: taxPresets,
                        customPlaceholder: "Tax account (e.g. Expenses:Tax:GST)",
                        value: $ledgerTaxAccount
                    )
                    Toggle("Save details file", isOn: $includeDetailsJSON)
                } header: {
                    Text("Ledger")
                } footer: {
                    Text("The currency and tax account used in every beancount entry BeanBeaver generates. Currency defaults to your region.\n\nSave details file stores a .json alongside each exported receipt — its items, prices, and category tags — next to the beancount and photo. Applies to both the ledger inbox file and GitHub pull requests.")
                }


                receiptsSection

                Section {
                    Button {
                        // Dismiss first so the home screen's scanning/done
                        // transition is actually visible, not hidden behind
                        // this sheet.
                        dismiss()
                        onRunSample()
                    } label: {
                        Label("Scan a Sample Receipt", systemImage: "doc.text.magnifyingglass")
                    }
                } footer: {
                    Text("Runs the full on-device scan on a receipt bundled with the app — a way to see what BeanBeaver does without a receipt in hand.")
                }

                Section {
                    NavigationLink("Privacy Policy") {
                        PrivacyPolicyView()
                    }
                    NavigationLink("Acknowledgements") {
                        AcknowledgementsView()
                    }
                } footer: {
                    Text("Both ship inside the app, so they're readable offline.")
                }

                versionSection
                feedbackSection

                Section {
                    Toggle("Store detailed debug info", isOn: $storeDetailedDebugInfo)
#if DEBUG
                    NavigationLink("Dump All Data") {
                        DataDumpView()
                    }
#endif
                    NavigationLink("Stored Debug Info") {
                        DebugInfoListView()
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Off by default — keep it that way unless support has told you to turn it on. When enabled, BeanBeaver keeps a full copy of each scanned receipt (merchant, items, prices, the raw OCR text, and the generated ledger entry), plus error detail from failed scans and ledger exports, in a debug log on this device — more than the app normally keeps. The raw OCR text can include anything printed on the receipt. Turn it off again once you're done.")
                }
                .id("debug")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
#if DEBUG
            // Screenshot scaffold: `-scrollToDebug` jumps straight to the
            // Debug section so it can be captured without manual scrolling.
            .task {
                if ProcessInfo.processInfo.arguments.contains("-scrollToDebug") {
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("debug", anchor: .top)
                }
            }
#endif
            }
        }
    }

    /// App marketing version + build number, e.g. "1.0.3 (12)".
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Bottom "About" section: the app build and the pinned beanbeaver-core
    /// (the on-device scan engine) it was compiled against. `BBReceiptCore` is
    /// generated by build-xcframework.sh from the Cargo.lock pin, so it always
    /// matches the framework actually linked.
    private var versionSection: some View {
        Section {
            LabeledContent("BeanBeaver", value: appVersionString)
            LabeledContent("beanbeaver-core",
                           value: "\(BBReceiptCore.version) (\(BBReceiptCore.commit))")
        } header: {
            Text("About")
        } footer: {
            Text("beanbeaver-core is the on-device scanning engine. Include both versions when reporting a scan issue.")
        }
    }

    /// Where to reach the project. Placed directly under About so the two read
    /// as one move: the versions to quote, then somewhere to quote them.
    ///
    /// Built with `if let` rather than a force-unwrap so a typo'd URL drops a
    /// row instead of trapping the app. `Link` hands the URL to the system,
    /// which is what lets iOS open the Discord or Element app when it's
    /// installed and fall back to Safari when it isn't.
    private var feedbackSection: some View {
        Section {
            ForEach(Self.feedbackRooms) { room in
                if let url = URL(string: room.urlString) {
                    Link(destination: url) {
                        Label(room.title, systemImage: room.symbol)
                    }
                }
            }
        } header: {
            Text("Feedback")
        } footer: {
            Text("Questions, bugs, and receipts that came out wrong — whichever room suits you. When it's a scan problem, include the two versions above.")
        }
    }

    /// A room the project can be reached in. A named type, not a tuple: `ForEach`
    /// needs an `id`, and key paths can't address tuple members.
    private struct FeedbackRoom: Identifiable {
        let title: String
        let symbol: String
        let urlString: String
        var id: String { title }
    }

    private static let feedbackRooms: [FeedbackRoom] = [
        FeedbackRoom(title: "Discord", symbol: "bubble.left.and.bubble.right",
                     urlString: "https://discord.gg/qsfS7uUMHQ"),
        FeedbackRoom(title: "Matrix", symbol: "number.square",
                     urlString: "https://matrix.to/#/#beanbeaver:matrix.org"),
    ]

    /// The Sync row's state line: what is configured, and how much has actually
    /// gone out through it.
    private var syncSubtitle: String {
        guard exporter.selectedTargetReady else { return "Not set up" }
        let filed = spendStore.exportedRecords.count
        return filed == 0
            ? exporter.exportIndicator
            : "\(exporter.exportIndicator) · \(filed) filed"
    }

    /// The tracker's own preferences.
    ///
    /// This was the Budget section. The monthly target went with the feature —
    /// see `SpendingView` — leaving the masking switch, which was only ever
    /// filed here because a budget is the other thing that reads as private.
    private var trackingSection: some View {
        Section {
            Toggle("Hide amounts", isOn: $amountPrivacy.hideAmounts)
            NavigationLink {
                ItemRulesView(store: ItemRuleStore.shared)
            } label: {
                Label("Categories & Tags", systemImage: "tag")
            }
        } header: {
            Text("Tracking")
        } footer: {
            Text("How items are sorted into categories, and whether the figures are shown.\n\nHide amounts covers every figure on the home card and the spending screens — and the trend charts, whose shape gives away a month on its own — so a glance at your phone doesn't read your spending. On by default; the eye on the home card and on the Spending screen is this same switch.")
        }
    }

    /// The honest successor to the old "Clear Old Receipts": no heuristic, and
    /// each action says exactly what it keeps. A scanned receipt itself is now
    /// kept until the user removes it — see `SpendStore` — so this is the only
    /// place that storage is freed from.
    private var receiptsSection: some View {
        Section {
            LabeledContent("Receipts recorded", value: "\(spendStore.records.count)")
            LabeledContent("Receipt photos",
                           value: ByteCountFormatter.string(
                               fromByteCount: spendStore.totalPhotoBytes(), countStyle: .file))
            Button {
                confirmClearAllPhotos = true
            } label: {
                Label("Clear All Photos", systemImage: "photo.badge.minus")
            }
            Button(role: .destructive) {
                confirmDeleteAllReceipts = true
            } label: {
                Label("Delete All Receipts", systemImage: "trash")
            }
        } header: {
            Text("Receipts")
        } footer: {
            Text("Clear All Photos frees the space used by every receipt photo — every receipt's parsed data and every budget figure stay exactly as they are. Delete All Receipts removes the parsed data and the photos for every scanned receipt on this device; anything already exported to your ledger is untouched, and originals stay in your photo library.")
        }
        .alert("Clear all photos?", isPresented: $confirmClearAllPhotos) {
            Button("Clear Photos", role: .destructive) { spendStore.clearAllPhotos() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees the space used by every receipt photo. Every receipt's parsed data and every budget figure stay exactly as they are.")
        }
        .alert("Delete all receipts?", isPresented: $confirmDeleteAllReceipts) {
            Button("Delete \(spendStore.records.count) Receipt\(spendStore.records.count == 1 ? "" : "s")",
                   role: .destructive) {
                spendStore.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the parsed data and the photos for every scanned receipt on this device. Anything already exported to your ledger is untouched, and originals stay in your photo library.")
        }
    }
}

// MARK: - Result card

/// The parsed receipt itself — merchant, totals, items, warnings, and the
/// generated beancount. Shared by the single-scan result screen and the batch
/// detail, which differ only in the actions sitting under it: a batch exports as
/// a whole, so its rows have no export button of their own.
struct ReceiptCard: View {
    let result: ReceiptResult
    var wallMs: Double?
    var capturedImageURL: URL?
    @State private var expandAccounting = false

    private var friendlyDate: String? { ReceiptDateFormat.friendly(result.date) }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 16) {
                header
                if !result.items.isEmpty {
                    Divider()
                    itemsList
                }
            }
            .bbCard()

            if !result.warnings.worthShowing.isEmpty {
                warningsBanner
            }

            DisclosureGroup(isExpanded: $expandAccounting) {
                VStack(alignment: .leading, spacing: 12) {
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.merchant.capitalized).font(.title2.bold())
                // A `Suggested` match isn't trusted enough to replace the OCR'd
                // name (that stays in `result.merchant`), so offer the canonical
                // guess quietly in grey rather than silently rewriting it.
                if case .suggested = result.merchantMatch.status,
                   let guess = result.merchantMatch.canonical {
                    Text("Did you mean \(guess.capitalized)?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let friendlyDate {
                    HStack(spacing: 4) {
                        Text(friendlyDate)
                        if result.dateIsPlaceholder {
                            Text("(estimated)")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            if result.subtotal != nil || result.tax != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let subtotal = result.subtotal {
                        subtotalRow("Subtotal", subtotal)
                    }
                    if let tax = result.tax {
                        subtotalRow("Tax", tax)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            HStack {
                Text("Total")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(PriceFormat.display(result.total).text)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.bbAccent)
            }
        }
    }

    private func subtotalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(PriceFormat.display(value).text).monospacedDigit()
        }
    }

    private var itemsList: some View {
        VStack(spacing: 10) {
            ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
                itemRow(item)
            }
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
                .monospacedDigit()
                .font(.subheadline)
                .foregroundStyle(priceDisplay.isNegative ? .green : .primary)
        }
    }

    /// The item's classification, straight from the beanbeaver-internal tags:
    /// the most-specific tag as an accent chip, then the broader tags as quiet
    /// context on the same line. No tags → a plain "Uncategorized".
    @ViewBuilder
    private func tagRow(for item: ReceiptItem) -> some View {
        let display = CategoryDisplay.tagDisplay(for: item.tags)
        if let primary = display.primary {
            HStack(spacing: 8) {
                Text(primary)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.bbAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.bbAccentSoft, in: Capsule())

                if !display.rest.isEmpty {
                    Text(display.rest.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("Uncategorized")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The findings worth reading, each in its own rank's color. The banner as
    /// a whole takes the loudest one — a receipt whose only finding is a
    /// possible missed item shouldn't wear the same red as one that cannot
    /// balance. `.info` findings never reach here: an uncategorized line is
    /// already labelled "Uncategorized" on its own row.
    private var warningsBanner: some View {
        let shown = result.warnings.worthShowing
        let top = shown.highestSeverity ?? .notice
        return VStack(alignment: .leading, spacing: 6) {
            Label(top == .attention ? "Heads up" : "Worth a look", systemImage: top.symbol)
                .font(.subheadline.bold())
                .foregroundStyle(top.tint)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, warning in
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(warning.severity.tint)
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
    @State private var showJSONPreview = false

    var body: some View {
        VStack(spacing: 16) {
            ReceiptCard(result: result, wallMs: wallMs, capturedImageURL: capturedImageURL)

            VStack(spacing: 8) {
                Button {
                    Task { await primaryExport() }
                } label: {
                    ExportButtonLabel(idleLabel: "Export:\(exporter.exportIndicator)", exporter: exporter)
                }
                .buttonStyle(.borderedProminent)
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

extension Phase {
    /// Short row label for the debug timing readout. Names come from the core's
    /// shared `Phase` taxonomy, so they match Android's breakdown verbatim.
    var label: String {
        switch self {
        case .acquire: return "acquire"
        case .encode: return "encode"
        case .decode: return "decode"
        case .prep: return "prep"
        case .detect: return "detect"
        case .classify: return "classify"
        case .recognize: return "recognize"
        case .parse: return "parse"
        case .render: return "render"
        @unknown default: return "?"
        }
    }
}

/// Compact per-stage latency readout under a result, for the real-device test.
/// `wallMs` is the Swift-observed total (incl. decode + FFI); the stage rows are
/// the Rust `ScanTimings` phase spans (decode → prep → detect → … → parse).
/// DEBUG-only diagnostic — never shown in a release build.
struct ScanTimingsView: View {
    let timings: ScanTimings
    var wallMs: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Debug: scan time").font(.caption).foregroundStyle(.secondary)
            if let wallMs { row("total (wall)", wallMs, emphasized: true) }
            // Ordered phase spans straight from the core's shared taxonomy — new
            // phases (e.g. app-side spans) appear here with no change to this view.
            ForEach(Array(timings.spans.enumerated()), id: \.offset) { _, span in
                row(span.phase.label, span.ms)
            }
            row("rust total", timings.totalMs)
            if let wallMs { row("other (wall−Σ)", wallMs - timings.totalMs) }
        }
        .font(.system(.caption2, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ ms: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(Int(ms.rounded())) ms").fontWeight(emphasized ? .bold : .regular)
        }
    }
}

// MARK: - Previews

#if DEBUG
extension ContentView {
    /// Preview/screenshot-only initializer that injects a pinned-status pipeline
    /// so the whole screen renders in any state without running OCR.
    init(previewPipeline: ReceiptPipeline) {
        _pipeline = State(initialValue: previewPipeline)
    }
}

extension ScanTimings {
    /// Plausible on-device stage split for previews/screenshots.
    static let preview = ScanTimings(spans: [
        PhaseSpan(phase: .decode, ms: 12),
        PhaseSpan(phase: .prep, ms: 28),
        PhaseSpan(phase: .detect, ms: 322),
        PhaseSpan(phase: .classify, ms: 41),
        PhaseSpan(phase: .recognize, ms: 408),
        PhaseSpan(phase: .parse, ms: 17),
    ])
}

extension ReceiptResult {
    /// A rich, fully-populated result (mirrors the bundled Costco fixture).
    /// Categories are realistic colon-delimited beancount account paths, as
    /// emitted by the on-device classifier.
    static let previewFull = ReceiptResult(
        merchant: "Costco Wholesale",
        merchantMatch: MerchantMatch(
            raw: "Costco Wholesale", canonical: "Costco Wholesale", status: .exact, score: 1.0),
        date: "2026-02-18",
        dateIsPlaceholder: false,
        total: "$148.73",
        tax: "$9.42",
        subtotal: "$139.31",
        items: [
            ReceiptItem(description: "ORG BANANAS", price: "$2.49", quantity: 1, account: "Expenses:Food:Grocery", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/fruit", display: "Fruit")]),
            ReceiptItem(description: "ROTISSERIE CHICKEN", price: "$4.99", quantity: 1, account: "Expenses:Food:Grocery:PreparedMeal", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/meat", display: "Meat"),
                          .init(path: "grocery/meat/chicken", display: "Chicken"),
                          .init(path: "grocery/prepared_meal", display: "Prepared Meal")]),
            ReceiptItem(description: "KIRKLAND OLIVE OIL 2L", price: "$21.99", quantity: 1, account: "Expenses:Food:Grocery", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/staple", display: "Staple")]),
            ReceiptItem(description: "BATH TISSUE 30 ROLL", price: "$24.99", quantity: 1, account: "Expenses:Home", tags: [.init(path: "household", display: "Household"), .init(path: "household/supply", display: "Supply")]),
            ReceiptItem(description: "GASOLINE REGULAR", price: "$58.40", quantity: 1, account: "Expenses:Driving:Gas", tags: [.init(path: "driving", display: "Driving"), .init(path: "driving/gas", display: "Gas")]),
            ReceiptItem(description: "MYSTERY ITEM", price: "$3.00", quantity: 2, account: nil, tags: []),
        ],
        warnings: [],
        rawText: "",
        imageFilename: "receipt.jpg",
        tenders: [],
        beancount: """
        2026-02-18 * "Costco Wholesale"
          Expenses:Food:Grocery        54.45 USD
          Expenses:Home                24.99 USD
          Expenses:Driving:Gas         58.40 USD
          Expenses:Uncategorized        6.00 USD
          Liabilities:CreditCard     -148.73 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview,
        confidence: FieldConfidences(
            merchant: 1.0, date: 0.98, total: 0.99, itemsCategorized: 0.83, needsReview: false),
        detections: []
    )

    /// A sparse result: no line items, inferred date, parser warnings.
    static let previewMinimal = ReceiptResult(
        merchant: "Corner Cafe",
        merchantMatch: MerchantMatch(
            raw: "Corner Cafe", canonical: nil, status: .unknown, score: 0.0),
        date: nil,
        dateIsPlaceholder: true,
        total: "$6.50",
        tax: nil,
        subtotal: nil,
        items: [],
        warnings: [
            ReceiptWarning(kind: .subtotalMismatch,
                           message: "No line items detected", afterItemIndex: -1),
            ReceiptWarning(kind: .possibleMissedItem,
                           message: "maybe missed item near price 4.99", afterItemIndex: -1),
        ],
        rawText: "",
        imageFilename: "receipt.jpg",
        tenders: [],
        beancount: """
        2026-06-24 * "Corner Cafe"
          Expenses:Uncategorized       6.50 USD
          Liabilities:CreditCard      -6.50 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview,
        confidence: FieldConfidences(
            merchant: 0.2, date: 0.1, total: 0.9, itemsCategorized: 0.0, needsReview: true),
        detections: []
    )

    /// A low-confidence merchant: OCR read "COSCO" and the matcher offers
    /// "Costco" as an uncorroborated suggestion — the display name stays raw and
    /// the guess appears in grey.
    static let previewSuggestedMerchant = ReceiptResult(
        merchant: "Cosco",
        merchantMatch: MerchantMatch(
            raw: "Cosco", canonical: "Costco", status: .suggested, score: 0.83),
        date: "2026-02-18",
        dateIsPlaceholder: false,
        total: "$42.10",
        tax: "$2.68",
        subtotal: "$39.42",
        items: [
            ReceiptItem(description: "PAPER TOWELS", price: "$18.99", quantity: 1, account: "Expenses:Home", tags: [.init(path: "household", display: "Household"), .init(path: "household/supply", display: "Supply")]),
            ReceiptItem(description: "ORG EGGS 24CT", price: "$9.49", quantity: 1, account: "Expenses:Food:Grocery", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/dairy", display: "Dairy")]),
        ],
        warnings: [],
        rawText: "",
        imageFilename: "receipt.jpg",
        tenders: [],
        beancount: """
        2026-02-18 * "Cosco"
          Expenses:Home                18.99 USD
          Expenses:Food:Grocery         9.49 USD
          Liabilities:CreditCard      -42.10 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview,
        confidence: FieldConfidences(
            merchant: 0.83, date: 0.95, total: 0.9, itemsCategorized: 1.0, needsReview: true),
        detections: []
    )
}

#Preview("Result – full") {
    ScrollView { ReceiptResultView(result: .previewFull, wallMs: 816, capturedImageURL: nil, exporter: LedgerExporter()).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Result – minimal") {
    ScrollView { ReceiptResultView(result: .previewMinimal, wallMs: 300, capturedImageURL: nil, exporter: LedgerExporter()).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Result – suggested merchant") {
    ScrollView { ReceiptResultView(result: .previewSuggestedMerchant, wallMs: 640, capturedImageURL: nil, exporter: LedgerExporter()).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Screen – home") {
    ContentView()
}

#Preview("Screen – scanning") {
    ContentView(previewPipeline: .preview(.scanning))
}

#Preview("Screen – done") {
    ContentView(previewPipeline: .preview(.done(.previewFull)))
}

#Preview("Screen – failed") {
    ContentView(previewPipeline: .preview(.failed("Couldn't read this receipt. Try retaking the photo in better light.")))
}
#endif
