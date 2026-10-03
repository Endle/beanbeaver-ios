import SwiftUI
import BBReceiptKit

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
    @AppStorage(GiftCardPrefs.enabledKey) private var trackGiftCard = false
    @AppStorage(PriceHistoryPrefs.enabledKey) private var priceHistoryEnabled = false
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
                                // "Export destinations", not "Sync": the page it
                                // opens is titled Export and every action that
                                // reaches it says Export. Sync implied a two-way
                                // relationship the app doesn't have.
                                Text("Export destinations")
                                Text(exportDestinationsSubtitle)
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
                    Toggle("Turn on price history", isOn: $priceHistoryEnabled)
                    Toggle("Track gift card", isOn: $trackGiftCard)
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
                    Text("Price history adds Items to Home so you can browse past purchases. It is off by default; turning it off keeps your receipts and item links.\n\nTrack gift card shows gift-card details, related transactions, and correction controls. It is off by default; turning it off keeps saved receipt data.\n\nDetailed debug info is off by default — keep it that way unless support has told you to turn it on. When enabled, BeanBeaver keeps a full copy of each scanned receipt (merchant, items, prices, the raw OCR text, and the generated ledger entry), plus error detail from failed scans and ledger exports, in a debug log on this device — more than the app normally keeps. The raw OCR text can include anything printed on the receipt. Turn it off again once you're done.\n\nScan a Sample Receipt runs the full on-device scan on a receipt bundled with the app — a way to see what BeanBeaver does without a receipt in hand.")
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

    /// The Export destinations row's state line: what is configured, and how
    /// much has actually gone out through it.
    private var exportDestinationsSubtitle: String {
        guard exporter.selectedTargetReady else { return "Not set up" }
        let exported = spendStore.exportedRecords.count
        return exported == 0
            ? exporter.exportIndicator
            : "\(exporter.exportIndicator) · \(exported) exported"
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
