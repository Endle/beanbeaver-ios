import Foundation
import Observation

/// Opens a GitHub pull request that appends a transaction to a file in the
/// user's ledger repository. No on-device git engine is needed — everything is
/// the GitHub REST API over HTTPS:
///
///   1. read the base branch's head commit,
///   2. read the target file (content + blob sha; may not exist yet),
///   3. create a fresh branch off the base,
///   4. PUT the appended file onto that branch (one commit),
///   5. open a PR from that branch into the base.
///
/// A fine-grained personal access token with Contents + Pull requests
/// read/write on the repo is stored in the Keychain.
@Observable
@MainActor
final class GitHubLedger: LedgerDestination {
    let kind: LedgerDestinationKind = .githubPR

    private enum Key {
        static let owner = "githubOwner"
        static let repo = "githubRepo"
        static let path = "githubPath"
        static let base = "githubBase"
        static let token = "githubToken"   // Keychain account
    }

    var owner: String { didSet { UserDefaults.standard.set(owner, forKey: Key.owner) } }
    var repo: String { didSet { UserDefaults.standard.set(repo, forKey: Key.repo) } }
    /// Path of the ledger file within the repo, e.g. `receipts-inbox.bean`.
    var path: String { didSet { UserDefaults.standard.set(path, forKey: Key.path) } }
    var baseBranch: String { didSet { UserDefaults.standard.set(baseBranch, forKey: Key.base) } }

    /// Backed by the Keychain, not UserDefaults. `token`'s presence flips
    /// `hasToken`, which the settings UI observes.
    var token: String {
        didSet { Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Key.token) }
    }

    init() {
        let d = UserDefaults.standard
        owner = d.string(forKey: Key.owner) ?? ""
        repo = d.string(forKey: Key.repo) ?? ""
        path = d.string(forKey: Key.path) ?? ""
        baseBranch = d.string(forKey: Key.base) ?? "main"
        token = Keychain.get(Key.token) ?? ""
    }

    var isConfigured: Bool {
        !owner.trimmed.isEmpty && !repo.trimmed.isEmpty
            && !path.trimmed.isEmpty && !token.trimmed.isEmpty
    }

    func append(_ entry: LedgerEntry) async throws -> LedgerExportOutcome {
        guard isConfigured else {
            throw LedgerExportError("GitHub isn't fully set up. Add the repo and a token in Settings › Sync.")
        }
        let cfg = Config(owner: owner.trimmed, repo: repo.trimmed, path: path.trimmed,
                         base: baseBranch.trimmed.isEmpty ? "main" : baseBranch.trimmed,
                         token: token.trimmed)
        let url = try await Self.openPullRequest(cfg: cfg, beancount: entry.beancount,
                                                 document: entry.document)
        return .pullRequest(url: url)
    }

    // MARK: - REST flow

    private struct Config {
        let owner, repo, path, base, token: String
    }

    private nonisolated static func openPullRequest(
        cfg: Config, beancount: String, document: ReceiptDocument?
    ) async throws -> URL {
        let repoRoot = "/repos/\(cfg.owner)/\(cfg.repo)"

        // 1. Head commit of the base branch.
        let ref: RefResponse = try await api(cfg, "GET", "\(repoRoot)/git/ref/heads/\(cfg.base)")
        let baseSha = ref.object.sha

        // 2. Current file content + blob sha (404 => file doesn't exist yet).
        let escapedPath = cfg.path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cfg.path
        let existing: ContentsResponse?
        do {
            existing = try await api(cfg, "GET", "\(repoRoot)/contents/\(escapedPath)?ref=\(cfg.base)")
        } catch let e as HTTPStatusError where e.status == 404 {
            existing = nil
        }
        let currentText = existing?.decodedContent ?? ""
        let newText = appendEntry(to: currentText, entry: beancount)

        // 3. New branch off the base head.
        let stamp = branchStamp()
        let branch = "beanbeaver/receipt-\(stamp)"
        let _: RefResponse = try await api(cfg, "POST", "\(repoRoot)/git/refs",
            body: ["ref": "refs/heads/\(branch)", "sha": baseSha])

        // 3b. Commit the receipt image onto the same branch so the PR carries it
        //     and the transaction's `document:` link resolves. Stored beside the
        //     ledger file under its documents-root-relative path (`beanbeaver/…`).
        if let document {
            let dir = (cfg.path as NSString).deletingLastPathComponent
            let imagePath = dir.isEmpty ? document.relpath : "\(dir)/\(document.relpath)"
            try await putImageIfAbsent(cfg, repoRoot: repoRoot, path: imagePath,
                                       data: document.data, branch: branch)
        }

        // 4. Commit the appended file onto the new branch.
        var putBody: [String: Any] = [
            "message": "BeanBeaver: add receipt transaction",
            "content": Data(newText.utf8).base64EncodedString(),
            "branch": branch,
        ]
        if let sha = existing?.sha { putBody["sha"] = sha }
        let _: PutResponse = try await api(cfg, "PUT", "\(repoRoot)/contents/\(escapedPath)", body: putBody)

        // 5. Open the PR.
        let pr: PullResponse = try await api(cfg, "POST", "\(repoRoot)/pulls", body: [
            "title": "Add receipt transaction",
            "head": branch,
            "base": cfg.base,
            "body": "Appended a receipt transaction scanned with BeanBeaver iOS.",
        ])
        guard let url = URL(string: pr.htmlUrl) else {
            throw LedgerExportError("Pull request created but its URL was missing.")
        }
        return url
    }

    /// Create `path` on `branch` with `data` if it's not already there. The
    /// receipt filename carries the image's content hash, so an existing file is
    /// necessarily identical — we skip it, keeping re-exports idempotent.
    private nonisolated static func putImageIfAbsent(
        _ cfg: Config, repoRoot: String, path: String, data: Data, branch: String
    ) async throws {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        do {
            let _: ContentsResponse = try await api(
                cfg, "GET", "\(repoRoot)/contents/\(escaped)?ref=\(branch)")
            return // already present on the branch
        } catch let e as HTTPStatusError where e.status == 404 {
            // not there yet — create it below
        }
        let _: PutResponse = try await api(cfg, "PUT", "\(repoRoot)/contents/\(escaped)", body: [
            "message": "BeanBeaver: add receipt image",
            "content": data.base64EncodedString(),
            "branch": branch,
        ])
    }

    /// Append `entry` to `existing`, keeping a blank-line separator between txns.
    private nonisolated static func appendEntry(to existing: String, entry: String) -> String {
        let trimmedEntry = entry.hasSuffix("\n") ? entry : entry + "\n"
        if existing.isEmpty { return trimmedEntry }
        let base = existing.hasSuffix("\n") ? existing : existing + "\n"
        return base + "\n" + trimmedEntry
    }

    private nonisolated static func branchStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: - Transport

    private struct HTTPStatusError: Error { let status: Int; let message: String }

    private nonisolated static func api<T: Decodable>(
        _ cfg: Config, _ method: String, _ pathAndQuery: String, body: [String: Any]? = nil
    ) async throws -> T {
        guard let url = URL(string: "https://api.github.com" + pathAndQuery) else {
            throw LedgerExportError("Bad GitHub URL for \(pathAndQuery).")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LedgerExportError("No response from GitHub.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GitHubError.self, from: data))?.message
                ?? "HTTP \(http.statusCode)"
            // 404 is caught by callers to mean "file not found"; keep it distinguishable.
            if http.statusCode == 404 {
                throw HTTPStatusError(status: 404, message: message)
            }
            throw LedgerExportError("GitHub: \(message)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LedgerExportError("Couldn't read GitHub's response (\(pathAndQuery)).")
        }
    }

    // MARK: - Wire types

    private struct GitHubError: Decodable { let message: String }
    private struct RefResponse: Decodable { let object: Obj; struct Obj: Decodable { let sha: String } }
    private struct PutResponse: Decodable { let commit: Commit; struct Commit: Decodable { let sha: String } }
    private struct PullResponse: Decodable {
        let htmlUrl: String
        enum CodingKeys: String, CodingKey { case htmlUrl = "html_url" }
    }
    private struct ContentsResponse: Decodable {
        let content: String
        let sha: String
        /// GitHub returns base64 with embedded newlines; strip them before decoding.
        var decodedContent: String {
            let cleaned = content.replacingOccurrences(of: "\n", with: "")
            guard let data = Data(base64Encoded: cleaned) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
