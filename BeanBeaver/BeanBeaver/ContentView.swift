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
    @Environment(\.openURL) private var openURL

    /// When on, a copy of each camera-scanned receipt is saved to the camera roll.
    @AppStorage("saveScansToPhotos") private var saveScansToPhotos = false

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

    /// Pending-count suffix for the import button, mirroring the Export button's
    /// "Export:…" indicator so a batch left half-done is visible from home
    /// without inventing a second idiom for it.
    private var batchBadge: String {
        batch.isEmpty ? "" : " (\(batch.drafts.count))"
    }

    /// Every capture "Clear Old Receipts" must spare: the photo behind the
    /// result currently on screen, plus every photo the pending batch still
    /// needs to parse, review, or export.
    private var keptCaptureFilenames: Set<String> {
        var kept = batch.liveCaptureFilenames
        if let name = pipeline.capturedImageURL?.lastPathComponent { kept.insert(name) }
        return kept
    }

    /// Build the Money Manager `.xlsx` for `results` and present its share sheet.
    /// A failure here is a rare temp-file write error and non-fatal — captured for
    /// support rather than surfaced, matching the ledger exporter's error handling.
    private func presentMoneyManager(for results: [ReceiptResult]) {
        guard Entitlements.isPremium else { return }
        do {
            moneyManagerShare = ShareFile(url: try MoneyManagerExport.makeFile(for: results))
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
                }
            }
            .navigationDestination(isPresented: $showBatchImport) {
                BatchImportView(batch: batch, exporter: exporter,
                                onConfigure: { showLedgerSettings = true })
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerWithHint(
                    onScan: { data in
                        if saveScansToPhotos { PhotoSaver.save(imageData: data) }
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
                SettingsView(saveScansToPhotos: $saveScansToPhotos,
                             keptCaptureFilenames: keptCaptureFilenames) {
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
                if ProcessInfo.processInfo.arguments.contains("-showDataDump") {
                    debugShowDataDump = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showPrivacy") {
                    debugShowPrivacy = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showDebugInfoList") {
                    debugShowDebugInfoList = true
                }
                // Headless check for `ReceiptCaptureStore.clearOld`: logs before/after
                // counts so a `simctl launch` run can be grepped for correctness.
                if ProcessInfo.processInfo.arguments.contains("-clearOldReceipts") {
                    let before = ReceiptCaptureStore.totalBytes()
                    let result = ReceiptCaptureStore.clearOld(keeping: keptCaptureFilenames)
                    let after = ReceiptCaptureStore.totalBytes()
                    NSLog("[ClearOldReceipts] before=\(before)B after=\(after)B removed=\(result.count) freed=\(result.bytes)B")
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
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Text("What happens in your wallet, stays in your wallet.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 12) {
                if VNDocumentCameraViewController.isSupported {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan a Receipt", systemImage: "camera.viewfinder")
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
                // back to. The camera button above stays the one-receipt path.
                // Driven through `navigationDestination` rather than a
                // NavigationLink so the `-showBatchImport` DEBUG deep-link can
                // open it headlessly for screenshots.
                Button {
                    showBatchImport = true
                } label: {
                    Label("Import from Photos\(batchBadge)", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.bbAccent)
                .controlSize(.large)

                Button {
                    showLedgerSettings = true
                } label: {
                    Label("Export:\(exporter.exportIndicator)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(exporter.exportTint)
                .controlSize(.large)

                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(BBQuietButtonStyle())
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("Receipts are scanned and parsed on your device. Nothing leaves it unless you export — and then only to your own ledger.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        .padding(.top, 20)
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
    @Binding var saveScansToPhotos: Bool
    /// Whether a `.json` details sidecar is written next to each exported receipt.
    /// Shares its key with `LedgerFileOptions.includeDetailsJSON`, which the
    /// export path reads. Default on.
    @AppStorage("includeDetailsJSON") private var includeDetailsJSON = true
    /// "Store detailed debug info" (Settings › Debug). Off by default — see
    /// `DebugInfoStore` for what turning it on actually keeps around.
    @AppStorage(DebugInfoStore.enabledKey) private var storeDetailedDebugInfo = false
    /// The "Enable premium features" switch — the stub premium control while
    /// BeanBeaver is TestFlight-only. Defaults on; see `Entitlements.isPremium`.
    @AppStorage(Entitlements.premiumEnabledKey) private var premiumEnabled = true
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
    /// Captures "Clear Old Receipts" must spare: the photo behind the result
    /// screen currently on top, so it can't vanish out from under the user while
    /// they're still looking at it, and every photo the pending import batch
    /// still needs.
    var keptCaptureFilenames: Set<String>
    var onRunSample: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var capturedBytes = ReceiptCaptureStore.totalBytes()
    @State private var clearResultMessage: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if VNDocumentCameraViewController.isSupported {
                    Section {
                        Toggle("Save a copy to Photos", isOn: $saveScansToPhotos)
                    } footer: {
                        Text("Keep a copy of each camera scan in your Photos library.")
                    }
                }

                Section {
                    Toggle("Save details file", isOn: $includeDetailsJSON)
                } footer: {
                    Text("Store a .json alongside each exported receipt — its items, prices, and category tags — next to the beancount and photo. Applies to both the ledger inbox file and GitHub pull requests.")
                }

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
                } header: {
                    Text("Ledger")
                } footer: {
                    Text("The currency and tax account used in every beancount entry BeanBeaver generates. Currency defaults to your region.")
                }

                storageSection

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

                Section {
                    Toggle("Store detailed debug info", isOn: $storeDetailedDebugInfo)
                    Toggle("Enable premium features", isOn: $premiumEnabled)
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
            .alert("Storage", isPresented: Binding(
                get: { clearResultMessage != nil },
                set: { if !$0 { clearResultMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(clearResultMessage ?? "")
            }
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

    private var storageSection: some View {
        Section {
            LabeledContent("Captured receipt photos",
                           value: ByteCountFormatter.string(fromByteCount: capturedBytes, countStyle: .file))
            Button(role: .destructive) {
                let result = ReceiptCaptureStore.clearOld(keeping: keptCaptureFilenames)
                capturedBytes = ReceiptCaptureStore.totalBytes()
                clearResultMessage = result.count > 0
                    ? "Cleared \(result.count) receipt photo\(result.count == 1 ? "" : "s"), "
                        + "freed \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))."
                    : "No old receipt photos to clear."
            } label: {
                Label("Clear Old Receipts", systemImage: "trash")
            }
        } footer: {
            Text("Each scan keeps a copy of the receipt photo on your device so you can review the original later. This removes all of them except the one you're currently viewing and any still waiting in a photo import.")
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

            if !result.warnings.isEmpty {
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

    private var warningsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Heads up", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.bold())
            ForEach(result.warnings, id: \.self) { warning in
                Text(warning).font(.caption)
            }
        }
        .foregroundStyle(Color.bbAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.bbAccentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            guard Entitlements.isPremium else { onConfigure(); return }
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
            ReceiptItem(description: "ORG BANANAS", price: "$2.49", quantity: 1, category: "Expenses:Food:Grocery", tags: ["grocery", "fruit"]),
            ReceiptItem(description: "ROTISSERIE CHICKEN", price: "$4.99", quantity: 1, category: "Expenses:Food:Grocery:PreparedMeal", tags: ["grocery", "meat", "chicken", "prepared", "meal"]),
            ReceiptItem(description: "KIRKLAND OLIVE OIL 2L", price: "$21.99", quantity: 1, category: "Expenses:Food:Grocery", tags: ["grocery", "staple"]),
            ReceiptItem(description: "BATH TISSUE 30 ROLL", price: "$24.99", quantity: 1, category: "Expenses:Home", tags: ["home", "household"]),
            ReceiptItem(description: "GASOLINE REGULAR", price: "$58.40", quantity: 1, category: "Expenses:Driving:Gas", tags: ["driving", "gas"]),
            ReceiptItem(description: "MYSTERY ITEM", price: "$3.00", quantity: 2, category: nil, tags: []),
        ],
        warnings: [],
        warningAfterItemIndices: [],
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
        warnings: ["No line items detected", "Date inferred from today"],
        warningAfterItemIndices: [-1, -1],
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
            ReceiptItem(description: "PAPER TOWELS", price: "$18.99", quantity: 1, category: "Expenses:Home", tags: ["home", "household"]),
            ReceiptItem(description: "ORG EGGS 24CT", price: "$9.49", quantity: 1, category: "Expenses:Food:Grocery", tags: ["grocery", "dairy", "egg"]),
        ],
        warnings: [],
        warningAfterItemIndices: [],
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
