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
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteSelected = false
    @State private var confirmClearAllPhotos = false
    @State private var moneyManagerShare: ShareFile?
    @State private var filter: Filter = .all

    /// Which slice of the month the list is showing. Not persisted: it's a
    /// question you ask on the way to doing something ("what haven't I filed?"),
    /// not a preference — and a filter that survived a relaunch would hide
    /// receipts from someone who'd forgotten they set it.
    private enum Filter: Hashable {
        case all, notExported, exported

        func matches(_ record: SpendRecord) -> Bool {
            switch self {
            case .all: return true
            case .notExported: return !record.isExported
            case .exported: return record.isExported
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

    private var records: [SpendRecord] { scopedRecords.filter(filter.matches) }

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
            Text("Frees the space used by every receipt photo. Every receipt's parsed data and every budget figure stay exactly as they are.")
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
                    ContentUnavailableView {
                        Label(filter == .exported ? "Nothing Exported Yet" : "Nothing to Export",
                              systemImage: filter == .exported ? "tray" : "checkmark.circle")
                    } description: {
                        Text(filter == .exported
                             ? "Receipts you've filed to your ledger show up here."
                             : "Every receipt here has reached your ledger.")
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

    /// The same `isExported` split the dots draw, as a way to narrow the list —
    /// so "what haven't I filed?" is answerable without reading every dot, and
    /// the counts state the backlog even when the answer is "none".
    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(.all, label: "All", count: scopedRecords.count, status: nil)
                chip(.notExported, label: "Not exported", count: backlog.count,
                     status: .notExported)
                chip(.exported, label: "Exported",
                     count: scopedRecords.count - backlog.count, status: .exported)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private func chip(_ value: Filter, label: String, count: Int,
                      status: SpendRecord.ExportStatus?) -> some View {
        let selected = filter == value
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
    /// view with the dot; what's left is the photo and the budget exclusion,
    /// which is a fact about the row rather than a state of its export (see
    /// `SpendRecord.ExportStatus` for why the dot deliberately doesn't carry it).
    ///
    /// Lowercased: these join the date/item-count subtitle now rather than
    /// heading their own line.
    private func detail(for record: SpendRecord) -> String? {
        var parts: [String] = []
        switch store.photoState(for: record) {
        case .present: break
        case .cleared: parts.append("photo cleared")
        case .unavailable: parts.append("photo unavailable")
        }
        if record.isExcluded { parts.append("excluded from budgets") }
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
        .buttonStyle(.borderedProminent)
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
