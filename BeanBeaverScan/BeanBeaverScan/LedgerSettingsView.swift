import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Configure where scanned transactions are sent: a synced `.bean` file (Files /
/// iCloud / Dropbox / …) and/or a GitHub pull request. Reached from Settings.
struct LedgerSettingsView: View {
    @Bindable var exporter: LedgerExporter
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var connection = GitHubConnection()
    @State private var codeCopied = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            filesSection
            gitHubSection
        }
        .navigationTitle("Ledger Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.plainText, .text, .data]) { result in
            switch result {
            case .success(let url):
                do { try exporter.filesInbox.setDestination(url) }
                catch { importError = String(describing: error) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Couldn't use that file", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    // MARK: - Files inbox

    private var filesSection: some View {
        Section {
            if let name = exporter.filesInbox.fileName {
                LabeledContent("File", value: name)
                Button("Choose a Different File…") { showFileImporter = true }
                Button("Remove", role: .destructive) { exporter.filesInbox.clear() }
            } else {
                Button("Choose Ledger File…") { showFileImporter = true }
            }
        } header: {
            Label(LedgerDestinationKind.filesInbox.title, systemImage: LedgerDestinationKind.filesInbox.systemImage)
        } footer: {
            Text("Pick a `.bean` file kept in any Files provider (iCloud Drive, Dropbox, Box…). New transactions are appended to it. `include` it from your main ledger.\n\nTip: create the (even empty) file in the Files app first, then pick it here.")
        }
    }

    // MARK: - GitHub

    private var gitHubSection: some View {
        Section {
            TextField("Owner (user or org)", text: $exporter.github.owner)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Repository", text: $exporter.github.repo)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("File path (e.g. receipts-inbox.bean)", text: $exporter.github.path)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Base branch", text: $exporter.github.baseBranch)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            gitHubAuthRows
        } header: {
            Label(LedgerDestinationKind.githubPR.title, systemImage: LedgerDestinationKind.githubPR.systemImage)
        } footer: {
            Text("Each export opens a pull request that appends the transaction to the file. Connect your GitHub account: authorize in the browser, then install BeanBeaver on this one repo (it can't touch your other repos). The token is stored in the device Keychain.")
        }
    }

    private var isGitHubConnected: Bool {
        !exporter.github.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "owner/repo" when both are filled in, else a generic fallback for the
    /// install prompt.
    private var repoLabel: String {
        let owner = exporter.github.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = exporter.github.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty || repo.isEmpty ? "your ledger repo" : "\(owner)/\(repo)"
    }

    @ViewBuilder
    private var gitHubAuthRows: some View {
        if isGitHubConnected {
            LabeledContent("Account") {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Button("Disconnect", role: .destructive) {
                connection.cancel()
                exporter.github.token = ""
            }
        } else {
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
    }
}

/// The set of export actions offered for a parsed result: one button per
/// configured destination, a Share fallback, and a shortcut to set up sync.
/// Shared by the result card and the toolbar menu so they never drift.
struct LedgerExportButtons: View {
    let beancount: String
    /// The receipt image's documents-root-relative path (`ReceiptResult
    /// .documentRelpath`) and the captured JPEG on disk. When both are present
    /// the image is stored alongside the transaction so its `document:` link
    /// resolves; otherwise export is text-only.
    var documentRelpath: String?
    var imageURL: URL?
    @Bindable var exporter: LedgerExporter
    var onConfigure: () -> Void

    var body: some View {
        ForEach(exporter.configuredKinds) { kind in
            Button {
                let entry = LedgerEntry(beancount: beancount,
                                        document: Self.makeDocument(relpath: documentRelpath,
                                                                    imageURL: imageURL))
                Task { await exporter.export(entry, to: kind) }
            } label: {
                Label(kind.title, systemImage: kind.systemImage)
            }
            .disabled(exporter.runningKind != nil)
        }

        ShareLink(item: beancount) {
            Label("Share / Copy", systemImage: "square.and.arrow.up")
        }

        Button {
            onConfigure()
        } label: {
            Label(exporter.configuredKinds.isEmpty ? "Set Up Sync…" : "Sync Settings…",
                  systemImage: "gearshape")
        }
    }

    /// Read the captured JPEG so it can travel with the transaction. Deferred to
    /// tap time (not view rendering) to avoid re-reading the file on every body
    /// evaluation. Returns nil (text-only export) if either input is missing or
    /// the bytes can't be read.
    private static func makeDocument(relpath: String?, imageURL: URL?) -> ReceiptDocument? {
        guard let relpath, let imageURL, let data = try? Data(contentsOf: imageURL) else {
            return nil
        }
        return ReceiptDocument(data: data, relpath: relpath)
    }
}
