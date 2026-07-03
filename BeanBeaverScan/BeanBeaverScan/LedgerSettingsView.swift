import SwiftUI
import UniformTypeIdentifiers

/// Configure where scanned transactions are sent: a synced `.bean` file (Files /
/// iCloud / Dropbox / …) and/or a GitHub pull request. Reached from Settings.
struct LedgerSettingsView: View {
    @Bindable var exporter: LedgerExporter
    @State private var showFileImporter = false
    @State private var importError: String?

    var body: some View {
        List {
            filesSection
            gitHubSection
        }
        .navigationTitle("Ledger Sync")
        .navigationBarTitleDisplayMode(.inline)
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
            SecureField("Access token", text: $exporter.github.token)
        } header: {
            Label(LedgerDestinationKind.githubPR.title, systemImage: LedgerDestinationKind.githubPR.systemImage)
        } footer: {
            Text("Each export opens a pull request that appends the transaction to the file. Use a fine-grained personal access token scoped to this repo with Contents and Pull requests read/write. The token is stored in the device Keychain.")
        }
    }
}

/// The set of export actions offered for a parsed result: one button per
/// configured destination, a Share fallback, and a shortcut to set up sync.
/// Shared by the result card and the toolbar menu so they never drift.
struct LedgerExportButtons: View {
    let beancount: String
    @Bindable var exporter: LedgerExporter
    var onConfigure: () -> Void

    var body: some View {
        ForEach(exporter.configuredKinds) { kind in
            Button {
                Task { await exporter.export(beancount, to: kind) }
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
}
