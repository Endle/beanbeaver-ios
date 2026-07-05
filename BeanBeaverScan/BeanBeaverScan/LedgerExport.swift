import Foundation
import Observation
import SwiftUI
import BBReceiptKit

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
    }
    let merchant: String
    let date: String?
    let dateIsPlaceholder: Bool
    let total: String
    let subtotal: String?
    let tax: String?
    let items: [Item]
    let warnings: [String]

    init(_ result: ReceiptResult) {
        merchant = result.merchant
        date = result.date
        dateIsPlaceholder = result.dateIsPlaceholder
        total = result.total
        subtotal = result.subtotal
        tax = result.tax
        items = result.items.map {
            Item(description: $0.description, price: $0.price, quantity: $0.quantity, category: $0.category)
        }
        warnings = result.warnings
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
    /// `imageURL` is the captured JPEG still on disk, if any.
    static func make(from result: ReceiptResult, imageURL: URL?) -> LedgerEntry {
        let document: ReceiptDocument? = {
            guard let relpath = result.documentRelpath, let imageURL,
                  let data = try? Data(contentsOf: imageURL) else { return nil }
            return ReceiptDocument(data: data, relpath: relpath)
        }()
        return LedgerEntry(beancount: result.beancount, document: document,
                           json: try? Self.jsonEncoder.encode(ReceiptExportJSON(result)),
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
    /// Append one transaction and, when present, store its receipt image so the
    /// `document:` link resolves. `entry.beancount` is `ReceiptResult.beancount`
    /// verbatim.
    func append(_ entry: LedgerEntry) async throws -> LedgerExportOutcome
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

    /// Compact label for the home screen's "Sync:" indicator.
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

/// What happened on a successful export — used to build the confirmation.
enum LedgerExportOutcome {
    case appended(fileName: String)
    case pullRequest(url: URL)

    var title: String {
        switch self {
        case .appended: return "Added to ledger"
        case .pullRequest: return "Pull request opened"
        }
    }

    var message: String {
        switch self {
        case .appended(let name): return "Appended the transaction to \(name)."
        case .pullRequest(let url): return url.absoluteString
        }
    }

    /// A URL the confirmation can offer to open (the PR page), if any.
    var openableURL: URL? {
        if case .pullRequest(let url) = self { return url }
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

    /// The backend currently running an export (for a per-button spinner), or nil.
    private(set) var runningKind: LedgerDestinationKind?

    /// Set when an export finishes; the view binds an alert to it.
    var result: Result?

    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let openURL: URL?
        let isError: Bool
    }

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

    /// Short label for a "Sync:" button — "None" or the configured
    /// destinations, e.g. "Files" or "Files+GitHub". Shared by the home
    /// screen and the result screen so they never drift.
    var syncIndicator: String {
        let kinds = configuredKinds
        guard !kinds.isEmpty else { return "None" }
        return kinds.map(\.shortTitle).joined(separator: "+")
    }

    /// Green once a destination is configured (matches the platform's
    /// "connected" convention), grey while sync is unset.
    var syncTint: Color {
        configuredKinds.isEmpty ? .secondary : .green
    }

    func export(_ entry: LedgerEntry, to kind: LedgerDestinationKind) async {
        guard runningKind == nil else { return }
        runningKind = kind
        defer { runningKind = nil }
        do {
            let outcome = try await destination(for: kind).append(entry)
            result = Result(title: outcome.title, message: outcome.message,
                            openURL: outcome.openableURL, isError: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            result = Result(title: "Export failed", message: message,
                            openURL: nil, isError: true)
        }
    }
}
