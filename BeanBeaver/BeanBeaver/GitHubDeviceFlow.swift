import Foundation
import Observation

/// GitHub **App** Device Flow — lets the user connect their GitHub account by
/// authorizing in the browser instead of pasting a personal access token, with
/// no backend and no embedded secret (device flow needs only the public
/// `client_id`).
///
/// Why a GitHub App (not an OAuth App): an OAuth App's smallest private-repo
/// scope is `repo`, which grants read/write to *every* private repo the user
/// has. A GitHub App is installed on **just the ledger repo**, so the token can
/// only touch that one repo — the right least-privilege story for a financial
/// ledger. The cost is one extra one-time step: besides authorizing, the user
/// installs the app on their repo (the install *is* the per-repo grant).
///
/// Setup (one-time, by the maintainer): register a GitHub App at
/// https://github.com/settings/apps with permissions **Contents: read/write**
/// and **Pull requests: read/write**, tick **Enable Device Flow**, and leave
/// **Expire user authorization tokens** *off* (so the token never expires and we
/// never need a refresh token / client secret). Paste its **Client ID** into
/// `GitHubApp.clientID` and its **slug** (from the app's public URL,
/// github.com/apps/<slug>) into `GitHubApp.appSlug`.
enum GitHubApp {
    /// Public GitHub App client ID — safe to ship (it is not a secret). Empty
    /// until the app is registered; `GitHubConnection` reports "not set up"
    /// while this is blank.
    static let clientID = "Iv23li8YKsK21kudOvAl"   // GitHub App "beanbeaver-ios", owned by @Endle (App ID 4217098)

    /// The app's public slug, used to build the install URL
    /// (github.com/apps/<slug>/installations/new). Empty until registered; when
    /// blank the install gate is skipped (the token is stored as-is).
    static let appSlug = "beanbeaver-ios"    // github.com/apps/<slug>

    static var isConfigured: Bool { !clientID.isEmpty }

    /// Where to send the user to install the app on their ledger repo. `nil`
    /// when `appSlug` hasn't been set.
    static var installURL: URL? {
        appSlug.isEmpty ? nil : URL(string: "https://github.com/apps/\(appSlug)/installations/new")
    }

    struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        /// GitHub's URL with the code pre-filled — open this so the user only
        /// has to tap "Authorize".
        let verificationURIComplete: URL?
        let interval: Int
        let expiresIn: Int
    }

    struct FlowError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    // MARK: - Step 1: request a device + user code

    static func requestDeviceCode() async throws -> DeviceCode {
        guard isConfigured else {
            throw FlowError("GitHub sign-in isn't set up in this build.")
        }
        // GitHub Apps don't take an OAuth `scope`; permissions come from the app
        // definition and the per-repo installation.
        let body = "client_id=\(clientID)"
        let json = try await postForm("https://github.com/login/device/code", body: body)
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uriString = json["verification_uri"] as? String,
              let uri = URL(string: uriString) else {
            throw FlowError(json["error_description"] as? String ?? "GitHub returned an unexpected device-code response.")
        }
        let complete = (json["verification_uri_complete"] as? String).flatMap(URL.init(string:))
        return DeviceCode(
            deviceCode: deviceCode, userCode: userCode, verificationURI: uri,
            verificationURIComplete: complete,
            interval: (json["interval"] as? Int) ?? 5,
            expiresIn: (json["expires_in"] as? Int) ?? 900)
    }

    // MARK: - Step 2: poll until the user authorizes

    /// Poll the token endpoint until the user authorizes (or the code expires /
    /// is denied). Returns the access token. Cancellable via task cancellation.
    ///
    /// The app is configured with non-expiring user tokens, so the response
    /// carries only `access_token` (no `refresh_token`/`expires_in` to handle).
    static func pollForToken(_ device: DeviceCode) async throws -> String {
        var interval = max(device.interval, 1)
        let deadline = Date().addingTimeInterval(Double(device.expiresIn))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()

            let body = "client_id=\(clientID)&device_code=\(device.deviceCode)"
                + "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            let json = try await postForm("https://github.com/login/oauth/access_token", body: body)

            if let token = json["access_token"] as? String { return token }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = (json["interval"] as? Int) ?? (interval + 5)
            case "access_denied":
                throw FlowError("Authorization was denied.")
            case "expired_token":
                throw FlowError("The code expired before you authorized. Try connecting again.")
            case let other?:
                throw FlowError(json["error_description"] as? String ?? "GitHub error: \(other).")
            case nil:
                throw FlowError("Unexpected response from GitHub while waiting for authorization.")
            }
        }
        throw FlowError("Timed out waiting for authorization.")
    }

    // MARK: - Step 3: confirm the app is installed on a repo

    /// True if the user has at least one installation of this app. A
    /// user-to-server token only ever sees its own app's installations, so a
    /// non-empty list means the app is installed somewhere the user can reach.
    ///
    /// Note: v1 checks only that *an* installation exists, not that the specific
    /// `owner/repo` is among its repositories — a mismatch still surfaces as a
    /// 404 at export time. Good enough while the common case is a single repo.
    static func hasInstallation(token: String) async throws -> Bool {
        let json = try await getJSON("https://api.github.com/user/installations", token: token)
        return ((json["total_count"] as? Int) ?? 0) > 0
    }

    /// The signed-in account's login, used to pre-fill the repo owner.
    static func fetchLogin(token: String) async throws -> String {
        let json = try await getJSON("https://api.github.com/user", token: token)
        guard let login = json["login"] as? String else {
            throw FlowError("Couldn't read your GitHub username.")
        }
        return login
    }

    struct RepoAccess {
        /// The branch pull requests will target.
        let defaultBranch: String
        /// Whether the token can push (i.e. the app is installed here with write).
        let canPush: Bool
    }

    /// Confirm the token can actually reach `owner/repo` and describe the access.
    /// Throws with GitHub's message when the repo isn't found or not accessible
    /// (e.g. the app isn't installed on it).
    static func checkRepoAccess(owner: String, repo: String, token: String) async throws -> RepoAccess {
        let json = try await getJSON("https://api.github.com/repos/\(owner)/\(repo)", token: token)
        guard let defaultBranch = json["default_branch"] as? String else {
            throw FlowError(json["message"] as? String ?? "Repository not found or not accessible.")
        }
        // `permissions` is present for authenticated requests; absent → assume ok.
        let canPush = (json["permissions"] as? [String: Any])?["push"] as? Bool ?? true
        return RepoAccess(defaultBranch: defaultBranch, canPush: canPush)
    }

    // MARK: - Transport

    private static func postForm(_ urlString: String, body: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw FlowError("Bad URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError("Couldn't read GitHub's response.")
        }
        return json
    }

    private static func getJSON(_ urlString: String, token: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw FlowError("Bad URL.") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError("Couldn't read GitHub's response.")
        }
        return json
    }
}

/// Drives the connect UI: request a code, open the browser, poll for the token,
/// confirm the app is installed on a repo, then hand the token back. Lives for
/// the duration of a single connect attempt.
@Observable
@MainActor
final class GitHubConnection {
    enum Phase: Equatable {
        case idle
        case starting
        case awaitingAuthorization(userCode: String)
        case verifyingInstall
        case needsInstall(installURL: URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?
    /// Token held after authorization but before the install gate passes, so the
    /// caller's `onToken` (which stores it) only fires once we're fully connected.
    private var pendingToken: String?
    private var onToken: ((String) -> Void)?

    var isBusy: Bool {
        switch phase {
        case .starting, .awaitingAuthorization, .verifyingInstall: return true
        case .idle, .needsInstall, .failed: return false
        }
    }

    /// Run the whole flow; on success `onToken` receives the access token.
    /// `openURL` is used to launch the GitHub authorization page.
    func connect(openURL: @escaping (URL) -> Void, onToken: @escaping (String) -> Void) {
        guard !isBusy else { return }
        self.onToken = onToken
        phase = .starting
        task = Task {
            do {
                let device = try await GitHubApp.requestDeviceCode()
                phase = .awaitingAuthorization(userCode: device.userCode)
                openURL(device.verificationURIComplete ?? device.verificationURI)
                let token = try await GitHubApp.pollForToken(device)
                await finish(withToken: token)
            } catch is CancellationError {
                phase = .idle
            } catch {
                fail(error)
            }
        }
    }

    /// Called after the user has installed the app (the "Continue" button in the
    /// needs-install state). Re-checks the installation and completes if present.
    func recheckInstallation() {
        guard case .needsInstall = phase, let token = pendingToken else { return }
        phase = .verifyingInstall
        task = Task { await finish(withToken: token) }
    }

    /// Confirm the install gate, then either complete or park in `.needsInstall`.
    private func finish(withToken token: String) async {
        // No slug configured → can't guide an install; accept the token as-is.
        guard let installURL = GitHubApp.installURL else {
            complete(token)
            return
        }
        phase = .verifyingInstall
        do {
            if try await GitHubApp.hasInstallation(token: token) {
                complete(token)
            } else {
                pendingToken = token
                phase = .needsInstall(installURL: installURL)
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            fail(error)
        }
    }

    private func complete(_ token: String) {
        onToken?(token)
        pendingToken = nil
        phase = .idle
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        phase = .failed(message)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingToken = nil
        phase = .idle
    }
}
