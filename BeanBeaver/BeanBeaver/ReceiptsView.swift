import SwiftUI
import BBReceiptKit

/// Every scanned receipt — the "see everything I scanned" and "bulk backup"
/// halves of the feature. Reuses `ParsedRow` and `BatchReceiptDetailView` from
/// the batch flow, but unlike a batch this list never drains on export: a
/// receipt lives here until the user deletes it or clears its photo.
struct ReceiptsView: View {
    /// When set (from `SpendingView`), only that month's receipts are shown
    /// and the title reflects it. Nil shows everything, newest first.
    var monthFilter: String?
    var exporter: LedgerExporter
    var onConfigure: () -> Void

    @State private var store = SpendStore.shared
    /// The same single state the home card's eye and the Settings toggle write,
    /// so the row subtitles mask with everything else.
    @State private var amountPrivacy = AmountPrivacy.shared
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteSelected = false
    @State private var confirmClearAllPhotos = false
    @State private var moneyManagerShare: ShareFile?
    /// Nil means "whatever `defaultFilter` says" — the newest month, which is
    /// what the list should open on and which isn't knowable at init.
    @State private var filter: Filter?

    /// Which slice the list is showing. Not persisted: it's a question you ask
    /// on the way to doing something ("what haven't I filed?"), not a preference
    /// — and a filter that survived a relaunch would hide receipts from someone
    /// who'd forgotten they set it.
    ///
    /// **Time and place lead now, and ledger state is one chip of several.** The
    /// row used to be `All / Not exported / Exported`, which organised browsing
    /// entirely around export — a chore, not a reason to open the list. `Exported`
    /// is gone: it answered the inverse of a question nobody asks, and every
    /// receipt it held is reachable through its month.
    private enum Filter: Hashable {
        case all
        case month(String)
        case unfiled
        case merchant(String)

        func matches(_ record: SpendRecord) -> Bool {
            switch self {
            case .all: return true
            case .month(let id): return SpendSummary.monthId(for: record) == id
            case .unfiled: return !record.isExported
            case .merchant(let name): return record.result.merchant == name
            }
        }
    }

    /// Everything in scope, before the chips narrow it — what the chip counts
    /// are computed over, so "Not exported 3" always agrees with what tapping it
    /// shows.
    private var scopedRecords: [SpendRecord] {
        guard let monthFilter else { return store.records }
        return store.records.filter { SpendSummary.monthId(for: $0) == monthFilter }
    }

    /// Opens on the newest month rather than everything: the list is for
    /// browsing what you've been buying, and "everything, ever" is the wrong
    /// first answer once there is more than a month of it. Every receipt stays
    /// one chip away.
    private var defaultFilter: Filter {
        guard monthFilter == nil, let newest = monthChips.first else { return .all }
        return .month(newest.id)
    }
    private var activeFilter: Filter { filter ?? defaultFilter }

    private var records: [SpendRecord] { scopedRecords.filter(activeFilter.matches) }

    /// The backlog the footer bar acts on — scoped to the month being shown, but
    /// deliberately *not* to the chips: the bar means "file everything here that
    /// isn't filed", and that shouldn't change meaning when the view is narrowed
    /// to the exported slice.
    private var backlog: [SpendRecord] { scopedRecords.filter { !$0.isExported } }

    private var isEditing: Bool { editMode == .active }
    private var selectedRecords: [SpendRecord] { records.filter { selection.contains($0.id) } }

    var body: some View {
        Group {
            if scopedRecords.isEmpty {
                ContentUnavailableView {
                    Label("No Receipts", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(monthFilter == nil
                         ? "Scanned receipts show up here."
                         : "No receipts scanned this month.")
                }
            } else {
                list
            }
        }
        .navigationTitle(monthFilter.map(SpendSummary.monthLabel(for:)) ?? "Receipts")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.bbAccent)
        .environment(\.editMode, $editMode)
        .toolbar {
            if !scopedRecords.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "Done" : "Select") {
                        editMode = isEditing ? .inactive : .active
                        if !isEditing { selection.removeAll() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            selection = Set(records.filter { !$0.isExported }.map(\.id))
                            editMode = .active
                        } label: {
                            Label("Select Unexported", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button {
                            confirmClearAllPhotos = true
                        } label: {
                            Label("Clear All Photos", systemImage: "photo.badge.minus")
                        }
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            Label("Delete All Receipts", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        // Centered alerts, not confirmationDialogs: triggered from an
        // already-dismissed overflow menu, so there's no live anchor for a
        // source-anchored popover — same reasoning as BatchImportView's
        // Discard Batch alert.
        .alert("Clear all photos?", isPresented: $confirmClearAllPhotos) {
            Button("Clear Photos", role: .destructive) { store.clearAllPhotos() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees the space used by every receipt photo. Every receipt's parsed data and every spending figure stay exactly as they are.")
        }
        .alert(selectedRecords.count == 1 ? "Delete this receipt?" : "Delete \(selectedRecords.count) receipts?",
               isPresented: $confirmDeleteSelected) {
            Button("Delete \(selectedRecords.count) Receipt\(selectedRecords.count == 1 ? "" : "s")",
                   role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the parsed data and the photos for the receipts you selected. Everything else stays. Anything already exported to your ledger is untouched, and originals stay in your photo library.")
        }
        .alert("Delete all receipts?", isPresented: $confirmDeleteAll) {
            Button("Delete \(store.records.count) Receipt\(store.records.count == 1 ? "" : "s")",
                   role: .destructive) {
                store.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the parsed data and the photos for every scanned receipt on this device. Anything already exported to your ledger is untouched, and originals stay in your photo library.")
        }
        .sheet(item: $moneyManagerShare) { share in
            ActivityView(items: [share.url])
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            // Hidden while selecting: the chips would fight the selection for
            // what a tap means, and narrowing the list under a live selection
            // silently changes what "Export 4 Receipts" is about to send.
            if !isEditing {
                filterChips
            }

            Group {
                if records.isEmpty {
                    // Only `Unfiled` can empty the list now — a month or a
                    // merchant chip only exists because it has receipts in it.
                    ContentUnavailableView {
                        Label("Nothing to Export", systemImage: "checkmark.circle")
                    } description: {
                        Text("Every receipt here has reached your ledger.")
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(records) { record in
                            row(record)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }

            if isEditing {
                editFooter
            } else if !backlog.isEmpty {
                backlogFooter
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Months present in the list, newest first, each with its receipt count.
    private var monthChips: [(id: String, label: String, count: Int)] {
        // Already narrowed to one month by the caller — a month chip row would
        // be one chip that changes nothing.
        guard monthFilter == nil else { return [] }
        let thisYear = String(SpendSummary.currentMonthId().prefix(4))
        return SpendSummary.monthIds(from: scopedRecords).map { id in
            // "March", not "March 2026" — a chip is a word wide, and the year
            // only earns its space once the list reaches back past this one.
            let full = SpendSummary.monthLabel(for: id)
            let label = id.hasPrefix(thisYear)
                ? full.split(separator: " ").first.map(String.init) ?? full
                : full
            return (id, label,
                    scopedRecords.filter { SpendSummary.monthId(for: $0) == id }.count)
        }
    }

    /// Merchants worth a chip: the recurring ones, busiest first. A merchant
    /// seen once is a row in the list, not a way to narrow it.
    private var merchantChips: [(name: String, count: Int)] {
        Dictionary(grouping: scopedRecords, by: { $0.result.merchant })
            .map { ($0.key, $0.value.count) }
            .filter { $0.1 > 1 }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }
            .prefix(4)
            .map { (name: $0.0, count: $0.1) }
    }

    /// Time and place first, with the one retained export filter second.
    ///
    /// `Unfiled` sits in position two deliberately: it is the chip with an
    /// action behind it, and last in a scrolling row is where a chip gets
    /// clipped by the fade and goes unseen.
    ///
    /// **`All` leads, and is shown even when nothing is scoped** — it is the way
    /// back out of every other chip. The unscoped list opens on the newest month
    /// (`defaultFilter`), so without it there is no chip that means "stop
    /// narrowing", and the older receipts a month chip hides are unreachable
    /// rather than one tap away. Its count is `scopedRecords`, so under a
    /// month-scoped caller it still means "everything in this month".
    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(.all, label: "All", count: scopedRecords.count, status: nil)
                if let newest = monthChips.first {
                    chip(.month(newest.id), label: newest.label, count: newest.count,
                         status: nil)
                }
                chip(.unfiled, label: "Unfiled", count: backlog.count,
                     status: .notExported)
                ForEach(monthChips.dropFirst(), id: \.id) { month in
                    chip(.month(month.id), label: month.label, count: month.count,
                         status: nil)
                }
                ForEach(merchantChips, id: \.name) { merchant in
                    // `.capitalized` to match `ParsedRow` — the chip and the
                    // rows it selects have to be the same word, and the parse
                    // carries the merchant as printed (`COSTCO`).
                    chip(.merchant(merchant.name), label: merchant.name.capitalized,
                         count: merchant.count, status: nil)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private func chip(_ value: Filter, label: String, count: Int,
                      status: SpendRecord.ExportStatus?) -> some View {
        let selected = activeFilter == value
        return Button {
            filter = value
        } label: {
            HStack(spacing: 6) {
                // The selected chip is a solid accent fill, so a coloured dot on
                // it would be unreadable — and redundant, since the chip is
                // already the loudest thing in the row.
                if let status, !selected {
                    ExportStatusDot(status: status, size: 8)
                }
                Text("\(label) \(count)")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(Color.bbAccent)
                                 : AnyShapeStyle(.quaternary),
                        in: Capsule())
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func row(_ record: SpendRecord) -> some View {
        if isEditing {
            ParsedRow(result: record.result, status: record.exportStatus,
                      detail: detail(for: record))
        } else {
            NavigationLink {
                BatchReceiptDetailView(result: record.result, wallMs: record.wallMs,
                                       imageURL: store.photoURL(for: record),
                                       exportedAt: record.exportedAt,
                                       exportedTargets: record.exportedTargets,
                                       onClearPhoto: { store.clearPhoto(record.id) })
            } label: {
                ParsedRow(result: record.result, status: record.exportStatus,
                          detail: detail(for: record))
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    store.remove(record.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    store.setExcluded(!record.isExcluded, for: record.id)
                } label: {
                    Label(record.isExcluded ? "Include" : "Exclude", systemImage: "eye.slash")
                }
                .tint(.orange)
            }
        }
    }

    /// Facts about the row that aren't its export status — everything the dot
    /// doesn't already say. Which target a receipt reached moved to the detail
    /// view with the dot; what's left is the category share, the photo and the
    /// which is a fact about the row rather than a state of its export (see
    /// `SpendRecord.ExportStatus` for why the dot deliberately doesn't carry it).
    ///
    /// Lowercased: these join the date/item-count subtitle now rather than
    /// heading their own line.
    /// The leading category across the receipts on screen, and what each receipt
    /// spent in it.
    ///
    /// `roots.first` follows the same order the Spending screen draws, which
    /// since mobile-util v0.1.9 puts the primary root (grocery) first whether or
    /// not it is largest — so this row and that screen agree on what leads. It
    /// still comes from the data rather than a hardcoded string here, and the
    /// share is simply omitted for a receipt with none of it.
    ///
    /// One FFI call for the whole list rather than a rollup per row.
    private var categoryShare: (label: String, byRecord: [String: Double])? {
        let ids = Set(scopedRecords.map(\.id.uuidString))
        let month = SpendSummary.month(SpendSummary.defaultMonthId(from: scopedRecords),
                                       from: scopedRecords)
        guard let root = month.roots.first else { return nil }
        let groups = SpendSummary.receipts(.root(root.id), from: scopedRecords)
        let byRecord = Dictionary(
            groups.filter { ids.contains($0.record.id.uuidString) }
                .map { ($0.record.id.uuidString, $0.amount) },
            uniquingKeysWith: { a, _ in a })
        return (root.label.lowercased(), byRecord)
    }

    private func detail(for record: SpendRecord) -> String? {
        var parts: [String] = []
        if let share = categoryShare,
           let amount = share.byRecord[record.id.uuidString], amount > 0 {
            parts.append("\(amountPrivacy.text(PriceFormat.currency(amount))) \(share.label)")
        }
        switch store.photoState(for: record) {
        case .present: break
        case .cleared: parts.append("photo cleared")
        case .unavailable: parts.append("photo unavailable")
        }
        // "budgets" was the old feature's word; the exclusion always meant
        // "kept out of the totals", which is now all there is.
        if record.isExcluded { parts.append("excluded from totals") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One tap to file everything unfiled. The bar is present whenever there's a
    /// backlog and absent the moment there isn't, so it doubles as the answer to
    /// "am I up to date?" — a screen with no bar is a screen with nothing owing.
    private var backlogFooter: some View {
        Button {
            Task { await export(backlog) }
        } label: {
            ExportButtonLabel(idleLabel: backlogLabel, exporter: exporter)
        }
        // Tinted, not filled. Filing to a ledger is still one tap and still
        // always here, but it is no longer the loudest thing on a screen whose
        // job is browsing what you bought. `Scan` on home keeps that role.
        .buttonStyle(.bordered)
        .tint(.bbAccent)
        .controlSize(.large)
        .allowsHitTesting(exporter.runningKind == nil)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var backlogLabel: String {
        guard exporter.selectedTargetReady else { return "Set Up Export…" }
        let count = backlog.count
        return "Export \(count) Receipt\(count == 1 ? "" : "s") to \(exporter.selectedTarget.label)"
    }

    // MARK: - Bulk actions

    /// Both things a selection can be used for, side by side. Deleting a chosen
    /// few used to have no home here: the swipe action does one row and the
    /// overflow menu does all of them, so trimming a dozen receipts meant a
    /// dozen swipes. Selection already existed for export — this just lets the
    /// same selection be thrown away, which is also why "Select Unexported" now
    /// composes into "delete what I never filed".
    private var editFooter: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                confirmDeleteSelected = true
            } label: {
                Image(systemName: "trash")
                    .font(.headline)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .disabled(selectedRecords.isEmpty)
            .accessibilityLabel(selectedRecords.count == 1
                                ? "Delete 1 selected receipt"
                                : "Delete \(selectedRecords.count) selected receipts")

            Button {
                Task { await exportSelected() }
            } label: {
                ExportButtonLabel(idleLabel: exportLabel, exporter: exporter)
            }
            .buttonStyle(.borderedProminent)
            .tint(exporter.exportTint)
            .controlSize(.large)
            .disabled(selectedRecords.isEmpty)
            .allowsHitTesting(exporter.runningKind == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Delete the selection, then leave the user somewhere sensible: selection
    /// emptied either way, and edit mode dropped when the list is now empty —
    /// otherwise the toolbar (hidden for an empty list) takes "Done" with it and
    /// strands the screen in edit mode.
    private func deleteSelected() {
        store.remove(ids: selection)
        selection.removeAll()
        if scopedRecords.isEmpty { editMode = .inactive }
    }

    private var exportLabel: String {
        guard exporter.selectedTargetReady else { return "Set Up Export…" }
        let count = selectedRecords.count
        return count == 1 ? "Export 1 Receipt" : "Export \(count) Receipts"
    }

    private func exportSelected() async {
        await export(selectedRecords)
    }

    /// Sends `records` to the selected target. Never drains the list either way
    /// — these receipts stay put whether they're being filed for the first time
    /// or re-filed; `markExported`/`markShared` are what changes their dot. A
    /// ledger export marks itself via the one hook in `LedgerExporter.export`;
    /// Money Manager is marked here, at presentation, since the share sheet that
    /// follows may be cancelled.
    ///
    /// Takes its records as an argument rather than reading the selection, so
    /// the footer bar's "file the backlog" and the selection's "file these" are
    /// the same code path — including the unconfigured-target detour, which the
    /// bar needs just as much.
    private func export(_ records: [SpendRecord]) async {
        guard !records.isEmpty else { return }
        if let kind = exporter.selectedTarget.ledgerKind {
            guard exporter.destination(for: kind).isConfigured else { onConfigure(); return }
            let entries = records.map {
                LedgerEntry.make(from: $0.result, imageURL: store.photoURL(for: $0), wallMs: $0.wallMs)
            }
            await exporter.export(entries, to: kind)
        } else {
            guard Entitlements.shared.isPremium else { onConfigure(); return }
            do {
                moneyManagerShare = ShareFile(url: try MoneyManagerExport.makeFile(for: records.map(\.result)))
                store.markShared(results: records.map(\.result))
            } catch {
                DebugInfoStore.recordExportFailure(context: "Money Manager export (Receipts)",
                                                   message: error.localizedDescription)
            }
        }
    }
}

#if DEBUG
#Preview("Receipts") {
    NavigationStack { ReceiptsView(exporter: LedgerExporter(), onConfigure: {}) }
}
#endif
