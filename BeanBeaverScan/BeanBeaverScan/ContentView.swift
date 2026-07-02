import SwiftUI
import PhotosUI
import VisionKit
import BBReceiptKit

struct ContentView: View {
    @State private var pipeline = ReceiptPipeline()
    @State private var photoItem: PhotosPickerItem?
    @State private var showScanner = false

    /// When on, a copy of each camera-scanned receipt is saved to the camera roll.
    @AppStorage("saveScansToPhotos") private var saveScansToPhotos = false

    /// Bundled DEBUG sample (a redacted Costco receipt fixture).
    private let sampleName = "costco_20260218_redact"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch pipeline.status {
                    case .idle:
                        idleView
                    case .scanning:
                        scanningView
                    case .failed(let message):
                        failedView(message)
                    case .done(let result):
                        ReceiptResultView(result: result, wallMs: pipeline.lastWallMs, capturedImageURL: pipeline.capturedImageURL) {
                            pipeline.reset()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("BeanBeaver")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.bbAccent)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner(
                    onScan: { data in
                        if saveScansToPhotos { PhotoSaver.save(imageData: data) }
                        Task { await pipeline.scan(imageData: data) }
                    },
                    onFinish: { showScanner = false }
                )
                .ignoresSafeArea()
            }
#if DEBUG
            .task {
                // Lets `simctl launch … -autoRunSample` exercise the pipeline
                // headlessly for screenshots/verification.
                if ProcessInfo.processInfo.arguments.contains("-autoRunSample") {
                    await pipeline.scanBundledSample(named: sampleName)
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
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    await pipeline.scan(imageData: data)
                }
            }
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.bbAccentSoft)
                        .frame(width: 88, height: 88)
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.bbAccent)
                }
                .padding(.top, 12)

                Text("Turn any receipt into clean bookkeeping — right on your phone.")
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
            }

            if VNDocumentCameraViewController.isSupported {
                HStack {
                    Image(systemName: "photo.badge.checkmark")
                        .foregroundStyle(.secondary)
                    Toggle("Save a copy to Photos", isOn: $saveScansToPhotos)
                        .font(.subheadline)
                }
                .padding(12)
                .bbCard()
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("Everything is scanned and parsed on your device — nothing is uploaded.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)

#if DEBUG
            Button("Debug: Run Bundled Sample") {
                Task { await pipeline.scanBundledSample(named: sampleName) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
#endif
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
            Text("This all happens on your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

// MARK: - Result card

struct ReceiptResultView: View {
    let result: ReceiptResult
    var wallMs: Double?
    var capturedImageURL: URL?
    var onScanAnother: () -> Void

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

            DisclosureGroup("Accounting details (beancount)") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(result.beancount)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    ShareLink(item: result.beancount) {
                        Label("Export beancount", systemImage: "square.and.arrow.up")
                    }

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
                .padding(.top, 8)
            }
            .padding(16)
            .bbCard()

            Button {
                onScanAnother()
            } label: {
                Label("Scan Another Receipt", systemImage: "camera.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.bbAccent)
            .controlSize(.large)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.merchant.capitalized).font(.title2.bold())
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
        let style = CategoryDisplay.style(for: item.category)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.description.capitalized)
                    .lineLimit(1)
                    .font(.subheadline)
                Text(style.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        date: "2026-02-18",
        dateIsPlaceholder: false,
        total: "$148.73",
        tax: "$9.42",
        subtotal: "$139.31",
        items: [
            ReceiptItem(description: "ORG BANANAS", price: "$2.49", quantity: 1, category: "Expenses:Food:Grocery"),
            ReceiptItem(description: "ROTISSERIE CHICKEN", price: "$4.99", quantity: 1, category: "Expenses:Food:Grocery:PreparedMeal"),
            ReceiptItem(description: "KIRKLAND OLIVE OIL 2L", price: "$21.99", quantity: 1, category: "Expenses:Food:Grocery"),
            ReceiptItem(description: "BATH TISSUE 30 ROLL", price: "$24.99", quantity: 1, category: "Expenses:Home"),
            ReceiptItem(description: "GASOLINE REGULAR", price: "$58.40", quantity: 1, category: "Expenses:Driving:Gas"),
            ReceiptItem(description: "MYSTERY ITEM", price: "$3.00", quantity: 2, category: nil),
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
        timings: .preview
    )

    /// A sparse result: no line items, inferred date, parser warnings.
    static let previewMinimal = ReceiptResult(
        merchant: "Corner Cafe",
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
        timings: .preview
    )
}

#Preview("Result – full") {
    ScrollView { ReceiptResultView(result: .previewFull, wallMs: 816, capturedImageURL: nil, onScanAnother: {}).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Result – minimal") {
    ScrollView { ReceiptResultView(result: .previewMinimal, wallMs: 300, capturedImageURL: nil, onScanAnother: {}).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Screen – idle") {
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
