import Foundation
import Observation

/// GitHub OAuth **Device Flow** — lets the user connect their GitHub account by
/// authorizing in the browser instead of pasting a personal access token, with
/// no backend and no embedded secret (device flow needs only the public
/// `client_id`). This is the same mechanism the `gh` CLI uses.
///
/// Setup (one-time, by the maintainer): register an OAuth App at
/// https://github.com/settings/developers, tick **Enable Device Flow**, and
/// paste its Client ID into `GitHubOAuth.clientID`. No client secret is used.
enum GitHubOAuth {
    /// Public OAuth App client ID — safe to ship (it is not a secret). Empty
    /// until the app is registered; `GitHubConnection` falls back to the manual
    /// token field while this is blank.
    static let clientID = ""   // TODO: paste the OAuth App Client ID here

    /// `repo` covers creating PRs on both public and private ledger repos.
    static let scope = "repo"

    static var isConfigured: Bool { !clientID.isEmpty }

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
            throw FlowError("GitHub sign-in isn't set up in this build. Enter a token manually instead.")
        }
        let body = "client_id=\(clientID)&scope=\(scope)"
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
}

/// Drives the connect UI: request a code, open the browser, poll for the token,
/// and hand it back. Lives for the duration of a single connect attempt.
@Observable
@MainActor
final class GitHubConnection {
    enum Phase: Equatable {
        case idle
        case starting
        case awaitingAuthorization(userCode: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .starting, .awaitingAuthorization: return true
        case .idle, .failed: return false
        }
    }

    /// Run the whole flow; on success `onToken` receives the access token.
    /// `openURL` is used to launch the GitHub authorization page.
    func connect(openURL: @escaping (URL) -> Void, onToken: @escaping (String) -> Void) {
        guard !isBusy else { return }
        phase = .starting
        task = Task {
            do {
                let device = try await GitHubOAuth.requestDeviceCode()
                phase = .awaitingAuthorization(userCode: device.userCode)
                openURL(device.verificationURIComplete ?? device.verificationURI)
                let token = try await GitHubOAuth.pollForToken(device)
                onToken(token)
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(message)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}
