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

    func append(_ entries: [LedgerEntry]) async throws -> LedgerExportOutcome {
        guard isConfigured else {
            throw LedgerExportError("GitHub isn't fully set up. Connect and pick a repo in Settings › Sync.")
        }
        let filings = try entries.map(Filing.init)
        let cfg = Config(owner: owner.trimmed, repo: repo.trimmed, token: token.trimmed)
        let url = try await Self.openPullRequest(cfg: cfg, filings: filings)
        return .pullRequest(url: url, count: filings.count)
    }

    // MARK: - REST flow

    private struct Config {
        let owner, repo, token: String
    }

    /// One file destined for the repo, with the commit message that carries it.
    private struct RepoFile {
        let path: String
        let data: Data
        let message: String
    }

    /// One receipt resolved to where it lands in the repo. Splitting this out of
    /// the REST flow means a batch fails before it creates a branch if any one
    /// receipt is unfilable, rather than stranding a half-populated branch.
    private struct Filing {
        let entry: LedgerEntry
        let folder: String
        let basename: String
        let dateToken: String

        /// What this receipt contributes to the repo, in commit order.
        var files: [RepoFile] {
            var out = [RepoFile(path: "\(folder)/\(basename).beancount",
                                data: Data(entry.beancount.utf8),
                                message: "BeanBeaver: add receipt transaction")]
            if let json = entry.json {
                out.append(RepoFile(path: "\(folder)/\(basename).json", data: json,
                                    message: "BeanBeaver: add receipt JSON"))
            }
            if let document = entry.document {
                out.append(RepoFile(path: "\(folder)/\(basename).jpg", data: document.data,
                                    message: "BeanBeaver: add receipt image"))
            }
            return out
        }

        init(_ entry: LedgerEntry) throws {
            // `<merchant>-<yyyymmdd|unknowndate>-<sha8>`: the identity token is
            // the same one baked into the transaction and `document.relpath`, so
            // this parse can't disagree with what's already on the receipt.
            guard let idParts = entry.beanbeaverId?.split(separator: "-").map(String.init),
                  idParts.count == 3 else {
                throw LedgerExportError("This receipt has no captured photo to derive an identity from — can't file it under GitHub.")
            }
            self.entry = entry
            dateToken = idParts[1]
            let sha8 = idParts[2]
            // One folder per receipt: beanbeaver_receipts/<merchant>-<date>-<sha8>/,
            // holding <merchant>-<date>-<hhmm>-<sha8>.{beancount,json,jpg}.
            folder = "\(rootDir)/\(entry.merchantSlug)-\(dateToken)-\(sha8)"
            basename = "\(entry.merchantSlug)-\(dateToken)-\(hhmm())-\(sha8)"
        }
    }

    /// The whole batch goes onto one branch and into one pull request: a PR is a
    /// review unit, and a receipt per PR would make a pile of receipts a pile of
    /// PRs to merge one by one.
    private nonisolated static func openPullRequest(
        cfg: Config, filings: [Filing]
    ) async throws -> URL {
        let repoRoot = "/repos/\(cfg.owner)/\(cfg.repo)"

        // 0. The repo's default branch — we always target it (no branch to pick).
        let repoInfo: RepoResponse = try await api(cfg, "GET", repoRoot)
        let base = repoInfo.defaultBranch

        // 1. Head commit of the base branch.
        let ref: RefResponse = try await api(cfg, "GET", "\(repoRoot)/git/ref/heads/\(base)")
        let baseSha = ref.object.sha

        // 2. Work out what's actually missing before touching anything. Checked
        //    against `base`, which a fresh branch is a copy of, so the answer is
        //    the same — but doing it first means a batch of receipts already in
        //    the repo doesn't leave an orphan branch behind, and reports itself
        //    instead of failing later on GitHub's "no commits between" for a PR
        //    with an empty diff.
        var pending: [RepoFile] = []
        for file in filings.flatMap(\.files) {
            if try await fileExists(cfg, repoRoot: repoRoot, path: file.path, ref: base) { continue }
            pending.append(file)
        }
        guard !pending.isEmpty else {
            throw LedgerExportError(filings.count == 1
                ? "This receipt is already filed in the repo — nothing to open a pull request for."
                : "All \(filings.count) receipts are already filed in the repo — nothing to open a pull request for.")
        }

        // 3. New branch off the base head.
        let stamp = branchStamp()
        let branch = "beanbeaver/receipt-\(stamp)"
        let _: RefResponse = try await api(cfg, "POST", "\(repoRoot)/git/refs",
            body: ["ref": "refs/heads/\(branch)", "sha": baseSha])

        // 4. One folder per receipt (see `Filing`), one commit per file — the
        //    contents API has no way to put several files in a single commit.
        for file in pending {
            try await putFile(cfg, repoRoot: repoRoot, file: file, branch: branch)
        }

        // 5. Open the PR.
        let pr: PullResponse = try await api(cfg, "POST", "\(repoRoot)/pulls", body: [
            "title": title(for: filings),
            "head": branch,
            "base": base,
            "body": prBody(for: filings),
        ])
        guard let url = URL(string: pr.htmlUrl) else {
            throw LedgerExportError("Pull request created but its URL was missing.")
        }
        return url
    }

    private nonisolated static func title(for filings: [Filing]) -> String {
        guard let only = filings.first, filings.count == 1 else {
            return "Add \(filings.count) receipts"
        }
        return "Add receipt: \(only.entry.merchantSlug) \(only.dateToken)"
    }

    private nonisolated static func prBody(for filings: [Filing]) -> String {
        guard let only = filings.first, filings.count == 1 else {
            return "Filed \(filings.count) scanned receipts with BeanBeaver iOS.\n\n"
                + filings.map { "- `\($0.folder)/`" }.joined(separator: "\n")
        }
        return "Filed a scanned receipt under `\(only.folder)/` with BeanBeaver iOS."
    }

    /// Whether `path` already exists at `ref`. Every path here is
    /// content-addressed (the sha8 token), so a file that's present is
    /// necessarily identical — which is what keeps re-exports idempotent.
    private nonisolated static func fileExists(
        _ cfg: Config, repoRoot: String, path: String, ref: String
    ) async throws -> Bool {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        do {
            let _: ContentsResponse = try await api(
                cfg, "GET", "\(repoRoot)/contents/\(escaped)?ref=\(ref)")
            return true
        } catch let e as HTTPStatusError where e.status == 404 {
            return false
        }
    }

    private nonisolated static func putFile(
        _ cfg: Config, repoRoot: String, file: RepoFile, branch: String
    ) async throws {
        let escaped = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        let _: PutResponse = try await api(cfg, "PUT", "\(repoRoot)/contents/\(escaped)", body: [
            "message": file.message,
            "content": file.data.base64EncodedString(),
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
