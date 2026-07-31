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

    private var records: [SpendRecord] {
        guard let monthFilter else { return store.records }
        return store.records.filter { SpendSummary.monthId(for: $0) == monthFilter }
    }

    private var isEditing: Bool { editMode == .active }
    private var selectedRecords: [SpendRecord] { records.filter { selection.contains($0.id) } }

    var body: some View {
        Group {
            if records.isEmpty {
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
            if !records.isEmpty {
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
            List(selection: $selection) {
                ForEach(records) { record in
                    row(record)
                }
            }
            .listStyle(.insetGrouped)

            if isEditing {
                editFooter
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func row(_ record: SpendRecord) -> some View {
        if isEditing {
            ParsedRow(result: record.result, caption: caption(for: record))
        } else {
            NavigationLink {
                BatchReceiptDetailView(result: record.result, wallMs: record.wallMs,
                                       imageURL: store.photoURL(for: record),
                                       onClearPhoto: { store.clearPhoto(record.id) })
            } label: {
                ParsedRow(result: record.result, caption: caption(for: record))
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

    /// The row's export/photo/excluded state, most receipts most of the time
    /// carrying none of it: an unexported, un-tidied, included receipt says
    /// nothing rather than warning about a state that's simply normal.
    private func caption(for record: SpendRecord) -> String? {
        var parts: [String] = []
        for target in record.exportedTargets {
            parts.append(target == "Money Manager" ? "Shared to Money Manager" : "Filed to \(target)")
        }
        switch store.photoState(for: record) {
        case .present: break
        case .cleared: parts.append("Photo cleared")
        case .unavailable: parts.append("Photo unavailable")
        }
        if record.isExcluded { parts.append("Excluded from budgets") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        if records.isEmpty { editMode = .inactive }
    }

    private var exportLabel: String {
        guard exporter.selectedTargetReady else { return "Set Up Export…" }
        let count = selectedRecords.count
        return count == 1 ? "Export 1 Receipt" : "Export \(count) Receipts"
    }

    /// Sends the selected receipts to the selected target. Never drains the
    /// list either way — these receipts stay put whether they're being filed
    /// for the first time or re-filed; `markExported`/`markShared` are what
    /// changes their caption. A ledger export marks itself via the one hook in
    /// `LedgerExporter.export`; Money Manager is marked here, at presentation,
    /// since the share sheet that follows may be cancelled.
    private func exportSelected() async {
        let selected = selectedRecords
        guard !selected.isEmpty else { return }
        if let kind = exporter.selectedTarget.ledgerKind {
            guard exporter.destination(for: kind).isConfigured else { onConfigure(); return }
            let entries = selected.map {
                LedgerEntry.make(from: $0.result, imageURL: store.photoURL(for: $0), wallMs: $0.wallMs)
            }
            await exporter.export(entries, to: kind)
        } else {
            guard Entitlements.shared.isPremium else { onConfigure(); return }
            do {
                moneyManagerShare = ShareFile(url: try MoneyManagerExport.makeFile(for: selected.map(\.result)))
                store.markShared(results: selected.map(\.result))
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
