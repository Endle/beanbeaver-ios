import SwiftUI
import PhotosUI
import VisionKit
import BBReceiptKit

struct ContentView: View {
    @State private var pipeline = ReceiptPipeline()
    @State private var exporter = LedgerExporter()
    @State private var photoItem: PhotosPickerItem?
    @State private var showScanner = false
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
    @State private var showJSONPreview = false
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
                                              onConfigure: { showSettings = true })
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
                                                        onConfigure: { showSettings = true },
                                                        onViewJSON: { showJSONPreview = true })
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
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
            .sheet(isPresented: $showSettings) {
                SettingsView(saveScansToPhotos: $saveScansToPhotos,
                             currentCaptureURL: pipeline.capturedImageURL) {
                    Task { await pipeline.scanBundledSample(named: sampleName) }
                }
            }
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
#if DEBUG
            .sheet(isPresented: $debugShowDataDump) {
                NavigationStack { DataDumpView() }
            }
            .sheet(isPresented: $debugShowPrivacy) {
                NavigationStack { PrivacyPolicyView() }
            }
            .task {
                // Lets `simctl launch … -autoRunSample` exercise the pipeline
                // headlessly for screenshots/verification.
                if ProcessInfo.processInfo.arguments.contains("-autoRunSample") {
                    await pipeline.scanBundledSample(named: sampleName)
                }
                if ProcessInfo.processInfo.arguments.contains("-showLedgerSettings") {
                    showLedgerSettings = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showDataDump") {
                    debugShowDataDump = true
                }
                if ProcessInfo.processInfo.arguments.contains("-showPrivacy") {
                    debugShowPrivacy = true
                }
                // Headless check for `ReceiptCaptureStore.clearOld`: logs before/after
                // counts so a `simctl launch` run can be grepped for correctness.
                if ProcessInfo.processInfo.arguments.contains("-clearOldReceipts") {
                    let before = ReceiptCaptureStore.totalBytes()
                    let result = ReceiptCaptureStore.clearOld(keeping: pipeline.capturedImageURL)
                    let after = ReceiptCaptureStore.totalBytes()
                    NSLog("[ClearOldReceipts] before=\(before)B after=\(after)B removed=\(result.count) freed=\(result.bytes)B")
                }
                // `-autoRunBatch`: headless E2E over Documents/batch_in/*.jpg → batch_out.json.
                if BatchRunner.isRequested {
                    await BatchRunner.run()
                }
            }
#endif
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    defer { photoItem = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    await pipeline.scan(imageData: data)
                }
            }
            // Headless launch-latency probe (process start → first frame); a no-op
            // unless launched with `-logLaunchTiming`. Not DEBUG-gated so a Release
            // build can be measured against Debug on a real device.
            .task { LaunchTiming.recordFirstFrame() }
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

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
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
                    Label("Sync:\(exporter.syncIndicator)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(exporter.syncTint)
                .controlSize(.large)

                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("Receipts are scanned and parsed on your device. Nothing leaves it unless you sync — and then only to your own ledger.")
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
/// against the original receipt.
struct OriginReceiptView: View {
    let imageURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let imageURL {
                    ScrollView([.horizontal, .vertical]) {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                    }
                } else {
                    ContentUnavailableView("No Photo Available", systemImage: "photo")
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
    }
}

struct SettingsView: View {
    @Binding var saveScansToPhotos: Bool
    /// Whether a `.json` details sidecar is written next to each synced receipt.
    /// Shares its key with `LedgerFileOptions.includeDetailsJSON`, which the
    /// export path reads. Default on.
    @AppStorage("includeDetailsJSON") private var includeDetailsJSON = true
    /// The photo behind the result screen currently on top, if any — excluded
    /// from "Clear Old Receipts" so it can't vanish out from under the user
    /// while they're still looking at it.
    var currentCaptureURL: URL?
    var onRunSample: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var capturedBytes = ReceiptCaptureStore.totalBytes()
    @State private var clearResultMessage: String?

    var body: some View {
        NavigationStack {
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
                    Text("Store a .json alongside each synced receipt — its items, prices, and category tags — next to the beancount and photo. Applies to both the ledger inbox file and GitHub pull requests.")
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

#if DEBUG
                Section("Debug") {
                    NavigationLink("Dump All Data") {
                        DataDumpView()
                    }
                }
#endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
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

    private var storageSection: some View {
        Section {
            LabeledContent("Captured receipt photos",
                           value: ByteCountFormatter.string(fromByteCount: capturedBytes, countStyle: .file))
            Button(role: .destructive) {
                let result = ReceiptCaptureStore.clearOld(keeping: currentCaptureURL)
                capturedBytes = ReceiptCaptureStore.totalBytes()
                clearResultMessage = result.count > 0
                    ? "Cleared \(result.count) receipt photo\(result.count == 1 ? "" : "s"), "
                        + "freed \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))."
                    : "No old receipt photos to clear."
            } label: {
                Label("Clear Old Receipts", systemImage: "trash")
            }
        } footer: {
            Text("Each scan keeps a copy of the receipt photo on your device so you can review the original later. This removes all of them except the one you're currently viewing.")
        }
    }
}

// MARK: - Result card

struct ReceiptResultView: View {
    let result: ReceiptResult
    var wallMs: Double?
    var capturedImageURL: URL?
    var exporter: LedgerExporter
    var onConfigure: () -> Void = {}
    @State private var showJSONPreview = false
    @State private var expandAccounting = false

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var friendlyDate: String? {
        guard let date = result.date else { return nil }
        guard let parsed = Self.isoDateFormatter.date(from: date) else { return date }
        return Self.displayDateFormatter.string(from: parsed)
    }

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

            VStack(spacing: 8) {
                Button {
                    Task { await primarySync() }
                } label: {
                    HStack {
                        Label("Sync:\(exporter.syncIndicator)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                        if exporter.runningKind != nil {
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(exporter.syncTint)
                .controlSize(.large)
                .disabled(exporter.runningKind != nil)

                // Secondary escape hatch: other configured destinations, Share/Copy,
                // and Sync Settings — the primary button above fires the first
                // configured destination directly, no picker in the way. Always
                // shown, even with nothing configured yet, so Share/Copy and
                // Set Up Sync… stay reachable.
                Menu {
                    LedgerExportButtons(result: result,
                                        imageURL: capturedImageURL,
                                        wallMs: wallMs,
                                        exporter: exporter,
                                        onConfigure: onConfigure,
                                        onViewJSON: { showJSONPreview = true })
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.large)
            }
        }
        .sheet(isPresented: $showJSONPreview) {
            ReceiptJSONView(result: result, wallMs: wallMs)
        }
    }

    /// Fires the first configured destination directly — no menu in the way.
    /// Falls back to opening Sync Settings when nothing is configured yet.
    private func primarySync() async {
        guard let kind = exporter.configuredKinds.first else {
            onConfigure()
            return
        }
        let entry = LedgerEntry.make(from: result, imageURL: capturedImageURL, wallMs: wallMs)
        await exporter.export(entry, to: kind)
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

/// Compact per-stage latency readout under a result, for the real-device test.
/// `wallMs` is the Swift-observed total (incl. decode + FFI); the stage rows are
/// the Rust `ScanTimings` (prep → detect → recognize → classify → parse).
/// DEBUG-only diagnostic — never shown in a release build.
struct ScanTimingsView: View {
    let timings: ScanTimings
    var wallMs: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Debug: scan time").font(.caption).foregroundStyle(.secondary)
            if let wallMs { row("total (wall)", wallMs, emphasized: true) }
            row("prep", timings.prepMs)
            row("detect", timings.detectMs)
            row("recognize", timings.recognizeMs)
            row("classify", timings.classifyMs)
            row("parse", timings.parseMs)
            row("rust total", timings.totalMs)
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
    static let preview = ScanTimings(
        prepMs: 28, detectMs: 322, classifyMs: 41,
        recognizeMs: 408, parseMs: 17, totalMs: 816)
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
        timings: .preview
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
        beancount: """
        2026-06-24 * "Corner Cafe"
          Expenses:Uncategorized       6.50 USD
          Liabilities:CreditCard      -6.50 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview
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
        beancount: """
        2026-02-18 * "Cosco"
          Expenses:Home                18.99 USD
          Expenses:Food:Grocery         9.49 USD
          Liabilities:CreditCard      -42.10 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview
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
