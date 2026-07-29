import BBReceiptKit
import SwiftUI
import UniformTypeIdentifiers

/// Browse the classification ruleset: which tags exist, which accounts they map
/// to, and which keyword rules produce them.
///
/// Read-only by design. The rule format may still change, so this deliberately
/// offers no rule editor — the one write gesture is importing a document, which
/// needs no UI for the format itself.
struct ItemRulesView: View {
    var store: ItemRuleStore

    @State private var axis: Axis = .tags
    @State private var query = ""
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var importError: String?

    enum Axis: String, CaseIterable, Identifiable {
        case tags = "Tags"
        case accounts = "Accounts"
        case rules = "Rules"
        var id: String { rawValue }
    }

    private var book: RuleBook? { store.book }

    var body: some View {
        List {
            if let loadError = store.loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.bbAccent)
                } header: {
                    Text("Your rules are not being applied")
                }
            }

            switch axis {
            case .tags: tagRows
            case .accounts: accountRows
            case .rules: ruleRows
            }

            if !store.documents.isEmpty {
                Section {
                    ForEach(store.documents) { doc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.displayName)
                            Text(doc.importedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { store.remove(atOffsets: $0) }
                } header: {
                    Text("Imported")
                } footer: {
                    Text("Rules from these files layer on top of the built-in ones and apply to every new scan.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Categories & Tags")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search tags, accounts, keywords")
        .overlay {
            if !query.isEmpty && isEmptyForQuery {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("View", selection: $axis) {
                ForEach(Axis.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ExplainItemView(book: book)
                } label: {
                    Label("Test", systemImage: "wand.and.stars")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Rules…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            // There is no system UTType for TOML, so accept a dynamically
            // derived one and fall back to plain text.
            allowedContentTypes: [UTType(filenameExtension: "toml") ?? .plainText, .plainText]
        ) { result in
            handleImport(result)
        }
        .alert("Rules Imported", isPresented: Binding(
            get: { importMessage != nil }, set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
        .alert("Couldn't Import", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Rows

    private var tagRows: some View {
        Section {
            ForEach(filteredTags, id: \.path) { tag in
                NavigationLink {
                    TagDetailView(tag: tag, book: book)
                } label: {
                    HStack(spacing: 8) {
                        // Indent by depth so the path hierarchy is legible
                        // without drawing an outline.
                        if depth(tag.path) > 0 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 1)
                                .padding(.leading, CGFloat(depth(tag.path) - 1) * 14)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.display)
                            Text(tag.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let account = accountsByPath[tag.path] {
                            Text(account.replacingOccurrences(of: "Expenses:", with: ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } footer: {
            Text("A tag is a path, so the same word can sit under two parents. Tags with no account listed only describe the item — the account comes from a parent or from the winning rule.")
        }
    }

    private var accountRows: some View {
        Section {
            ForEach(filteredCategories, id: \.path) { cat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.account)
                        .font(.subheadline)
                    Text(cat.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Where each tag lands in your ledger. An imported document can remap any of these without touching a rule.")
        }
    }

    private var ruleRows: some View {
        Section {
            ForEach(filteredRules, id: \.index) { rule in
                NavigationLink {
                    RuleDetailView(rule: rule)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(rule.id ?? "rule \(rule.index)")
                                .font(.subheadline)
                            if rule.layer > 0 {
                                Text("yours")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.bbAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.bbAccentSoft, in: Capsule())
                            }
                        }
                        Text(rule.keywords.prefix(4).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(rule.account ?? "tags only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Rules are matched against each item's text. When several match, the highest-priority one supplies the account; every match contributes its tags.")
        }
    }

    // MARK: - Filtering

    private var accountsByPath: [String: String] {
        Dictionary(uniqueKeysWithValues: (book?.categories() ?? []).map { ($0.path, $0.account) })
    }

    private func depth(_ path: String) -> Int { path.filter { $0 == "/" }.count }

    private var filteredTags: [ItemTag] {
        let all = book?.tags() ?? []
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.path.lowercased().contains(q) || $0.display.lowercased().contains(q) }
    }

    private var filteredCategories: [ItemCategory] {
        let all = book?.categories() ?? []
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { $0.path.lowercased().contains(q) || $0.account.lowercased().contains(q) }
    }

    private var filteredRules: [ItemRule] {
        let all = book?.rules() ?? []
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter { rule in
            (rule.id ?? "").lowercased().contains(q)
                || rule.keywords.contains { $0.lowercased().contains(q) }
                || rule.tagPaths.contains { $0.lowercased().contains(q) }
                || (rule.account ?? "").lowercased().contains(q)
        }
    }

    private var isEmptyForQuery: Bool {
        switch axis {
        case .tags: return filteredTags.isEmpty
        case .accounts: return filteredCategories.isEmpty
        case .rules: return filteredRules.isEmpty
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            // Files hands back a security-scoped URL; the text is copied out
            // immediately so the rules survive the source going away.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let toml = try String(contentsOf: url, encoding: .utf8)
                let summary = try store.importDocument(
                    named: url.lastPathComponent, toml: toml
                )
                importMessage = "Added \(summary.rules) rule\(summary.rules == 1 ? "" : "s")"
                    + (summary.tags > 0 ? " and \(summary.tags) new tag\(summary.tags == 1 ? "" : "s")." : ".")
            } catch let error as ScanError {
                // The core validated it — surface its message verbatim, since it
                // names the offending tag path or rule id.
                importError = String(describing: error)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// The rules that mention one tag, and where it files.
private struct TagDetailView: View {
    let tag: ItemTag
    let book: RuleBook?

    var body: some View {
        List {
            Section {
                LabeledContent("Path", value: tag.path)
                if let account = book?.categories().first(where: { $0.path == tag.path })?.account {
                    LabeledContent("Account", value: account)
                }
            }
            let rules = (book?.rules() ?? []).filter { $0.tagPaths.contains(tag.path) }
            if rules.isEmpty {
                Section {
                    Text("No rule assigns this tag directly. It may still appear on items via a more specific tag beneath it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Rules") {
                    ForEach(rules, id: \.index) { rule in
                        NavigationLink {
                            RuleDetailView(rule: rule)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.id ?? "rule \(rule.index)").font(.subheadline)
                                Text(rule.keywords.prefix(5).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(tag.display)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RuleDetailView: View {
    let rule: ItemRule

    var body: some View {
        List {
            Section {
                LabeledContent("Source", value: rule.layer == 0 ? "Built in" : "Imported")
                LabeledContent("Priority", value: "\(rule.priority)")
                if rule.exactOnly {
                    LabeledContent("Matching", value: "Exact only")
                }
                if let account = rule.account {
                    LabeledContent("Account", value: account)
                } else {
                    LabeledContent("Account", value: "None — tags only")
                }
            }
            Section("Tags") {
                ForEach(rule.tagPaths, id: \.self) { Text($0) }
            }
            if !rule.removeTags.isEmpty {
                Section {
                    ForEach(rule.removeTags, id: \.self) { Text($0) }
                } header: {
                    Text("Removes")
                } footer: {
                    Text("These tags are taken away when this rule matches, even if another rule added them.")
                }
            }
            if !rule.disables.isEmpty {
                Section {
                    ForEach(rule.disables, id: \.self) { Text($0) }
                } header: {
                    Text("Disables")
                } footer: {
                    Text("When this rule matches, these rules are ignored entirely.")
                }
            }
            Section("Keywords (\(rule.keywords.count))") {
                ForEach(rule.keywords, id: \.self) { Text($0).font(.callout) }
            }
        }
        .navigationTitle(rule.id ?? "Rule")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Type an item description and see exactly how it classifies, and why.
///
/// This is the screen that answers "why is my yogurt filed under Snacks?" —
/// nothing else in BeanBeaver could say.
struct ExplainItemView: View {
    let book: RuleBook?
    /// Pre-filled when opened from a scanned item.
    var initialDescription: String = ""

    @State private var text = ""

    private var explanation: ItemExplanation? {
        guard let book, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return book.explain(description: text)
    }

    var body: some View {
        List {
            Section {
                TextField("e.g. KS ORG 2% MILK", text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } footer: {
                Text("Type a line as it appears on a receipt.")
            }

            if let e = explanation {
                Section("Result") {
                    LabeledContent("Account", value: e.account ?? "Uncategorized")
                    if !e.tags.isEmpty {
                        let display = CategoryDisplay.tagDisplay(for: e.tags)
                        HStack(spacing: 8) {
                            if let primary = display.primary {
                                Text(primary)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.bbAccent)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Color.bbAccentSoft, in: Capsule())
                            }
                            if !display.rest.isEmpty {
                                Text(display.rest.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if e.matches.isEmpty {
                        Text("No rule matched this line.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(e.matches.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if m.isCategoryWinner {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.bbAccent)
                                        .font(.caption)
                                }
                                Text(m.ruleId ?? "rule \(m.ruleIndex)").font(.subheadline)
                                Spacer()
                                Text(m.isExact ? "Exact" : "Fuzzy")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("matched “\(m.matchedKeyword)”  ·  priority \(m.priority)")
                                .font(.caption).foregroundStyle(.secondary)
                            if !m.tagPaths.isEmpty {
                                Text(m.tagPaths.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Matched rules")
                } footer: {
                    Text("Strongest first. The checked rule supplied the account; every rule listed contributed its tags.")
                }
            }
        }
        .navigationTitle("Test an Item")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if text.isEmpty { text = initialDescription } }
    }
}

#Preview {
    NavigationStack {
        ItemRulesView(store: ItemRuleStore())
    }
}
