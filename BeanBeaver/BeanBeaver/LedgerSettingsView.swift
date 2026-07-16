import SwiftUI
import UIKit
import UniformTypeIdentifiers
import BBReceiptKit

/// Configure where scanned transactions are sent: a synced `.bean` file (Files /
/// iCloud / Dropbox / …) and/or a GitHub pull request. Reached from Settings.
struct LedgerSettingsView: View {
    @Bindable var exporter: LedgerExporter
    // Ledger inbox file (Files/iCloud/Dropbox/…) is disabled for now — it will
    // be back in a future version. GitHub PR is the only sync option meanwhile.
    // @State private var showFileImporter = false
    // @State private var importError: String?
    @State private var connection = GitHubConnection()
    @State private var codeCopied = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            // Ledger inbox file (Files/iCloud/Dropbox/…) is disabled for now —
            // it will be back in a future version. Re-enable `filesSection`
            // below (and the .fileImporter/.alert modifiers) to bring it back.
            // filesSection
            gitHubSection
        }
        .navigationTitle("Ledger Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
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

    private var gitHubSection: some View {
        Section {
            if isGitHubConnected {
                gitHubConnectedRows
                repoConfigRows
            } else {
                gitHubConnectFlow
            }
        } header: {
            Label(LedgerDestinationKind.githubPR.title, systemImage: LedgerDestinationKind.githubPR.systemImage)
        } footer: {
            Text("Each export opens a pull request that appends the transaction to the ledger file on the repo's default branch. Connect your GitHub account: authorize in the browser, then install BeanBeaver on the one repo you pick — it can't touch your other repos. The token is stored in the device Keychain.")
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

    /// Account status + disconnect, shown once a token is stored.
    @ViewBuilder
    private var gitHubConnectedRows: some View {
        HStack {
            Label("GitHub connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Spacer()
            Button("Disconnect", role: .destructive) {
                connection.cancel()
                exporter.github.token = ""
            }
        }
    }

    /// Which repo to write to — picked from the ones BeanBeaver is installed on
    /// rather than typed. The path each receipt lands at within the repo is fixed
    /// (`GitHubLedger.rootDir`), so it isn't asked for.
    @ViewBuilder
    private var repoConfigRows: some View {
        NavigationLink {
            RepoPickerView(github: exporter.github)
        } label: {
            LabeledContent("Repository", value: chosenRepo ?? "Choose…")
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

/// Pick the ledger repo from the ones BeanBeaver is installed on, instead of
/// typing `owner/repo` from memory.
///
/// The installation *is* the per-repo write grant, so every row here is known to
/// be writable — there's nothing to verify after picking, and a repo the app
/// can't reach can't be chosen by mistake. The list is usually one row (the repo
/// just installed on during the connect flow); it only gets long if the user
/// granted "All repositories" at install time, which is what the filter is for.
struct RepoPickerView: View {
    @Bindable var github: GitHubLedger
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var state: LoadState = .loading
    @State private var search = ""

    private enum LoadState {
        case loading
        case loaded([GitHubApp.Repo])
        case failed(String)
    }

    var body: some View {
        List {
            switch state {
            case .loading:
                HStack(spacing: 8) { ProgressView(); Text("Loading your repositories…") }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.footnote)
                    Button("Try Again") { Task { await loadRepos() } }
                }
            case .loaded(let repos):
                repoSection(repos)
            }
            escapeHatchSection
        }
        .navigationTitle("Repository")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter repositories")
        .task { await loadRepos() }
    }

    @ViewBuilder
    private func repoSection(_ repos: [GitHubApp.Repo]) -> some View {
        let matches = filtered(repos)
        Section {
            if repos.isEmpty {
                Text("BeanBeaver isn't installed on any repository yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if matches.isEmpty {
                Text("No repository matches “\(search)”.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(matches) { repo in
                    Button {
                        choose(repo)
                    } label: {
                        HStack {
                            Text(repo.fullName)
                            Spacer()
                            if isChosen(repo) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .fontWeight(.semibold)
                            }
                        }
                        // Keep the row tappable across the Spacer, not just the text.
                        .contentShape(Rectangle())
                    }
                    // Without this a List button tints its whole label blue; picker
                    // rows want primary text with only the checkmark accented.
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            if !repos.isEmpty {
                Text("Pull requests will target the repository's default branch.")
            }
        }
    }

    @ViewBuilder
    private var escapeHatchSection: some View {
        Section {
            if let installURL = GitHubApp.installURL {
                Button {
                    openURL(installURL)
                } label: {
                    Label("Install on Another Repository…", systemImage: "square.and.arrow.down")
                }
            }
            Button {
                Task { await loadRepos() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            NavigationLink {
                ManualRepoEntryView(github: github)
            } label: {
                Label("Enter Manually…", systemImage: "keyboard")
            }
        } footer: {
            Text("Only repositories BeanBeaver is installed on can be written to, so only those are listed. Just installed it somewhere new? Tap Refresh.")
        }
    }

    private func filtered(_ repos: [GitHubApp.Repo]) -> [GitHubApp.Repo] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(needle) }
    }

    private func isChosen(_ repo: GitHubApp.Repo) -> Bool {
        repo.owner == github.owner && repo.name == github.repo
    }

    private func choose(_ repo: GitHubApp.Repo) {
        github.owner = repo.owner
        github.repo = repo.name
        dismiss()
    }

    @MainActor
    private func loadRepos() async {
        state = .loading
        do {
            state = .loaded(try await GitHubApp.listInstallationRepos(token: github.token))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }
}

/// Escape hatch: type `owner/repo` by hand. Needed when the picker can't show the
/// repo — most likely a stale installation list. Nothing typed here proves the
/// token can write to it, so unlike the picker this path keeps an access check.
struct ManualRepoEntryView: View {
    @Bindable var github: GitHubLedger
    @State private var repoCheck: RepoCheck = .idle

    private enum RepoCheck: Equatable {
        case idle, checking
        case ok(branch: String)
        case failed(String)
    }

    var body: some View {
        List {
            Section {
                TextField("Owner (you or an org)", text: $github.owner)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: github.owner) { repoCheck = .idle }
                TextField("Repository", text: $github.repo)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: github.repo) { repoCheck = .idle }

                Button {
                    verifyRepoAccess()
                } label: {
                    HStack {
                        Label("Verify Access", systemImage: "checkmark.shield")
                        if repoCheck == .checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(verifyDisabled)
                repoCheckStatus
            } footer: {
                Text("Type the owner and repository exactly as they appear on GitHub.")
            }
        }
        .navigationTitle("Enter Manually")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var repoCheckStatus: some View {
        switch repoCheck {
        case .ok(let branch):
            Label("Ready — pull requests will target \(branch).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.footnote)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.footnote)
        case .idle, .checking:
            EmptyView()
        }
    }

    private var verifyDisabled: Bool {
        if repoCheck == .checking { return true }
        return github.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || github.repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Confirm the connected token can actually reach the entered repo, and show
    /// the outcome (green ready / red reason).
    private func verifyRepoAccess() {
        let owner = github.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = github.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repo.isEmpty else { return }
        repoCheck = .checking
        Task { @MainActor in
            do {
                let access = try await GitHubApp.checkRepoAccess(
                    owner: owner, repo: repo, token: github.token)
                repoCheck = access.canPush
                    ? .ok(branch: access.defaultBranch)
                    : .failed("Reachable, but no write access. Install BeanBeaver on this repo with Contents + Pull requests write.")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                repoCheck = .failed(message)
            }
        }
    }
}

/// The set of export actions offered for a parsed result: one button per
/// configured destination, a Share fallback, and a shortcut to set up sync.
/// Shared by the result card and the toolbar menu so they never drift.
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

    var body: some View {
        ForEach(exporter.configuredKinds) { kind in
            Button {
                let entry = LedgerEntry.make(from: result, imageURL: imageURL, wallMs: wallMs)
                Task { await exporter.export(entry, to: kind) }
            } label: {
                Label(kind.title, systemImage: kind.systemImage)
            }
            .disabled(exporter.runningKind != nil)
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
            Label(exporter.configuredKinds.isEmpty ? "Set Up Sync…" : "Sync Settings…",
                  systemImage: "gearshape")
        }
    }
}
