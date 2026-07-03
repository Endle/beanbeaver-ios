import Foundation
import Observation

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
    /// Append one transaction. `beancount` is `ReceiptResult.beancount` verbatim.
    func append(_ beancount: String) async throws -> LedgerExportOutcome
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

    func export(_ beancount: String, to kind: LedgerDestinationKind) async {
        guard runningKind == nil else { return }
        runningKind = kind
        defer { runningKind = nil }
        do {
            let outcome = try await destination(for: kind).append(beancount)
            result = Result(title: outcome.title, message: outcome.message,
                            openURL: outcome.openableURL, isError: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            result = Result(title: "Export failed", message: message,
                            openURL: nil, isError: true)
        }
    }
}
