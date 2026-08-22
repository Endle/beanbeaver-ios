import SwiftUI
import PhotosUI
import BBReceiptKit

/// The photo-library import workspace: add a pile of receipts, watch them parse,
/// look over what came back, then export the lot in one go.
///
/// Deliberately not the camera flow — "Scan a Receipt" stays a single fast path
/// for one receipt at the checkout counter. This is the sit-down-and-process-a-
/// backlog path, which is why it's a place you navigate to and can come back to
/// rather than a picker that fires once.
struct BatchImportView: View {
    @Bindable var batch: ReceiptBatch
    var exporter: LedgerExporter
    var onConfigure: () -> Void

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoadingPicked = false
    @State private var confirmDiscard = false
    /// An export landed and its confirmation is up; the batch drains when that's
    /// dismissed. Lost if the app dies with the alert open, which leaves the
    /// receipts in the batch — a re-export then reports them already filed, which
    /// is recoverable with Discard Batch.
    @State private var awaitingConfirmation = false
    /// How many of the last selection were already in the batch — surfaced once,
    /// as a note under the header, rather than as an alert per photo.
    @State private var duplicatesSkipped = 0
    /// The Money Manager `.xlsx` for the whole batch, awaiting the share sheet.
    @State private var moneyManagerShare: ShareFile?

    var body: some View {
        Group {
            if batch.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Import from Photos")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.bbAccent)
        .toolbar {
            if !batch.isEmpty {
                // One overflow menu instead of a separate + and ⋯: adding more
                // photos and discarding the batch are the only batch-level
                // actions here. Money Manager export lives on the bottom Export
                // button (via the selected target), not up here.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        addPhotosPicker {
                            Label("Add Photos", systemImage: "photo.badge.plus")
                        }

                        Divider()

                        Button(role: .destructive) {
                            confirmDiscard = true
                        } label: {
                            Label("Discard Batch", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        // A centered alert, not a confirmationDialog: the latter renders as a
        // source-anchored popover on iPad/Mac, and since it's triggered from the
        // (already-dismissed) overflow menu rather than a live button, that
        // popover has no anchor and points at nothing. An alert has no anchor.
        .alert("Discard this batch?", isPresented: $confirmDiscard) {
            Button("Discard \(batch.drafts.count) Receipt\(batch.drafts.count == 1 ? "" : "s")",
                   role: .destructive) {
                batch.discardAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every receipt waiting here, and its photo, from this device. "
                 + "Anything already exported to your ledger is untouched, and the originals "
                 + "stay in your photo library.")
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        .onChange(of: exporter.result?.id) { _, resultID in
            drainOnConfirmation(resultID)
        }
        // These are receipts the user already asked to have parsed, so resuming
        // needs no button: anything queued or interrupted just picks up here.
        .task { batch.startParsing() }
        .sheet(item: $moneyManagerShare) { share in
            ActivityView(items: [share.url])
        }
    }

    /// Export every parsed receipt in the batch to one Money Manager `.xlsx` and
    /// present its share sheet. Non-destructive — unlike `export()`, it leaves the
    /// batch in place. A temp-write failure is rare and non-fatal; it's captured
    /// for support rather than surfaced.
    private func presentMoneyManager() {
        guard Entitlements.shared.isPremium else { return }
        do {
            moneyManagerShare = ShareFile(url: try MoneyManagerExport.makeFile(for: batch.parsedResults))
            SpendStore.shared.markShared(results: batch.parsedResults)
        } catch {
            DebugInfoStore.recordExportFailure(context: "Money Manager batch export",
                                             message: error.localizedDescription)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Receipts Yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add receipt photos from your library and BeanBeaver will read them all, "
                 + "then file them to your ledger together.")
        } actions: {
            addPhotosPicker {
                Label("Add Photos", systemImage: "photo.badge.plus")
                    .font(.headline)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.bbAccent)
            .controlSize(.large)
        }
    }

    /// Additive on purpose: pull some from one album, look them over, pull more
    /// from another. Photos already in the batch are rejected by content hash,
    /// so overlapping selections cost nothing.
    private func addPhotosPicker<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(selection: $pickerItems, matching: .images, label: label)
            .disabled(isLoadingPicked)
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(batch.drafts) { draft in
                        row(draft)
                    }
                    .onDelete { offsets in
                        for index in offsets { batch.remove(batch.drafts[index].id) }
                    }
                } header: {
                    header
                }
            }
            .listStyle(.insetGrouped)

            exportFooter
        }
        .background(Color.bbCanvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerLine)
            if isLoadingPicked {
                Text("Adding photos…")
            } else if duplicatesSkipped > 0 {
                Text("\(duplicatesSkipped) already in this batch — skipped.")
            }
        }
        .textCase(nil)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var headerLine: String {
        var parts: [String] = []
        if let createdAt = batch.createdAt {
            parts.append("Started \(createdAt.formatted(.dateTime.month(.abbreviated).day()))")
        }
        parts.append("\(batch.drafts.count) receipt\(batch.drafts.count == 1 ? "" : "s")")
        if batch.needsAttentionCount > 0 {
            parts.append("\(batch.needsAttentionCount) need\(batch.needsAttentionCount == 1 ? "s" : "") a look")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func row(_ draft: ReceiptDraft) -> some View {
        switch draft.state {
        case .parsed(let result):
            NavigationLink {
                BatchReceiptDetailView(result: result, wallMs: draft.wallMs,
                                       imageURL: batch.url(for: draft))
            } label: {
                ParsedRow(result: result)
            }
        case .failed(let message):
            FailedRow(message: message) { batch.retry(draft.id) }
        case .scanning:
            PendingRow(label: "Reading…", showsSpinner: true)
        case .queued:
            PendingRow(label: "Waiting", showsSpinner: false)
        case .interrupted:
            PendingRow(label: "Interrupted — will retry", showsSpinner: false)
        }
    }

    // MARK: - Export

    private var exportFooter: some View {
        VStack(spacing: 8) {
            if batch.isParsing {
                Button(role: .cancel) {
                    batch.stopParsing()
                } label: {
                    Label("Stop Reading (\(batch.remainingParseCount) left)", systemImage: "stop.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.large)
            }

            Button {
                Task { await export() }
            } label: {
                ExportButtonLabel(idleLabel: exportLabel, exporter: exporter)
            }
            .buttonStyle(.borderedProminent)
            .tint(exporter.exportTint)
            .controlSize(.large)
            .disabled(batch.parsedCount == 0)
            // Deliberately not `.disabled` while exporting: a disabled prominent
            // button renders washed out with its spinner greyed into the fill —
            // the exact "nothing is happening" look this is meant to fix. Block
            // the tap instead; `export` already refuses a second concurrent run.
            // Also inert while the confirmation is up, since the receipts are
            // still listed at that point and a second tap would re-file them.
            .allowsHitTesting(exporter.runningKind == nil && !awaitingConfirmation)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, BBLayout.tabBarInset)
        .background(Color.bbCanvas)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.bbHairline).frame(height: 1)
        }
    }

    private var exportLabel: String {
        guard exporter.selectedTargetReady else { return "Set Up Export…" }
        let count = batch.parsedCount
        return count == 1 ? "Export 1 Receipt" : "Export \(count) Receipts"
    }

    /// Sends every parsed receipt to the selected target — one pull request or
    /// append for a ledger destination, or the Money Manager share export for the
    /// whole batch. Ledger exports only drain on success (a failure leaves the batch
    /// to retry); the Money Manager export is non-destructive and never drains.
    ///
    /// Draining is deferred to `drainOnConfirmation` rather than done here: the
    /// confirmation is about to appear, and emptying the list out from under it
    /// reads as the receipts having vanished rather than having been filed.
    private func export() async {
        if let kind = exporter.selectedTarget.ledgerKind {
            guard exporter.destination(for: kind).isConfigured else { onConfigure(); return }
            let entries = batch.exportableEntries
            guard !entries.isEmpty else { return }
            if await exporter.export(entries, to: kind) {
                awaitingConfirmation = true
            }
        } else {
            guard Entitlements.shared.isPremium else { onConfigure(); return }
            presentMoneyManager()
        }
    }

    /// Drain once the user has actually seen the confirmation — spotted by
    /// `exporter.result` going back to nil, which is the alert closing. Tying it
    /// to the dismissal rather than a delay means there's no interval to guess
    /// at, and the list emptying reads as a consequence of tapping OK.
    private func drainOnConfirmation(_ resultID: UUID?) {
        guard awaitingConfirmation, resultID == nil else { return }
        awaitingConfirmation = false
        batch.removeParsed()
    }

    // MARK: - Loading picked photos

    /// One photo at a time: a selection of twenty full-resolution JPEGs loaded
    /// at once is a lot of memory to hold for no reason — `add` writes each to
    /// disk and we drop it.
    private func load(_ items: [PhotosPickerItem]) async {
        isLoadingPicked = true
        duplicatesSkipped = 0
        defer {
            isLoadingPicked = false
            pickerItems = []
        }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if batch.add(data) == .duplicate { duplicatesSkipped += 1 }
        }
        batch.startParsing()
    }
}

// MARK: - Rows

/// A parsed receipt's row: an optional export-status dot, merchant,
/// needs-attention badge, date/item-count subtitle, total. Shared by the batch
/// list and `ReceiptsView`.
///
/// Both extras are nil at the batch call site, which is what keeps them honest:
/// a draft in a batch has no export state to report and nothing to say about a
/// photo it hasn't settled yet.
///
/// `detail` joins the subtitle rather than sitting on its own line. Photo state
/// used to be a third line in `ReceiptsView`, in the same weight and colour as
/// the export caption above it — which made a fact about the row ("photo
/// cleared") look exactly like its status. The dot is status now; anything on
/// this line is not.
struct ParsedRow: View {
    let result: ReceiptResult
    var status: SpendRecord.ExportStatus?
    var detail: String?

    private var subtitle: String {
        var parts: [String] = []
        if let date = ReceiptDateFormat.friendly(result.date) { parts.append(date) }
        let count = result.items.count
        if count > 0 { parts.append("\(count) item\(count == 1 ? "" : "s")") }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            if let status {
                ExportStatusDot(status: status)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.merchant.capitalized)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if result.needsAttention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.bbAccent)
                    }
                }
                if !subtitle.isEmpty {
                    // **Never `lineLimit(1)`.** This carries `detail` — the
                    // category share, "photo cleared", "excluded from totals" —
                    // and truncating it cuts exactly the informational half,
                    // leaving a date and an item count anyone could guess.
                    // Proportional, not mono: it is prose, and mono is for the
                    // amount column on the right, where it aligns.
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(PriceFormat.display(result.total).text)
                .font(.bbMono(15, .semibold))
        }
        .padding(.vertical, 2)
    }
}

private struct PendingRow: View {
    let label: String
    let showsSpinner: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct FailedRow: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Couldn't read this one", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.bbAccent)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry", action: onRetry)
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

/// One receipt out of a batch. The card, and nothing that exports — a batch goes
/// to the ledger as a unit, so the only per-receipt actions here are looking at
/// the photo behind the parse and throwing the parse away.
struct BatchReceiptDetailView: View {
    let result: ReceiptResult
    var wallMs: Double?
    var imageURL: URL?
    /// When this receipt first reached a target, and which targets it has
    /// reached. Set from `ReceiptsView`; nil/empty in the batch flow, where a
    /// draft hasn't been anywhere yet.
    ///
    /// This is where "Filed to GitHub" went when the list row traded it for a
    /// dot. The list only has to answer *whether* a receipt is filed; the answer
    /// to *where* is worth a line of its own, and it's the one screen with room
    /// to say a receipt went to both.
    var exportedAt: Date?
    var exportedTargets: [String] = []
    /// Present only when opened from `ReceiptsView`, where the photo belongs to
    /// a settled `SpendRecord` the user can choose to clear. Nil in the batch
    /// review flow, where photos aren't yet something the user manages
    /// per-receipt — so the toolbar there stays the single photo button.
    var onClearPhoto: (() -> Void)?

    @State private var showOriginReceipt = false
    /// Outcome of the last "Save to Camera Roll", shown in an alert. One piece
    /// of state for both outcomes: the action is invisible either way once the
    /// menu closes, so success needs saying as much as failure does.
    @State private var saveOutcome: SaveOutcome?
    @Environment(\.dismiss) private var dismiss

    private struct SaveOutcome {
        let title: String
        let message: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ReceiptCard(result: result, wallMs: wallMs, capturedImageURL: imageURL)
                exportStatusCard
            }
            .padding()
        }
        .background(Color.bbCanvas)
        .navigationTitle(result.merchant.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let onClearPhoto {
                    Menu {
                        Button {
                            showOriginReceipt = true
                        } label: {
                            Label("Show Original Receipt", systemImage: "photo")
                        }
                        .disabled(imageURL == nil)
                        Button {
                            Task { await saveToCameraRoll() }
                        } label: {
                            Label("Save to Camera Roll", systemImage: "square.and.arrow.down")
                        }
                        .disabled(imageURL == nil)
                        Button(role: .destructive) {
                            // The photo is gone the moment this returns, so the
                            // `imageURL` this screen was pushed with is now
                            // stale — pop back to the list rather than show a
                            // photo button pointing at a deleted file.
                            onClearPhoto()
                            dismiss()
                        } label: {
                            Label("Clear Photo", systemImage: "photo.badge.minus")
                        }
                        .disabled(imageURL == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                } else {
                    Button {
                        showOriginReceipt = true
                    } label: {
                        Image(systemName: "photo")
                    }
                    .disabled(imageURL == nil)
                }
            }
        }
        .sheet(isPresented: $showOriginReceipt) {
            OriginReceiptView(imageURL: imageURL)
        }
        .alert(saveOutcome?.title ?? "", isPresented: showingSaveOutcome, presenting: saveOutcome) { _ in
            Button("OK", role: .cancel) {}
        } message: { outcome in
            Text(outcome.message)
        }
    }

    /// Where this receipt has got to, in words. Rendered only when the caller
    /// supplied export state at all (`ReceiptsView`), so the batch flow — where
    /// a draft has been nowhere by definition — doesn't grow a card telling it
    /// so.
    ///
    /// Says "Shared to" for Money Manager and "Filed to" for a ledger, matching
    /// `SpendStore.markShared`'s honesty about the difference: a share sheet is
    /// marked at presentation and may have been cancelled, while a ledger append
    /// either landed or reported an error.
    @ViewBuilder
    private var exportStatusCard: some View {
        if let exportedAt {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ExportStatusDot(status: .exported)
                    Text(exportedTargets.isEmpty
                         ? "Exported"
                         : exportedTargets.map(Self.targetPhrase).joined(separator: " · "))
                        .font(.subheadline.weight(.medium))
                }
                Text("First exported \(exportedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .bbCard()
        } else if !exportedTargets.isEmpty || onClearPhoto != nil {
            HStack(spacing: 8) {
                ExportStatusDot(status: .notExported)
                Text("Not exported yet")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding()
            .bbCard()
        }
    }

    private static func targetPhrase(_ target: String) -> String {
        target == "Money Manager" ? "Shared to Money Manager" : "Filed to \(target)"
    }

    private var showingSaveOutcome: Binding<Bool> {
        Binding(get: { saveOutcome != nil }, set: { if !$0 { saveOutcome = nil } })
    }

    /// Copy this receipt's photo into the user's photo library. The copy lands
    /// outside the app's storage, so it survives Clear Photo and Delete All
    /// Receipts — that's the point of the action, and why the confirmation says
    /// so rather than just "Saved".
    private func saveToCameraRoll() async {
        guard let imageURL else { return }
        do {
            try await PhotoSaver.save(imageAt: imageURL)
            saveOutcome = SaveOutcome(
                title: "Saved to Camera Roll",
                message: "A copy of this receipt photo is now in your photo library. Deleting the receipt here won't remove it.")
        } catch {
            saveOutcome = SaveOutcome(title: "Couldn't Save Photo",
                                      message: error.localizedDescription)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Batch – empty") {
    NavigationStack {
        BatchImportView(batch: ReceiptBatch(), exporter: LedgerExporter(), onConfigure: {})
    }
}

#Preview("Batch – detail") {
    NavigationStack {
        BatchReceiptDetailView(result: .previewFull, wallMs: 816, imageURL: nil)
    }
}
#endif
