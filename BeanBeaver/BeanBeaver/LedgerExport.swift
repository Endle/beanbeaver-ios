import Foundation
import Observation
import SwiftUI
import BBReceiptKit

/// User-facing options for what an export writes. The Settings toggle binds to
/// the same `@AppStorage` key; `LedgerEntry.make` reads it here so both the
/// GitHub-PR and Files-inbox backends honor one setting. Default on — the
/// details file is useful and both backends already carried it for GitHub.
enum LedgerFileOptions {
    static let includeDetailsJSONKey = "includeDetailsJSON"

    static var includeDetailsJSON: Bool {
        UserDefaults.standard.object(forKey: includeDetailsJSONKey) as? Bool ?? true
    }
}

/// A receipt image to store alongside the transaction so its `document:` link
/// resolves for any user. `relpath` is relative to the ledger's documents root
/// (e.g. `beanbeaver/2026-02-18-costco-a1b2c3d4.jpg`) — exactly the value the
/// Rust core wrote into the transaction's `document:` metadata
/// (`ReceiptResult.documentRelpath`). `data` is the scanned JPEG, whose content
/// hash the relpath's token was derived from, so the link always resolves.
struct ReceiptDocument {
    let data: Data
    let relpath: String
}

/// The scan's structured output before beancount formatting — merchant,
/// totals, items — exported as a `.json` sidecar next to `.beancount`/`.jpg`
/// so the raw parse survives even if the beancount rendering rules change.
struct ReceiptExportJSON: Encodable {
    struct Item: Encodable {
        let description: String
        let price: String
        let quantity: Int32
        let category: String?
        /// Beanbeaver-internal semantic tags (broad→specific), the classification
        /// the app displays from. Preserved here so the raw parse keeps the full
        /// tag set even if the beancount account mapping later changes.
        let tags: [String]
    }
    /// Per-stage on-device timings (ms), mirrored from the Rust `ScanTimings` —
    /// same shape as `BatchRunner.Timings`, so a PR's sidecar JSON carries the
    /// same latency breakdown as the headless E2E harness.
    struct Timings: Encodable {
        let prepMs: Double
        let detectMs: Double
        let classifyMs: Double
        let recognizeMs: Double
        let parseMs: Double
        let totalMs: Double
        /// Swift-observed total (incl. decode + FFI) — nil when unavailable
        /// (e.g. exported from a re-opened result screen).
        let wallMs: Double?
    }
    let merchant: String
    let date: String?
    let dateIsPlaceholder: Bool
    let total: String
    let subtotal: String?
    let tax: String?
    let items: [Item]
    let warnings: [String]
    let timings: Timings

    init(_ result: ReceiptResult, wallMs: Double? = nil) {
        merchant = result.merchant
        date = result.date
        dateIsPlaceholder = result.dateIsPlaceholder
        total = result.total
        subtotal = result.subtotal
        tax = result.tax
        items = result.items.map {
            Item(description: $0.description, price: $0.price, quantity: $0.quantity,
                 category: $0.category, tags: $0.tags)
        }
        warnings = result.warnings
        timings = Timings(
            prepMs: result.timings.prepMs, detectMs: result.timings.detectMs,
            classifyMs: result.timings.classifyMs, recognizeMs: result.timings.recognizeMs,
            parseMs: result.timings.parseMs, totalMs: result.timings.totalMs,
            wallMs: wallMs)
    }
}

/// An export button's contents: normally its label, and while an export runs,
/// what that export is actually doing. Shared by the single-scan result screen
/// and the batch page so the two can't drift.
///
/// The live message matters more than it looks — a batch is tens of seconds of
/// sequential network calls, and a spinner alone doesn't distinguish "working"
/// from "wedged".
struct ExportButtonLabel: View {
    let idleLabel: String
    var exporter: LedgerExporter

    var body: some View {
        HStack(spacing: 8) {
            if exporter.runningKind != nil {
                ProgressView().tint(.white)
                Text(exporter.runningMessage ?? "Exporting…")
                    .font(.subheadline)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.default, value: exporter.runningMessage)
            } else {
                Label(idleLabel, systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// Read-only preview of the `.json` sidecar an export would attach — lets the
/// user check the raw parse (and share/copy it) without actually exporting,
/// even when `LedgerFileOptions.includeDetailsJSON` is off.
struct ReceiptJSONView: View {
    let result: ReceiptResult
    var wallMs: Double?
    @Environment(\.dismiss) private var dismiss

    private var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ReceiptExportJSON(result, wallMs: wallMs)),
              let text = String(data: data, encoding: .utf8) else {
            return "Unable to encode JSON."
        }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(jsonText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Receipt JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: jsonText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One transaction to export, plus the optional receipt image that travels with
/// it. `document` is nil when the scan produced no content hash (older cores) or
/// the captured JPEG is unavailable — export then falls back to text-only.
struct LedgerEntry {
    let beancount: String
    let document: ReceiptDocument?
    /// The pre-beancount scan data, serialized — nil only if encoding somehow fails.
    let json: Data?
    /// Lowercase-dash merchant slug, matching `document.relpath`'s convention.
    let merchantSlug: String
    /// `bb-<yyyymmdd|unknowndate>-<sha8>`, the same identity token stamped on
    /// the transaction and baked into `document.relpath`. `nil` when the scan
    /// produced no image hash (`document` is then nil too).
    let beanbeaverId: String?

    /// Build the entry the export destinations receive from a finished scan.
    /// `imageURL` is the captured JPEG still on disk, if any. `wallMs` is the
    /// Swift-observed total scan time, folded into the `.json` sidecar's
    /// timings alongside the Rust per-stage breakdown. The sidecar is included
    /// only when the user has the "details file" option on
    /// (`LedgerFileOptions.includeDetailsJSON`) — both backends skip a nil `json`.
    static func make(from result: ReceiptResult, imageURL: URL?, wallMs: Double? = nil) -> LedgerEntry {
        let document: ReceiptDocument? = {
            guard let relpath = result.documentRelpath, let imageURL,
                  let data = try? Data(contentsOf: imageURL) else { return nil }
            return ReceiptDocument(data: data, relpath: relpath)
        }()
        let json = LedgerFileOptions.includeDetailsJSON
            ? try? Self.jsonEncoder.encode(ReceiptExportJSON(result, wallMs: wallMs))
            : nil
        return LedgerEntry(beancount: result.beancount, document: document,
                           json: json,
                           merchantSlug: Self.merchantSlug(result.merchant),
                           beanbeaverId: result.beanbeaverId)
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Lowercase, dash-collapsed slug (e.g. `COSTCO WHOLESALE #123` ->
    /// `costco-wholesale-123`) — mirrors `receipt-core`'s `merchant_slug` so
    /// filenames built here agree with `document.relpath`. Never empty.
    private static func merchantSlug(_ merchant: String) -> String {
        var slug = ""
        var previousDash = false
        for ch in merchant.lowercased() {
            let isAlphanumeric = ch.isASCII && (ch.isLetter || ch.isNumber)
            let normalized: Character = isAlphanumeric ? ch : "-"
            if normalized == "-" {
                if previousDash { continue }
                previousDash = true
            } else {
                previousDash = false
            }
            slug.append(normalized)
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "unknown" : slug
    }
}

/// Called by a destination to say what it's doing, so a long export can show it.
/// A batch of eight receipts is ~50 sequential GitHub round trips; twenty
/// seconds of unlabelled spinner is indistinguishable from a hang, which is the
/// whole reason this exists. Calls land on the main actor, in order.
typealias LedgerProgressReporter = @MainActor @Sendable (String) -> Void

/// A place a parsed receipt's beancount transaction can be sent. Concrete
/// backends (a synced `.bean` file via the Files layer, a GitHub pull request)
/// live in their own files; the UI only talks to this seam.
///
/// Adding a WebDAV/S3/etc. destination later is just another conformance.
@MainActor
protocol LedgerDestination: AnyObject {
    var kind: LedgerDestinationKind { get }
    /// Whether the user has finished configuring this backend (picked a file,
    /// entered a repo + token, …). Drives whether the export button is offered.
    var isConfigured: Bool { get }
    /// Append `entries` in order and, when present, store each receipt image so
    /// the `document:` links resolve. `entry.beancount` is
    /// `ReceiptResult.beancount` verbatim.
    ///
    /// Array-shaped rather than one-at-a-time because both backends collapse a
    /// batch into a single operation — one branch and one pull request, one
    /// read-modify-write of the inbox file — which is also fewer round trips per
    /// receipt than looping would be. A single scan just passes `[entry]`.
    /// Callers must not pass an empty array.
    ///
    /// Report each step through `progress` — this can take tens of seconds.
    func append(_ entries: [LedgerEntry],
                progress: @escaping LedgerProgressReporter) async throws -> LedgerExportOutcome
}

enum LedgerDestinationKind: String, CaseIterable, Identifiable {
    case filesInbox
    case githubPR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filesInbox: return "Ledger inbox file"
        case .githubPR: return "GitHub pull request"
        }
    }

    /// Compact label for the home screen's "Export:" indicator.
    var shortTitle: String {
        switch self {
        case .filesInbox: return "Files"
        case .githubPR: return "GitHub"
        }
    }

    /// One-line explainer shown under the row in settings.
    var blurb: String {
        switch self {
        case .filesInbox:
            return "Append to a .bean file in iCloud Drive, Dropbox, Box… — anything in Files. `include` it from your main ledger."
        case .githubPR:
            return "Open a pull request that appends the transaction to a file in your ledger's GitHub repo."
        }
    }

    var systemImage: String {
        switch self {
        case .filesInbox: return "folder"
        case .githubPR: return "arrow.triangle.branch"
        }
    }
}

/// A downstream receiver the Export page can target — the "where do receipts go"
/// choice the home screen's "Export:" indicator reflects and the primary Export
/// button acts on. Broader than `LedgerDestinationKind`: Money Manager is a
/// share-sheet Excel export, not an async ledger append, so its `ledgerKind` is
/// nil. Add a new receiver as a case here and the Export page renders it, the
/// picker lists it, and the indicators pick it up — no other wiring per site.
enum ExportTarget: String, CaseIterable, Identifiable {
    case github
    case moneyManager

    var id: String { rawValue }
    static let storageKey = "syncSelectedExporter"

    var label: String {
        switch self {
        case .github: return "GitHub"
        case .moneyManager: return "Money Manager"
        }
    }

    var systemImage: String {
        switch self {
        case .github: return LedgerDestinationKind.githubPR.systemImage
        case .moneyManager: return "tablecells"
        }
    }

    /// The async ledger destination this maps to, or nil for a share-sheet export
    /// (Money Manager) — which is what tells the primary action whether "export"
    /// means an append or presenting a file to share.
    var ledgerKind: LedgerDestinationKind? {
        switch self {
        case .github: return .githubPR
        case .moneyManager: return nil
        }
    }

    var requiresPremium: Bool { self == .moneyManager }
}

/// What happened on a successful export — used to build the confirmation.
/// `count` is how many transactions went in, so a batch can say so.
enum LedgerExportOutcome {
    case appended(fileName: String, count: Int)
    case pullRequest(url: URL, count: Int)

    var title: String {
        switch self {
        case .appended: return "Added to ledger"
        case .pullRequest: return "Pull request opened"
        }
    }

    var message: String {
        switch self {
        case .appended(let name, let count):
            return count == 1
                ? "Appended the transaction to \(name)."
                : "Appended \(count) transactions to \(name)."
        case .pullRequest(let url, _):
            return url.absoluteString
        }
    }

    /// A URL the confirmation can offer to open (the PR page), if any.
    var openableURL: URL? {
        if case .pullRequest(let url, _) = self { return url }
        return nil
    }
}

/// A backend-agnostic failure with a user-presentable message.
struct LedgerExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Owns the configured destinations and runs an export, publishing progress and
/// a result for the UI to surface in an alert. One instance is held by
/// `ContentView` and passed down to the result screen and settings.
@Observable
@MainActor
final class LedgerExporter {
    // `var` (not `let`) so `@Bindable` can form writable key-paths through them
    // (e.g. `$exporter.github.owner`); the instances are never reassigned.
    var filesInbox = FilesLedgerInbox()
    var github = GitHubLedger()

    /// The receiver the Export page has selected — the target of the primary
    /// Export button and what the home "Export:" indicator shows. Persisted so it
    /// survives relaunch; observable so the indicator updates the moment it changes.
    var selectedTarget: ExportTarget = ExportTarget(
        rawValue: UserDefaults.standard.string(forKey: ExportTarget.storageKey) ?? ""
    ) ?? .github {
        didSet { UserDefaults.standard.set(selectedTarget.rawValue, forKey: ExportTarget.storageKey) }
    }

    /// The backend currently running an export (for a per-button spinner), or nil.
    private(set) var runningKind: LedgerDestinationKind?

    /// What that export is doing right now, straight from the backend. Nil
    /// between steps and when nothing is running.
    private(set) var runningMessage: String?

    /// Set when an export finishes; the view binds an alert to it.
    var result: Result?

    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let openURL: URL?
        let isError: Bool
    }

#if DEBUG
    /// Walk the export button through a realistic run without a configured
    /// backend, so the running state can be seen headlessly (`-fakeExportProgress`).
    /// Lives here because `runningKind`/`runningMessage` are `private(set)`.
    func simulateProgress() async {
        runningKind = .githubPR
        defer {
            runningKind = nil
            runningMessage = nil
        }
        let steps = ["Reading Endle/my_beancount_record…",
                     "Checking receipt 1 of 3…", "Checking receipt 2 of 3…",
                     "Checking receipt 3 of 3…", "Creating the branch…",
                     "Uploading receipt 1 of 3…", "Uploading receipt 2 of 3…",
                     "Uploading receipt 3 of 3…", "Opening the pull request…"]
        for step in steps {
            runningMessage = step
            try? await Task.sleep(for: .seconds(2))
        }
        // Ends by publishing a result, so the confirmation's presentation can be
        // checked from wherever the export was started — the alert used to anchor
        // to the home screen and arrive late when it was the batch page.
        result = Result(title: "Pull request opened",
                        message: "https://github.com/Endle/my_beancount_record/pull/6",
                        openURL: URL(string: "https://github.com/Endle/my_beancount_record/pull/6"),
                        isError: false)
    }
#endif

    func destination(for kind: LedgerDestinationKind) -> any LedgerDestination {
        switch kind {
        case .filesInbox: return filesInbox
        case .githubPR: return github
        }
    }

    /// Destinations the user has configured — the ones worth offering as buttons.
    var configuredKinds: [LedgerDestinationKind] {
        LedgerDestinationKind.allCases.filter { destination(for: $0).isConfigured }
    }

    /// Whether the selected target can receive right now — a configured ledger
    /// destination, or premium unlocked for the Money Manager share export.
    var selectedTargetReady: Bool {
        if let kind = selectedTarget.ledgerKind { return destination(for: kind).isConfigured }
        return Entitlements.isPremium
    }

    /// Label for an "Export:" button — the selected target's name, with a lock
    /// when it's premium and not yet unlocked. Shared by the home screen and the
    /// result screen so they never drift.
    var exportIndicator: String {
        var label = selectedTarget.label
        if selectedTarget.requiresPremium && !Entitlements.isPremium { label += " 🔒" }
        return label
    }

    /// Green once the selected target is ready (matches the platform's
    /// "connected" convention), grey while it still needs setup/unlock.
    var exportTint: Color {
        selectedTargetReady ? .green : .secondary
    }

    /// Send `entries` to `kind`, publishing a confirmation (or a failure) for the
    /// UI's alert. Returns whether it succeeded, so a batch can drain only the
    /// receipts that actually landed. A no-op if an export is already running or
    /// there's nothing to send.
    @discardableResult
    func export(_ entries: [LedgerEntry], to kind: LedgerDestinationKind) async -> Bool {
        guard runningKind == nil, !entries.isEmpty else { return false }
        runningKind = kind
        runningMessage = nil
        defer {
            runningKind = nil
            runningMessage = nil
        }
        do {
            let outcome = try await destination(for: kind).append(entries) { [weak self] message in
                self?.runningMessage = message
            }
            result = Result(title: outcome.title, message: outcome.message,
                            openURL: outcome.openableURL, isError: false)
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DebugInfoStore.recordExportFailure(context: "export to \(kind.shortTitle)", message: message)
            result = Result(title: "Export failed", message: message,
                            openURL: nil, isError: true)
            return false
        }
    }
}
