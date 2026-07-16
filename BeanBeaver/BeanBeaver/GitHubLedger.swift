import Foundation
import Observation

/// Opens a GitHub pull request that files a scanned receipt into the user's
/// ledger repository as its own folder — `.beancount`, `.json`, and `.jpg`
/// side by side — rather than appending to a shared file. No on-device git
/// engine is needed — everything is the GitHub REST API over HTTPS:
///
///   1. resolve the repo's default branch and read its head commit,
///   2. create a fresh branch off the default branch,
///   3. PUT each of the receipt's files onto that branch (one commit each),
///   4. open a PR from that branch into the default branch.
///
/// A GitHub App user access token (obtained via device flow, see
/// `GitHubDeviceFlow.swift`) authorizes the REST calls and is stored in the
/// Keychain. The app must be installed on the repo with Contents + Pull requests
/// read/write; because it's a per-repo installation the token can't reach the
/// user's other repos.
@Observable
@MainActor
final class GitHubLedger: LedgerDestination {
    let kind: LedgerDestinationKind = .githubPR

    private enum Key {
        static let owner = "githubOwner"
        static let repo = "githubRepo"
        static let token = "githubToken"   // Keychain account
    }

    /// Root folder everything scanned lives under. Each receipt gets its own
    /// subfolder, `<merchant>-<yyyymmdd>-<sha8>/`, holding
    /// `<merchant>-<yyyymmdd>-<hhmm>-<sha8>.{beancount,json,jpg}` — so a PR
    /// review shows exactly what was scanned, without touching a shared file.
    nonisolated static let rootDir = "beanbeaver_receipts"

    var owner: String { didSet { UserDefaults.standard.set(owner, forKey: Key.owner) } }
    var repo: String { didSet { UserDefaults.standard.set(repo, forKey: Key.repo) } }

    /// Backed by the Keychain, not UserDefaults. `token`'s presence flips
    /// `hasToken`, which the settings UI observes.
    var token: String {
        didSet { Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Key.token) }
    }

    init() {
        let d = UserDefaults.standard
        owner = d.string(forKey: Key.owner) ?? ""
        repo = d.string(forKey: Key.repo) ?? ""
        token = Keychain.get(Key.token) ?? ""
    }

    var isConfigured: Bool {
        !owner.trimmed.isEmpty && !repo.trimmed.isEmpty && !token.trimmed.isEmpty
    }

    func append(_ entry: LedgerEntry) async throws -> LedgerExportOutcome {
        guard isConfigured else {
            throw LedgerExportError("GitHub isn't fully set up. Connect and pick a repo in Settings › Sync.")
        }
        // `<merchant>-<yyyymmdd|unknowndate>-<sha8>`: the identity token is the
        // same one baked into the transaction and `document.relpath`, so this
        // parse can't disagree with what's already on the receipt.
        guard let idParts = entry.beanbeaverId?.split(separator: "-").map(String.init),
              idParts.count == 3 else {
            throw LedgerExportError("This receipt has no captured photo to derive an identity from — can't file it under GitHub.")
        }
        let (dateToken, sha8) = (idParts[1], idParts[2])
        let cfg = Config(owner: owner.trimmed, repo: repo.trimmed, token: token.trimmed)
        let url = try await Self.openPullRequest(cfg: cfg, entry: entry,
                                                 merchantSlug: entry.merchantSlug,
                                                 dateToken: dateToken, sha8: sha8)
        return .pullRequest(url: url)
    }

    // MARK: - REST flow

    private struct Config {
        let owner, repo, token: String
    }

    private nonisolated static func openPullRequest(
        cfg: Config, entry: LedgerEntry, merchantSlug: String, dateToken: String, sha8: String
    ) async throws -> URL {
        let repoRoot = "/repos/\(cfg.owner)/\(cfg.repo)"

        // 0. The repo's default branch — we always target it (no branch to pick).
        let repoInfo: RepoResponse = try await api(cfg, "GET", repoRoot)
        let base = repoInfo.defaultBranch

        // 1. Head commit of the base branch.
        let ref: RefResponse = try await api(cfg, "GET", "\(repoRoot)/git/ref/heads/\(base)")
        let baseSha = ref.object.sha

        // 2. New branch off the base head.
        let stamp = branchStamp()
        let branch = "beanbeaver/receipt-\(stamp)"
        let _: RefResponse = try await api(cfg, "POST", "\(repoRoot)/git/refs",
            body: ["ref": "refs/heads/\(branch)", "sha": baseSha])

        // 3. One folder per receipt: beanbeaver_receipts/<merchant>-<date>-<sha8>/,
        //    holding <merchant>-<date>-<hhmm>-<sha8>.{beancount,json,jpg}.
        let folder = "\(rootDir)/\(merchantSlug)-\(dateToken)-\(sha8)"
        let basename = "\(merchantSlug)-\(dateToken)-\(hhmm())-\(sha8)"

        try await putFileIfAbsent(cfg, repoRoot: repoRoot, path: "\(folder)/\(basename).beancount",
                                  data: Data(entry.beancount.utf8), branch: branch,
                                  message: "BeanBeaver: add receipt transaction")
        if let json = entry.json {
            try await putFileIfAbsent(cfg, repoRoot: repoRoot, path: "\(folder)/\(basename).json",
                                      data: json, branch: branch,
                                      message: "BeanBeaver: add receipt JSON")
        }
        if let document = entry.document {
            try await putFileIfAbsent(cfg, repoRoot: repoRoot, path: "\(folder)/\(basename).jpg",
                                      data: document.data, branch: branch,
                                      message: "BeanBeaver: add receipt image")
        }

        // 4. Open the PR.
        let pr: PullResponse = try await api(cfg, "POST", "\(repoRoot)/pulls", body: [
            "title": "Add receipt: \(merchantSlug) \(dateToken)",
            "head": branch,
            "base": base,
            "body": "Filed a scanned receipt under `\(folder)/` with BeanBeaver iOS.",
        ])
        guard let url = URL(string: pr.htmlUrl) else {
            throw LedgerExportError("Pull request created but its URL was missing.")
        }
        return url
    }

    /// Create `path` on `branch` with `data` if it's not already there. Every
    /// path here is content-addressed (the sha8 token), so an existing file is
    /// necessarily identical — skip it, keeping re-exports idempotent.
    private nonisolated static func putFileIfAbsent(
        _ cfg: Config, repoRoot: String, path: String, data: Data, branch: String, message: String
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
            "message": message,
            "content": data.base64EncodedString(),
            "branch": branch,
        ])
    }

    private nonisolated static func branchStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// Export-time hour+minute (`HHmm`) for the file basename — receipts only
    /// carry a date, so the time distinguishes files if the same receipt is
    /// re-exported later.
    private nonisolated static func hhmm() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmm"
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // A transport failure (dropped connection, timeout, offline) throws
            // before there's any HTTP response to inspect — without the method
            // and path here, "the network connection was lost" gives no clue
            // which of the PR flow's several requests actually failed.
            let nsError = error as NSError
            throw LedgerExportError(
                "GitHub \(method) \(pathAndQuery) failed: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw LedgerExportError("No response from GitHub \(method) \(pathAndQuery).")
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
    private struct RepoResponse: Decodable {
        let defaultBranch: String
        enum CodingKeys: String, CodingKey { case defaultBranch = "default_branch" }
    }
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
