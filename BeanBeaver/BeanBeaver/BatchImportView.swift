import SwiftUI
import PhotosUI
import BBReceiptKit

/// The photo-library import workspace: add a pile of receipts, watch them parse,
/// look over what came back, then sync the lot in one go.
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
    /// A sync landed and its confirmation is up; the batch drains when that's
    /// dismissed. Lost if the app dies with the alert open, which leaves the
    /// receipts in the batch — a re-sync then reports them already filed, which
    /// is recoverable with Discard Batch.
    @State private var awaitingConfirmation = false
    /// How many of the last selection were already in the batch — surfaced once,
    /// as a note under the header, rather than as an alert per photo.
    @State private var duplicatesSkipped = 0

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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            confirmDiscard = true
                        } label: {
                            Label("Discard Batch", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addPhotosPicker {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .confirmationDialog("Discard this batch?", isPresented: $confirmDiscard,
                            titleVisibility: .visible) {
            Button("Discard \(batch.drafts.count) Receipt\(batch.drafts.count == 1 ? "" : "s")",
                   role: .destructive) {
                batch.discardAll()
            }
        } message: {
            Text("Removes every receipt waiting here, and its photo, from this device. "
                 + "Anything already synced to your ledger is untouched, and the originals "
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

            syncFooter
        }
        .background(Color(.systemGroupedBackground))
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

    // MARK: - Sync

    private var syncFooter: some View {
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
                Task { await sync() }
            } label: {
                SyncButtonLabel(idleLabel: syncLabel, exporter: exporter)
            }
            .buttonStyle(.borderedProminent)
            .tint(exporter.syncTint)
            .controlSize(.large)
            .disabled(batch.parsedCount == 0)
            // Deliberately not `.disabled` while syncing: a disabled prominent
            // button renders washed out with its spinner greyed into the fill —
            // the exact "nothing is happening" look this is meant to fix. Block
            // the tap instead; `export` already refuses a second concurrent run.
            // Also inert while the confirmation is up, since the receipts are
            // still listed at that point and a second tap would re-file them.
            .allowsHitTesting(exporter.runningKind == nil && !awaitingConfirmation)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var syncLabel: String {
        guard exporter.configuredKinds.isEmpty == false else { return "Set Up Sync…" }
        let count = batch.parsedCount
        return count == 1 ? "Sync 1 Receipt" : "Sync \(count) Receipts"
    }

    /// Sends every parsed receipt to the first configured destination — one pull
    /// request, or one append, for the whole batch. Only drains on success, so a
    /// failed sync leaves the batch exactly as it was to retry.
    ///
    /// Draining is deferred to `drainOnConfirmation` rather than done here: the
    /// confirmation is about to appear, and emptying the list out from under it
    /// reads as the receipts having vanished rather than having been filed.
    private func sync() async {
        guard let kind = exporter.configuredKinds.first else {
            onConfigure()
            return
        }
        let entries = batch.syncableEntries
        guard !entries.isEmpty else { return }
        if await exporter.export(entries, to: kind) {
            awaitingConfirmation = true
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

private struct ParsedRow: View {
    let result: ReceiptResult

    private var subtitle: String {
        var parts: [String] = []
        if let date = ReceiptDateFormat.friendly(result.date) { parts.append(date) }
        let count = result.items.count
        if count > 0 { parts.append("\(count) item\(count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
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
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(PriceFormat.display(result.total).text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
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

/// One receipt out of a batch. The card, and nothing that syncs — a batch goes
/// to the ledger as a unit, so the only per-receipt actions here are looking at
/// the photo behind the parse and throwing the parse away.
struct BatchReceiptDetailView: View {
    let result: ReceiptResult
    var wallMs: Double?
    var imageURL: URL?

    @State private var showOriginReceipt = false

    var body: some View {
        ScrollView {
            ReceiptCard(result: result, wallMs: wallMs, capturedImageURL: imageURL)
                .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(result.merchant.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showOriginReceipt = true
                } label: {
                    Image(systemName: "photo")
                }
                .disabled(imageURL == nil)
            }
        }
        .sheet(isPresented: $showOriginReceipt) {
            OriginReceiptView(imageURL: imageURL)
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
