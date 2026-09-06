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
    @State private var showOriginReceipt = false
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
    /// Review & Fix over the receipt that was just scanned — the moment a
    /// misread is most visible, and the last one before it is exported.
    @State private var showEditor = false
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
        .tint(.bbAccent)
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
                // **Attached inside the cover, not beside it.** A `.sheet` on
                // this view's root presents *under* the full-screen cover: the
                // flag flips, the sheet is built, and nothing appears. Verified
                // by the same failure on the pre-existing `-showOriginReceipt`
                // deep-link, which fires after the scan with the cover already
                // up. Anything the result screen presents belongs here.
                .sheet(isPresented: $showEditor) {
                    if let result = doneResult {
                        // Both halves, in this order: the record was written the
                        // moment the scan finished (`SpendStore.record`), so it
                        // is corrected by the parse it was filed under, and only
                        // then does the screen start showing the corrected one.
                        ReceiptEditorView(original: result,
                                          imageURL: pipeline.capturedImageURL) { edited in
                            SpendStore.shared.updateResult(replacing: result, with: edited)
                            pipeline.replaceResult(with: edited)
                        }
                    }
                }
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
                                              onConfigure: { showLedgerSettings = true },
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
            .background(Color.bbCanvas)
            .navigationBarTitleDisplayMode(.inline)
            .tint(.bbAccent)
            .toolbar {
                // **Not while scanning.** `reset()` clears the status but does
                // not cancel the running `scan()` task, so a Done tap mid-scan
                // dismisses this and then has the finished result present itself
                // again a second later. Withholding the button keeps the old
                // behaviour exactly — there was no way out of a scan before
                // either — rather than inventing a cancel path for a step that
                // takes about two seconds.
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
                        Button("Edit") { showEditor = true }
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
                }
            }
        }
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
                showOriginReceipt = true
            }
            // `-showEditor` (paired with `-autoRunSample`): open Review & Fix
            // over the scanned result. The only way to reach this screen without
            // a finger, and the check that caught it presenting under the
            // full-screen cover.
            if ProcessInfo.processInfo.arguments.contains("-showEditor") {
                showEditor = true
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
    /// Whether to draw the modal "Done". False when this is a tab root, where
    /// there is nothing to dismiss and the button would be a dead control.
    var showsDone: Bool = true
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
                }
                .listRowBackground(Color.bbCardFill)

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
                    Text("Save details file writes a .json of each receipt's items, prices, and tags next to the exported beancount and photo.")
                }
                .listRowBackground(Color.bbCardFill)


                receiptsSection

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
                .listRowBackground(Color.bbCardFill)

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
                    Button {
                        // Dismiss first so the home screen's scanning/done
                        // transition is actually visible, not hidden behind
                        // this sheet.
                        dismiss()
                        onRunSample()
                    } label: {
                        Label("Scan a Sample Receipt", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Off by default — keep it that way unless support has told you to turn it on. When enabled, BeanBeaver keeps a full copy of each scanned receipt (merchant, items, prices, the raw OCR text, and the generated ledger entry), plus error detail from failed scans and ledger exports, in a debug log on this device — more than the app normally keeps. The raw OCR text can include anything printed on the receipt. Turn it off again once you're done.\n\nScan a Sample Receipt runs the full on-device scan on a receipt bundled with the app — a way to see what BeanBeaver does without a receipt in hand.")
                }
                .listRowBackground(Color.bbCardFill)
                .id("debug")
            }
            .listStyle(.insetGrouped)
            // The warm ground the rest of the app stands on. Same two-part move
            // as `ReceiptsView`: hide the scroll view's own background so the
            // canvas shows through, and repaint each section's rows, because a
            // List row's fill is its own and not the scroll view's.
            .scrollContentBackground(.hidden)
            .background(Color.bbCanvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
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
        .listRowBackground(Color.bbCardFill)
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
        .listRowBackground(Color.bbCardFill)
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
            Text("Hide amounts covers the figures and the trend charts alike, and is the same switch as the eye on the home and Spending screens.")
        }
        .listRowBackground(Color.bbCardFill)
    }

    /// The honest successor to the old "Clear Old Receipts": no heuristic, and
    /// each action says exactly what it keeps — in its confirmation alert, which
    /// is why the section carries no footer repeating it. A scanned receipt
    /// itself is now kept until the user removes it — see `SpendStore` — so this
    /// is the only place that storage is freed from.
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
        }
        .listRowBackground(Color.bbCardFill)
        .alert("Clear all photos?", isPresented: $confirmClearAllPhotos) {
            Button("Clear Photos", role: .destructive) { spendStore.clearAllPhotos() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees the space used by every receipt photo. Every receipt's parsed data and every spending figure stay exactly as they are.")
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
    /// Optional banner between the header and the items — the scan-result
    /// screen's "what this did to your month" chip. Sits *inside* the card and
    /// above the line items on purpose: it answers the question the app is for,
    /// and the items are the supporting detail. `BatchReceiptDetailView` passes
    /// nothing, since a receipt opened from the list was not just added.
    var impact: AnyView?
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
    @State private var expandAccounting = false
    @State private var showAllItems = false

    private var friendlyDate: String? { ReceiptDateFormat.friendly(result.date) }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    header
                    if let impact {
                        impact
                    }
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
    /// tap-me colour here and a receipt total is not an action; and this figure
    /// now shares the eye-line with the impact chip below, which is the one that
    /// says what the scan did to the month. Subtotal moved into "Accounting
    /// details" — it reconciles the parse, which is what that section is for;
    /// tax is repeated small at the card's foot, see `taxFootnote`.
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
    @State private var spendStore = SpendStore.shared
    @State private var amountPrivacy = AmountPrivacy.shared

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
                        impact: AnyView(impactChip),
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
                Group {
                    if onScanAnother == nil {
                        Button {
                            Task { await primaryExport() }
                        } label: {
                            ExportButtonLabel(idleLabel: "Export:\(exporter.exportIndicator)",
                                              exporter: exporter)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await primaryExport() }
                        } label: {
                            ExportButtonLabel(idleLabel: "Export:\(exporter.exportIndicator)",
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

    /// What this scan did to the month, in one line — the answer to the
    /// question the app is now *for*, placed above the ledger actions rather
    /// than below them.
    ///
    /// Reads the month *after* the record was stored, so it states the new
    /// total rather than predicting it. Absent when the receipt isn't in the
    /// store yet (a preview, or a parse that wasn't recorded), rather than
    /// guessing at a figure.
    @ViewBuilder
    private var impactChip: some View {
        if let record = storedRecord {
            let monthId = spendStore.monthId(for: record)
            let month = spendStore.month(monthId)
            // Deliberately not memoized: a one-record array, and the answer is
            // about this scan rather than about the corpus.
            let own = SpendSummary.month(monthId, from: [record])
            VStack(alignment: .leading, spacing: 2) {
                Text("Added to \(SpendSummary.monthLabel(for: monthId).split(separator: " ").first.map(String.init) ?? month.label) · now \(amountPrivacy.text(PriceFormat.currency(month.tracked)))")
                    .font(.subheadline.weight(.semibold))
                if !own.roots.isEmpty {
                    Text(own.roots
                        .map { "\(amountPrivacy.text(PriceFormat.currency($0.amount))) \($0.label.lowercased())" }
                        .joined(separator: ", "))
                        .font(.caption)
                }
            }
            .foregroundStyle(Color.bbImpactText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.bbImpactSoft,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// This receipt as the store holds it, matched on the identity the store
    /// dedups by.
    private var storedRecord: SpendRecord? {
        guard let id = result.beanbeaverId else { return nil }
        return spendStore.records.first { $0.result.beanbeaverId == id }
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
        merchantDetails: MerchantDetails(
            streetAddress: "65 Kirkham Drive", city: "Markham", region: "ON",
            postalCode: "L3S 0A9", phoneNumber: "(905) 555-0143", storeNumber: "545",
            rawLines: ["65 Kirkham Drive", "Markham, ON L3S 0A9", "Whse:545 Trm:8"]),
        date: "2026-02-18",
        dateIsPlaceholder: false,
        total: "$148.73",
        tax: "$9.42",
        subtotal: "$139.31",
        items: [
            ReceiptItem(description: "ORG BANANAS", price: "$2.49", quantity: 1, account: "Expenses:Food:Grocery", tagPath: "grocery/fruit", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/fruit", display: "Fruit")]),
            ReceiptItem(description: "ROTISSERIE CHICKEN", price: "$4.99", quantity: 1, account: "Expenses:Food:Grocery:PreparedMeal", tagPath: "grocery/prepared_meal", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/meat", display: "Meat"),
                          .init(path: "grocery/meat/chicken", display: "Chicken"),
                          .init(path: "grocery/prepared_meal", display: "Prepared Meal")]),
            ReceiptItem(description: "KIRKLAND OLIVE OIL 2L", price: "$21.99", quantity: 1, account: "Expenses:Food:Grocery", tagPath: "grocery/staple", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/staple", display: "Staple")]),
            ReceiptItem(description: "BATH TISSUE 30 ROLL", price: "$24.99", quantity: 1, account: "Expenses:Home", tagPath: "household/supply", tags: [.init(path: "household", display: "Household"), .init(path: "household/supply", display: "Supply")]),
            ReceiptItem(description: "GASOLINE REGULAR", price: "$58.40", quantity: 1, account: "Expenses:Driving:Gas", tagPath: "driving/gas", tags: [.init(path: "driving", display: "Driving"), .init(path: "driving/gas", display: "Gas")]),
            ReceiptItem(description: "MYSTERY ITEM", price: "$3.00", quantity: 2, account: nil, tagPath: nil, tags: []),
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
        merchantDetails: .empty,
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
        merchantDetails: .empty,
        date: "2026-02-18",
        dateIsPlaceholder: false,
        total: "$42.10",
        tax: "$2.68",
        subtotal: "$39.42",
        items: [
            ReceiptItem(description: "PAPER TOWELS", price: "$18.99", quantity: 1, account: "Expenses:Home", tagPath: "household/supply", tags: [.init(path: "household", display: "Household"), .init(path: "household/supply", display: "Supply")]),
            ReceiptItem(description: "ORG EGGS 24CT", price: "$9.49", quantity: 1, account: "Expenses:Food:Grocery", tagPath: "grocery/dairy", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/dairy", display: "Dairy")]),
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
