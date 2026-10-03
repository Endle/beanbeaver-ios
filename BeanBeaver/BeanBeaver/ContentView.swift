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
    /// Which tab is showing. `Scan` is never one of these for longer than a tap
    /// — see `tabSelection`.
    @State private var tab: RootTab = .home
    /// Also opened by the `-showBatchImport` DEBUG deep-link.
    @State private var showBatchImport = false
    /// Also opened by the `-showSpending` DEBUG deep-link.
    @State private var showSpending = false
    /// Also opened by the `-showReceipts` DEBUG deep-link.
    @State private var showReceipts = false
    @State private var showItems = false
    @AppStorage(PriceHistoryPrefs.enabledKey) private var priceHistoryEnabled = false
    @State private var showLedgerSettings = false
    /// One sheet at a time, attached to the result cover that owns it.
    private enum ResultSheet: Identifiable {
        case editor, original, settings, json, share(URL)
        var id: String {
            switch self {
            case .editor: return "editor"
            case .original: return "original"
            case .settings: return "settings"
            case .json: return "json"
            case .share(let url): return url.absoluteString
            }
        }
    }
    @State private var resultSheet: ResultSheet?
    /// DEBUG deep-link: `-showDataDump` opens the data-dump debug screen on
    /// launch so it can be screenshotted headlessly.
    @State private var debugShowDataDump = false
    /// DEBUG deep-link: `-showPrivacy` opens the bundled privacy policy, whose
    /// Markdown rendering is otherwise only checkable by hand in Xcode.
    @State private var debugShowPrivacy = false
    /// DEBUG deep-link: `-showDebugInfoList` opens "Stored Debug Info" on
    /// launch so what `DebugInfoStore` captured can be screenshotted headlessly.
    @State private var debugShowDebugInfoList = false
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

    private var isScanning: Bool {
        if case .scanning = pipeline.status { return true }
        return false
    }

    /// Build the Money Manager `.xlsx` for `results` and present its share sheet.
    /// A failure here is a rare temp-file write error and non-fatal — captured for
    /// support rather than surfaced, matching the ledger exporter's error handling.
    private func presentMoneyManager(for results: [ReceiptResult]) {
        guard Entitlements.shared.isPremium else { return }
        do {
            resultSheet = .share(try MoneyManagerExport.makeFile(for: results))
            // Marked at presentation, not confirmed delivery — the share sheet
            // that follows may be cancelled — which is why the row says
            // "Shared", never "Filed".
            SpendStore.shared.markShared(results: results)
        } catch {
            DebugInfoStore.recordExportFailure(context: "Money Manager export",
                                               message: error.localizedDescription)
        }
    }

    /// Whether the scan pipeline has anything to show. Drives the result
    /// modal, which covers the tab bar: a scan result is the outcome of an
    /// action, not a place you navigate to.
    private var pipelineIsActive: Bool {
        if case .idle = pipeline.status { return false }
        return true
    }

    /// Tab selection, with `Scan` intercepted.
    ///
    /// Scan is an **action wearing a tab item**: tapping it opens the camera and
    /// leaves you on the tab you were already on, so there is no empty "Scan
    /// screen" to come back to and no state to restore. The raised button in
    /// `RootTabBarAction` does the same thing; both go through here so they
    /// cannot drift.
    private var tabSelection: Binding<RootTab> {
        Binding(get: { tab },
                set: { selected in
                    if selected == .scan {
                        showScanner = true
                    } else {
                        tab = selected
                    }
                })
    }

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack {
                HomeView(batch: batch,
                         exporter: exporter,
                         onOpenSpending: { showSpending = true },
                         onOpenReceipts: { showReceipts = true },
                         onOpenItems: { showItems = priceHistoryEnabled },
                         onOpenImport: { showBatchImport = true },
                         onOpenSync: { showLedgerSettings = true },
                         onScan: VNDocumentCameraViewController.isSupported
                             ? { showScanner = true } : nil)
                    .navigationDestination(isPresented: $showBatchImport) {
                        BatchImportView(batch: batch, exporter: exporter,
                                        onConfigure: { showLedgerSettings = true })
                    }
                    .navigationDestination(isPresented: $showSpending) {
                        SpendingView(onScan: { showScanner = true }, exporter: exporter,
                                     onConfigure: { showLedgerSettings = true })
                    }
                    .navigationDestination(isPresented: $showItems) {
                        if priceHistoryEnabled { ItemsView() }
                    }
                    .navigationDestination(isPresented: $showReceipts) {
                        ReceiptsView(exporter: exporter, onConfigure: { showLedgerSettings = true })
                    }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(RootTab.home)

            // Never actually shown — `tabSelection` turns a tap here into the
            // camera. It exists so the platform lays out three slots and puts
            // the middle one under the raised button.
            //
            // **Label only, no icon.** The raised circle covers this slot's
            // glyph, and `camera.viewfinder` is wide enough that its lower
            // brackets poked out from under the circle — which reads as a
            // rendering fault, not a design. With no image the platform centres
            // the word under the circle, which is where the design puts it.
            Color.bbCanvas
                .ignoresSafeArea()
                .tabItem { Text("Scan") }
                .tag(RootTab.scan)

            SettingsView(exporter: exporter, showsDone: false) {
                Task { await pipeline.scanBundledSample(named: sampleName) }
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(RootTab.settings)
        }
        .safeAreaInset(edge: .top) { storageNotices }
        .tint(.bbAccent)
        .onChange(of: priceHistoryEnabled) { _, enabled in
            if !enabled { showItems = false }
        }
        .overlay(alignment: .bottom) {
            RootTabBarAction { showScanner = true }
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
        // The scan result, over the tab bar. Dismissing it *is* resetting the
        // pipeline — one piece of state, so a swipe-down and a `Done` tap can't
        // leave the app showing a result it thinks it has already cleared.
        .fullScreenCover(isPresented: Binding(
            get: { pipelineIsActive },
            set: { if !$0 { pipeline.reset() } }
        )) {
            scanOutcome
                // Same reason the Done button is withheld: an interactive
                // dismissal mid-scan would leave the finished result to present
                // itself unbidden.
                .interactiveDismissDisabled(isScanning)
                .sheet(item: $resultSheet) { sheet in
                    resultPresentation(sheet)
                }

        }
        .sheet(isPresented: $showLedgerSettings) {
            NavigationStack { LedgerSettingsView(exporter: exporter) }
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
        .task { await runDebugDeepLinks() }
#endif
        // Headless launch-latency probe (process start → first frame); a no-op
        // unless launched with `-logLaunchTiming`. Not DEBUG-gated so a Release
        // build can be measured against Debug on a real device.
        .task { LaunchTiming.recordFirstFrame() }
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

    private var storageNotices: some View {
        VStack(spacing: 0) {
            StorageIssueView(message: SpendStore.shared.storageIssue) { SpendStore.shared.retryPersistence() }
            StorageIssueView(message: batch.storageIssue) { batch.retryPersistence() }
            StorageIssueView(message: ItemRuleStore.shared.storageIssue) { ItemRuleStore.shared.retryPersistence() }
        }
    }

    @ViewBuilder
    private func resultPresentation(_ sheet: ResultSheet) -> some View {
        switch sheet {
        case .editor:
            if let result = doneResult {
                ReceiptEditorView(original: result, imageURL: pipeline.capturedImageURL) { edited in
                    pipeline.replaceResult(with: edited)
                }
            }
        case .original:
            OriginReceiptView(imageURL: pipeline.capturedImageURL)
        case .settings:
            NavigationStack { LedgerSettingsView(exporter: exporter) }
        case .json:
            if let result = doneResult { ReceiptJSONView(result: result, wallMs: pipeline.lastWallMs) }
        case .share(let url):
            ActivityView(items: [url])
        }
    }

    // MARK: - Scan outcome

    /// Everything the pipeline can be showing, in one full-screen modal: the
    /// progress while it reads, the failure if it can't, and the result if it
    /// can.
    ///
    /// One presentation rather than three, so the transition from "reading" to
    /// "read" happens *inside* a screen that is already up. Presenting the
    /// result separately meant a cover dismissing and another appearing on every
    /// successful scan.
    @ViewBuilder
    private var scanOutcome: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        switch pipeline.status {
                        case .idle:
                            // Unreachable: the cover is bound to "not idle".
                            EmptyView()
                        case .scanning:
                            scanningView
                        case .failed(let message):
                            failedView(message)
                        case .done(let result):
                            ReceiptResultView(result: result, wallMs: pipeline.lastWallMs,
                                              capturedImageURL: pipeline.capturedImageURL,
                                              exporter: exporter,
                                              onConfigure: { resultSheet = .settings },
                                              onExportMoneyManager: { presentMoneyManager(for: [result]) },
                                              onScanAnother: VNDocumentCameraViewController.isSupported
                                                  ? { showScanner = true } : nil)
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
            .safeAreaInset(edge: .top) { storageNotices }
            .background(Color.bbCanvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Keep the existing scan UX: Done appears when work finishes.
                // reset() also invalidates late completions if called elsewhere.
                if !isScanning {
                    ToolbarItem(placement: .topBarLeading) {
                        // "Done", not a house glyph. With a Home tab underneath,
                        // an icon that means "go home" is claiming to navigate
                        // where this only dismisses.
                        Button("Done") { pipeline.reset() }
                    }
                }
                // Correcting the scan is worth a button of its own here for the
                // same reason it is on the detail screen — and this is the
                // screen where a misread is actually noticed, since the export
                // that would carry it into the ledger is one tap below.
                if isDone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { resultSheet = .editor }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                resultSheet = .original
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
                                                        onConfigure: { resultSheet = .settings },
                                                        onViewJSON: { resultSheet = .json },
                                                        onExportMoneyManager: { presentMoneyManager(for: [result]) })
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        // On the stack, not inside it: a tint on the content doesn't reach the
        // navigation bar, so Done / Edit / the menu were system blue over a
        // screen whose every other control is the brand red. The same modifier
        // used to sit on the scroll view above and only reached the buttons.
        .tint(.bbAccent)
    }

#if DEBUG
    /// Every `-flag` the headless harnesses launch with — screenshots, dumps
    /// and seeded fixtures. DEBUG only, and one place rather than scattered
    /// `onAppear`s, so what a flag does is greppable from the flag.
    ///
    /// `-showSettings` selects the tab now that Settings is one; the rest are
    /// unchanged.
    @MainActor
    private func runDebugDeepLinks() async {
            // Lets `simctl launch … -autoRunSample` exercise the pipeline
            // headlessly for screenshots/verification.
            if ProcessInfo.processInfo.arguments.contains("-autoRunSample") {
                await pipeline.scanBundledSample(named: sampleName)
            }
            // `-showOriginReceipt` (paired with `-autoRunSample`): open the
            // zoomable receipt-review sheet so a headless run can screenshot
            // it — the pinch gesture itself still needs a real finger.
            if ProcessInfo.processInfo.arguments.contains("-showOriginReceipt") {
                resultSheet = .original
            }
            // `-showEditor` (paired with `-autoRunSample`): open Review & Fix
            // over the scanned result. The only way to reach this screen without
            // a finger, and the check that caught it presenting under the
            // full-screen cover.
            if ProcessInfo.processInfo.arguments.contains("-showEditor") {
                resultSheet = .editor
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
                tab = .settings
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

#if DEBUG
extension ContentView {
    /// Preview/screenshot-only initializer that injects a pinned-status pipeline
    /// so the whole screen renders in any state without running OCR.
    init(previewPipeline: ReceiptPipeline) {
        _pipeline = State(initialValue: previewPipeline)
    }
}

#endif
