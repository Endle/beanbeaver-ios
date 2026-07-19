import SwiftUI
import UIKit
import UniformTypeIdentifiers
import BBReceiptKit

/// Configure where scanned transactions are sent: a synced `.bean` file (Files /
/// iCloud / Dropbox / …) and/or a GitHub pull request. Reached from Settings.
struct LedgerSettingsView: View {
    @Bindable var exporter: LedgerExporter
    // Ledger inbox file (Files/iCloud/Dropbox/…) is disabled for now — it will
    // be back in a future version. GitHub PR is the only export option meanwhile.
    // @State private var showFileImporter = false
    // @State private var importError: String?
    @State private var connection = GitHubConnection()
    @State private var codeCopied = false
    @State private var repoState: RepoState = .idle
    /// Live write-access check for the selected repo (picker or hand-typed),
    /// shown as the green "Ready" / amber / red status under the Repository row.
    @State private var access: AccessCheck = .idle
    /// The signed-in account's login, for the "Connected as @…" line.
    @State private var accountLogin: String?
    /// Set when we hand off to GitHub's install page from Advanced, so returning
    /// reloads the repo list — and only then, not on every incidental foreground.
    @State private var didOpenInstall = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Account the Money Manager export files its rows under. Key matches
    /// `MoneyManagerExport.accountKey`; default `MoneyManagerExport.defaultAccount`.
    @AppStorage("moneyManagerAccount") private var moneyManagerAccount = "Cash"

    private enum RepoState {
        case idle, loading
        case loaded([GitHubApp.Repo])
        case failed(String)
    }

    private enum AccessCheck: Equatable {
        case idle, checking
        case ok(branch: String)
        case noWrite
        case failed(String)
    }

    /// Label for an exporter in the picker — its name, plus a lock when it's a
    /// premium exporter that isn't unlocked yet (shown rather than hidden, so a
    /// GitHub-only user still sees Money Manager exists without any friction).
    private func exporterLabel(_ option: ExportTarget) -> String {
        var label = option.label
        if option.requiresPremium && !Entitlements.isPremium { label += " 🔒" }
        return label
    }

    var body: some View {
        List {
            // Pick one exporter and show only its detail below, so the page stays
            // short as downstream targets (Money Manager, later Files/Dropbox…) are
            // added rather than stacking every one's config. A menu picker keeps it
            // compact as the list grows past what segments could hold.
            Section {
                Picker("Export receipts to", selection: $exporter.selectedTarget) {
                    ForEach(ExportTarget.allCases) { option in
                        Text(exporterLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            // Ledger inbox file (Files/iCloud/Dropbox/…) is disabled for now — it
            // will be back in a future version. Re-enable `filesSection` (and the
            // .fileImporter/.alert modifiers) to bring it back as another case.
            switch exporter.selectedTarget {
            case .github:
                gitHubSection
            case .moneyManager:
                if Entitlements.isPremium {
                    moneyManagerSection
                } else {
                    moneyManagerLockedSection
                }
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        // Keyed on the token: load the account + repos once connected, and clear
        // them on disconnect so nothing sits stale behind a signed-out account.
        .task(id: exporter.github.token) {
            guard isGitHubConnected else {
                repoState = .idle; accountLogin = nil; return
            }
            accountLogin = try? await GitHubApp.fetchLogin(token: exporter.github.token)
            await loadRepos()
        }
        // Auto-verify whatever repo is selected (picker or typed by hand) so the
        // user gets an affirmative "Ready — PRs target <branch>" instead of
        // discovering a bad choice as a 404 at export time. Re-runs on every
        // connection/repo change; `verifyAccess` debounces manual typing.
        .task(id: accessKey) {
            await verifyAccess()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if case .needsInstall = connection.phase {
                // Returned from installing during the connect flow — finish
                // automatically, no "I've Installed It" tap needed.
                connection.recheckInstallation()
            } else if didOpenInstall, isGitHubConnected {
                // Returned from "Install on Another Repository…" — pull the updated
                // list so the new repo is selectable without a manual Refresh.
                didOpenInstall = false
                Task { await loadRepos() }
            }
        }
        // .fileImporter(isPresented: $showFileImporter,
        //               allowedContentTypes: [.plainText, .text, .data]) { result in
        //     switch result {
        //     case .success(let url):
        //         do { try exporter.filesInbox.setDestination(url) }
        //         catch { importError = String(describing: error) }
        //     case .failure(let error):
        //         importError = error.localizedDescription
        //     }
        // }
        // .alert("Couldn't use that file", isPresented: Binding(
        //     get: { importError != nil }, set: { if !$0 { importError = nil } })) {
        //     Button("OK", role: .cancel) {}
        // } message: { Text(importError ?? "") }
    }

    // MARK: - Files inbox
    //
    // Disabled for now — it will be back in a future version.
    //
    // private var filesSection: some View {
    //     Section {
    //         if let name = exporter.filesInbox.fileName {
    //             LabeledContent("File", value: name)
    //             Button("Choose a Different File…") { showFileImporter = true }
    //             Button("Remove", role: .destructive) { exporter.filesInbox.clear() }
    //         } else {
    //             Button("Choose Ledger File…") { showFileImporter = true }
    //         }
    //     } header: {
    //         Label(LedgerDestinationKind.filesInbox.title, systemImage: LedgerDestinationKind.filesInbox.systemImage)
    //     } footer: {
    //         Text("Pick a `.bean` file kept in any Files provider (iCloud Drive, Dropbox, Box…). New transactions are appended to it. `include` it from your main ledger.\n\nTip: create the (even empty) file in the Files app first, then pick it here.")
    //     }
    // }

    // MARK: - GitHub

    /// The whole GitHub destination: the authorized account (axis 1), the repo it
    /// writes to with its verified status (axis 2), then the escape hatches folded
    /// into Advanced.
    private var gitHubSection: some View {
        Section {
            if isGitHubConnected {
                accountRow          // who: the authorized account
                repositoryRow       // where: the repo + its auto-verified status
                advancedSection     // escape hatches: install elsewhere, type by hand
            } else {
                gitHubConnectFlow
            }
        } header: {
            Label(LedgerDestinationKind.githubPR.title, systemImage: LedgerDestinationKind.githubPR.systemImage)
        } footer: {
            // Once connected, the walkthrough is spent text — keep only what's
            // still true.
            if isGitHubConnected {
                Text("Each export opens a pull request against the repository's default branch. Only repositories BeanBeaver is installed on are listed. The token is stored in the device Keychain.")
            } else {
                Text("Each export opens a pull request that appends the transaction to the ledger file on the repo's default branch. Connect your GitHub account: authorize in the browser, then install BeanBeaver on the one repo you pick — it can't touch your other repos. The token is stored in the device Keychain.")
            }
        }
    }

    /// Money Manager (Realbyte) `.xlsx` export — a downstream output managed here
    /// on the Export page next to the ledger destinations. The export itself runs on
    /// demand from a receipt's (or the batch's) share menu; this only configures
    /// the account its rows are filed under.
    private var moneyManagerSection: some View {
        Section {
            TextField("Account name", text: $moneyManagerAccount)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        } header: {
            Label("Money Manager", systemImage: "tablecells")
        } footer: {
            Text("Export a scanned receipt — or a whole photo batch — to a Money Manager Excel file from its share menu, then import it in Money Manager via More → Backup → Import excel file. Rows are filed under this account, so use the exact account name from that app. Categories are best-effort; you may need to match them after importing.")
        }
    }

    /// Non-premium view of the Money Manager exporter — shown in place of the
    /// account field so a locked user still sees what it is. No purchase flow yet
    /// (premium is open through the TestFlight phase), so this is informational.
    private var moneyManagerLockedSection: some View {
        Section {
            Label("Premium feature", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        } header: {
            Label("Money Manager", systemImage: "tablecells")
        } footer: {
            Text("Exporting scanned receipts to a Money Manager Excel file is a premium feature.")
        }
    }

    private var isGitHubConnected: Bool {
        !exporter.github.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "owner/repo" once both are set, else nil.
    private var chosenRepo: String? {
        let owner = exporter.github.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = exporter.github.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty || repo.isEmpty ? nil : "\(owner)/\(repo)"
    }

    /// The repo, or a generic fallback for the install prompt.
    private var repoLabel: String { chosenRepo ?? "your ledger repo" }

    /// Re-verify whenever the connection or the chosen repo changes.
    private var accessKey: String { "\(isGitHubConnected)|\(chosenRepo ?? "")" }

    /// Axis 1 — the authorized account: who BeanBeaver acts as, plus disconnect.
    /// Kept distinct from the repository below (axis 2), which is a separate grant.
    @ViewBuilder
    private var accountRow: some View {
        HStack {
            Label {
                Text(accountLogin.map { "Connected as @\($0)" } ?? "GitHub connected")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            Button("Disconnect", role: .destructive) {
                connection.cancel()
                exporter.github.token = ""
                accountLogin = nil
                access = .idle
            }
        }
    }

    /// Axis 2 — which repo to write to: a menu of the repos BeanBeaver is
    /// installed on, a refresh at the trailing edge, and the auto-verified status
    /// beneath. Installation *is* the write grant, so listed repos are known
    /// writable; the status still runs, both to show the PR target branch and to
    /// catch a repo that isn't actually reachable before export time.
    @ViewBuilder
    private var repositoryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Repository")
                Spacer()
                refreshControl
            }
            // Show the repo the receipts land in. Try to write down the FULL
            // "owner/repo": give it the whole row width and let it wrap to two or
            // more lines rather than middle-truncate to "owner/rea…name" — the
            // repo name is the one thing here the user most needs to read in full
            // to confirm their choice, so height is cheaper than hiding it.
            switch repoState {
            case .idle, .loading:
                Text("Loading…").foregroundStyle(.secondary)
            case .failed:
                Text(repoSelection.wrappedValue?.fullName ?? "Unavailable")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let repos):
                if repos.isEmpty && repoSelection.wrappedValue == nil {
                    Text("None installed").foregroundStyle(.secondary)
                } else {
                    repoMenu(repos)
                }
            }
        }
        // The installation list itself failed to load — say why, right under the
        // row. The refresh control doubles as the retry.
        if case .failed(let message) = repoState {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.footnote)
        }
        accessStatus
    }

    /// The repo dropdown as a `Menu` (not a full-row `Picker`) so its label can
    /// take the full row width and wrap to the complete repo name, and so it stays
    /// independently tappable from the refresh button in the same List row
    /// (`.borderless`).
    private func repoMenu(_ repos: [GitHubApp.Repo]) -> some View {
        Menu {
            Picker("Repository", selection: repoSelection) {
                Text("Choose…").tag(GitHubApp.Repo?.none)
                ForEach(repoOptions(repos)) { repo in
                    Text(repo.fullName).tag(GitHubApp.Repo?.some(repo))
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // Wrap, never truncate — try our best to write down the full repo
                // name so the user can confirm the exact "owner/repo" at a glance.
                Text(repoSelection.wrappedValue?.fullName ?? "Choose…")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(repoSelection.wrappedValue == nil ? Color.accentColor : .primary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }

    /// A spinner while the list loads, otherwise the refresh/retry button.
    @ViewBuilder
    private var refreshControl: some View {
        switch repoState {
        case .idle, .loading:
            ProgressView()
        case .loaded, .failed:
            Button {
                Task { await loadRepos() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh repository list")
        }
    }

    /// The affirmative status under the Repository row: green once the selected
    /// repo is confirmed writable (with its PR target branch), amber/red when it
    /// isn't. Empty until a repo is chosen.
    @ViewBuilder
    private var accessStatus: some View {
        switch access {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView(); Text("Checking access…").foregroundStyle(.secondary) }
                .font(.footnote)
        case .ok(let branch):
            Label("Ready — pull requests will target \(branch).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.footnote)
        case .noWrite:
            Label("Reachable, but no write access — install BeanBeaver on this repo with Contents + Pull requests write.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.footnote)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.footnote)
        }
    }

    /// The escape hatches, tucked away since they're rare next to picking a repo:
    /// grant a new repo on GitHub, or type an `owner/repo` the list can't show.
    /// Both feed the same selection, so the Repository status above verifies them
    /// — no separate Verify button.
    @ViewBuilder
    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            if let installURL = GitHubApp.installURL {
                Button {
                    didOpenInstall = true
                    openURL(installURL)
                } label: {
                    Label("Install on Another Repository…", systemImage: "square.and.arrow.down")
                }
            }
            TextField("Owner (you or an org)", text: $exporter.github.owner)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Repository", text: $exporter.github.repo)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Text("Type a repository by hand if it isn't in the list above.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Bridges the picker to the two stored strings. Selecting "Choose…" (nil)
    /// clears them, which is the only way back to an unset repo.
    private var repoSelection: Binding<GitHubApp.Repo?> {
        Binding(
            get: {
                let owner = exporter.github.owner.trimmingCharacters(in: .whitespacesAndNewlines)
                let repo = exporter.github.repo.trimmingCharacters(in: .whitespacesAndNewlines)
                return owner.isEmpty || repo.isEmpty ? nil : GitHubApp.Repo(owner: owner, name: repo)
            },
            set: { selection in
                exporter.github.owner = selection?.owner ?? ""
                exporter.github.repo = selection?.name ?? ""
            }
        )
    }

    /// A repo set by hand won't be in the installation list; without it as an
    /// option the picker would have no tag to match and would render blank.
    private func repoOptions(_ repos: [GitHubApp.Repo]) -> [GitHubApp.Repo] {
        guard let chosen = repoSelection.wrappedValue, !repos.contains(chosen) else { return repos }
        return [chosen] + repos
    }

    @MainActor
    private func loadRepos() async {
        repoState = .loading
        do {
            let repos = try await GitHubApp.listInstallationRepos(token: exporter.github.token)
            repoState = .loaded(repos)
            // Almost everyone installs on exactly one ledger repo — pick it so the
            // common case needs no menu tap. Only fills an unset choice, so a repo
            // the user already picked (or typed manually) is left alone.
            if repos.count == 1, repoSelection.wrappedValue == nil {
                repoSelection.wrappedValue = repos[0]
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DebugInfoStore.recordExportFailure(context: "load GitHub repos", message: message)
            repoState = .failed(message)
        }
    }

    /// Confirm the connected token can reach the selected repo and describe the
    /// access — the source of the green "Ready" line. Debounced: manual typing
    /// re-keys `accessKey` on every keystroke, and the sleep is cancelled when the
    /// id changes, so only a repo left alone for a beat actually hits the network.
    @MainActor
    private func verifyAccess() async {
        let owner = exporter.github.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = exporter.github.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGitHubConnected, !owner.isEmpty, !repo.isEmpty else { access = .idle; return }
        access = .checking
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        do {
            let result = try await GitHubApp.checkRepoAccess(
                owner: owner, repo: repo, token: exporter.github.token)
            access = result.canPush ? .ok(branch: result.defaultBranch) : .noWrite
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DebugInfoStore.recordExportFailure(context: "verify repo access", message: message)
            access = .failed(message)
        }
    }

    /// The connect flow before a token exists: one Connect button that walks
    /// through the device-code and install steps.
    @ViewBuilder
    private var gitHubConnectFlow: some View {
        switch connection.phase {
        case .awaitingAuthorization(let code):
            VStack(alignment: .leading, spacing: 10) {
                Text("Authorize in the browser that just opened, then come back. Enter this code if GitHub asks for it — tap to copy:")
                    .font(.footnote)
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { codeCopied = true }
                } label: {
                    HStack(spacing: 12) {
                        Text(code)
                            .font(.system(.title, design: .monospaced).weight(.bold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: codeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(codeCopied ? .green : .accentColor)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(codeCopied ? "Code copied" : "Copy code \(code)")
                HStack(spacing: 6) { ProgressView(); Text("Waiting for authorization…").font(.footnote) }
            }
            Button("Cancel", role: .cancel) { connection.cancel() }
        case .starting:
            HStack { ProgressView(); Text("Contacting GitHub…") }
        case .verifyingInstall:
            HStack { ProgressView(); Text("Checking repository access…") }
        case .needsInstall(let installURL):
            VStack(alignment: .leading, spacing: 6) {
                Text("Almost done. Install BeanBeaver on \(repoLabel) so it can open pull requests there — and only there.")
                    .font(.footnote)
            }
            Button {
                openURL(installURL)
            } label: {
                Label("Install on Your Repo", systemImage: "square.and.arrow.down")
            }
            Button("I've Installed It — Continue") { connection.recheckInstallation() }
            Button("Cancel", role: .cancel) { connection.cancel() }
        case .idle, .failed:
            Button {
                codeCopied = false
                connection.connect(openURL: { openURL($0) }) { token in
                    exporter.github.token = token
                    deduceOwnerIfNeeded(token: token)
                }
            } label: {
                Label("Connect GitHub", systemImage: "person.badge.key")
            }
            .disabled(!GitHubApp.isConfigured)
            if case .failed(let message) = connection.phase {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// After connecting, default the owner to the signed-in account's login so
    /// the user doesn't have to type it. Only fills a blank field, so an org
    /// owner the user already entered is never overwritten.
    private func deduceOwnerIfNeeded(token: String) {
        guard exporter.github.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            guard exporter.github.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let login = try? await GitHubApp.fetchLogin(token: token) else { return }
            exporter.github.owner = login
        }
    }
}

/// A file to hand to the system share sheet, wrapped so `.sheet(item:)` has a
/// stable identity to key on.
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Thin SwiftUI wrapper over `UIActivityViewController` for sharing a file — the
/// share sheet's "Save to Files" / AirDrop / "Open in…" is how the Money Manager
/// `.xlsx` reaches that app's importer. Presented from a parent's `.sheet(item:)`
/// rather than from inside a `Menu`, where a `ShareLink` would eagerly rebuild
/// its payload on every render.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The set of export actions offered for a parsed result: one button per
/// configured destination, a Money Manager `.xlsx` export, a Share fallback, and
/// a shortcut to set up export. Shared by the result card and the toolbar menu so
/// they never drift.
struct LedgerExportButtons: View {
    let result: ReceiptResult
    /// The captured JPEG on disk, if any — read (off the render pass, at tap
    /// time) into the `LedgerEntry` so it travels alongside the transaction.
    var imageURL: URL?
    /// Swift-observed total scan time, folded into the exported JSON sidecar's
    /// timings alongside the Rust per-stage breakdown.
    var wallMs: Double?
    @Bindable var exporter: LedgerExporter
    var onConfigure: () -> Void
    var onViewJSON: () -> Void = {}
    /// Build the Money Manager `.xlsx` and present its share sheet. Handled by the
    /// parent (not here) so the sheet isn't anchored to this transient `Menu`.
    var onExportMoneyManager: () -> Void = {}

    var body: some View {
        ForEach(exporter.configuredKinds) { kind in
            Button {
                let entry = LedgerEntry.make(from: result, imageURL: imageURL, wallMs: wallMs)
                Task { await exporter.export([entry], to: kind) }
            } label: {
                Label(kind.title, systemImage: kind.systemImage)
            }
            .disabled(exporter.runningKind != nil)
        }

        // Premium: hidden entirely for free users (no lock, no paywall). One
        // gate — `Entitlements.isPremium` — so the eventual purchase check lands
        // in a single place.
        if Entitlements.isPremium {
            Button {
                onExportMoneyManager()
            } label: {
                Label("Export to Money Manager", systemImage: "tablecells")
            }
        }

        ShareLink(item: result.beancount) {
            Label("Share / Copy", systemImage: "square.and.arrow.up")
        }

        Button {
            onViewJSON()
        } label: {
            Label("Read the JSON", systemImage: "curlybraces")
        }

        Button {
            onConfigure()
        } label: {
            Label(exporter.configuredKinds.isEmpty ? "Set Up Export…" : "Export Settings…",
                  systemImage: "gearshape")
        }
    }
}
