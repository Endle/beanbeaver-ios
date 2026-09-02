import BBReceiptKit
import SwiftUI

/// Review & Fix: correct what the parse got wrong, and re-render the receipt
/// from the correction.
///
/// The screen is a `Form`, not a receipt card. A card is the app's way of
/// showing a receipt as a piece of paper, and this is the opposite gesture —
/// the user is not reading a receipt here, they are telling the app that it
/// misread one. `Form` also brings the platform's own editing affordances
/// (swipe-to-delete, drag-to-reorder, keyboard management) which a hand-drawn
/// card would have to reinvent.
///
/// Nothing is corrected locally: the edits go back through
/// `reformatReceipt`, so the beancount, the account each line posts to, the
/// tags, the confidences and the warnings are all re-derived by the same code
/// that produced them in the first place. That is what stops the app from
/// showing one thing and the ledger from saying another — the failure the old
/// positional `item_account_overrides` had by construction.
struct ReceiptEditorView: View {
    let original: ReceiptResult
    /// The receipt's photo, used only to re-hash it when the beancount carries
    /// no `beanbeaver-image-sha256` line. See `ReceiptIdentity`.
    var imageURL: URL?
    /// Set when this receipt has already reached a ledger, so the screen can say
    /// that editing it here does not go back and change what was filed.
    var exportedAt: Date?
    let onSave: (ReceiptResult) -> Void

    @State private var draft: ReceiptEditDraft
    @State private var saveError: String?
    @State private var showDiscardConfirmation = false
    @State private var ruleStore = ItemRuleStore.shared
    @Environment(\.dismiss) private var dismiss

    init(original: ReceiptResult,
         imageURL: URL? = nil,
         exportedAt: Date? = nil,
         onSave: @escaping (ReceiptResult) -> Void) {
        self.original = original
        self.imageURL = imageURL
        self.exportedAt = exportedAt
        self.onSave = onSave
        _draft = State(initialValue: ReceiptEditDraft(result: original))
    }

    var body: some View {
        NavigationStack {
            Form {
                receiptSection
                itemsSection
                summarySection
                if exportedAt != nil { alreadyExportedSection }
            }
            .navigationTitle("Review & Fix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft.hasChanges {
                            showDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.hasChanges)
                }
            }
            .alert("Couldn't apply the correction",
                   isPresented: .init(get: { saveError != nil },
                                      set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .confirmationDialog("Discard your changes?",
                                isPresented: $showDiscardConfirmation,
                                titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
    }

    // MARK: - Receipt

    private var receiptSection: some View {
        Section("Receipt") {
            LabeledContent("Merchant") {
                TextField("Merchant", text: $draft.merchant)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }

            // A receipt with no date is a real state the parser reports, and
            // giving it one here is the whole fix. There is no way to take a
            // date *away* through `ReceiptEdits`, so this offers the direction
            // that exists rather than a toggle that would half-work.
            if let date = draft.date {
                DatePicker("Date",
                           selection: .init(get: { date }, set: { draft.date = $0 }),
                           displayedComponents: .date)
            } else {
                Button("Set a Date") { draft.date = Date() }
            }
        }
    }

    // MARK: - Items

    private var itemsSection: some View {
        Section {
            ForEach($draft.items) { $item in
                NavigationLink {
                    ItemEditorView(item: $item, tags: ruleStore.book?.tags() ?? [])
                } label: {
                    ItemRow(item: item)
                }
            }
            .onDelete { draft.items.remove(atOffsets: $0) }
            .onMove { draft.items.move(fromOffsets: $0, toOffset: $1) }

            Button {
                draft.items.append(EditedItemDraft())
            } label: {
                Label("Add Item", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Text("Items (\(draft.items.count))")
                Spacer()
                // Explicit rather than relying on a long-press drag: reordering
                // matters here — the item block is sent as a list, so its order
                // is what the corrected receipt records — and an affordance
                // nobody finds is not one.
                EditButton()
                    .textCase(nil)
            }
        } footer: {
            Text("Swipe a line to delete it, or Edit to reorder. "
                 + "A line you rename is re-filed from its new text.")
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            amountField("Subtotal", text: $draft.subtotal)
            amountField("Tax", text: $draft.tax)
            amountField("Total", text: $draft.total)
        } header: {
            Text("Summary")
        } footer: {
            reconciliation
        }
    }

    private func amountField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("0.00", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
        }
    }

    /// The two identities a receipt has to satisfy, checked live.
    ///
    /// This is the same arithmetic the fixture discipline does by hand — the
    /// lines must add to the subtotal, and subtotal plus tax must be the total —
    /// and it is here because it is the fastest way to see *which* line is still
    /// wrong. It never blocks saving: a receipt can be mid-correction, and a
    /// receipt can also genuinely not balance, which is worth being able to
    /// record.
    @ViewBuilder
    private var reconciliation: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let difference = draft.itemsDifference {
                checkRow(label: "Items add to \(PriceFormat.currency(draft.itemsSum))",
                         difference: difference,
                         offBy: "off the subtotal")
            }
            if let difference = draft.summaryDifference {
                checkRow(label: "Subtotal + tax",
                         difference: difference,
                         offBy: "off the total")
            }
        }
        .padding(.top, 2)
    }

    private func checkRow(label: String, difference: Double, offBy: String) -> some View {
        // A cent of slack: the parse carries two-decimal strings and the sum of
        // several is a float, so an exactly-balanced receipt can land a
        // rounding step away from zero.
        let balanced = abs(difference) < 0.005
        return Label {
            Text(balanced
                 ? "\(label) — balances"
                 : "\(label) — \(PriceFormat.currency(abs(difference))) \(offBy)")
        } icon: {
            Image(systemName: balanced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(balanced ? Color.secondary : Color.bbAccent)
    }

    private var alreadyExportedSection: some View {
        Section {
            Label {
                Text("This receipt has already been filed. Correcting it here "
                     + "updates the app, not the entry that was exported.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Save

    private func save() {
        if let problem = draft.itemProblem {
            saveError = problem
            return
        }
        // Nothing to send is not an error: a user who opened this, looked, and
        // changed their mind gets the same exit as Cancel rather than a
        // pointless re-render.
        guard let edits = draft.edits() else { dismiss(); return }

        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = DateYmd(year: Int32(now.year ?? 1970),
                            month: UInt32(now.month ?? 1),
                            day: UInt32(now.day ?? 1))

        do {
            let edited = try reformatReceipt(
                previous: original,
                today: today,
                creditCardAccount: ReceiptEditorView.creditCardAccount,
                currency: LedgerFormatPrefs.currency,
                taxAccount: LedgerFormatPrefs.taxAccount,
                imageSha256: ReceiptIdentity.imageSha256(for: original, imageURL: imageURL),
                edits: edits,
                options: ruleStore.parseOptions
            )
            onSave(edited)
            dismiss()
        } catch {
            saveError = String(describing: error)
        }
    }

    /// The same constant `ReceiptPipeline` and `ReceiptBatch` scan with. A
    /// re-render has to be handed the account the original render used, or the
    /// corrected entry would post somewhere else; when that constant becomes a
    /// user setting, all three read it from the same place.
    private static let creditCardAccount = "Liabilities:CreditCard"
}

// MARK: - Item row

/// One line as it appears in the editor's list: what it says, what it costs, and
/// where it is filed.
private struct ItemRow: View {
    let item: EditedItemDraft

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description.isEmpty ? "New item" : item.description)
                    .foregroundStyle(item.description.isEmpty ? Color.secondary : Color.primary)
                if let category = categoryLabel {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(item.price.isEmpty ? "—" : PriceFormat.display(item.price).text)
                .monospacedDigit()
                .foregroundStyle(item.price.isEmpty ? Color.secondary : Color.primary)
        }
    }

    /// A user-picked tag wins the label; otherwise the parse's own classification
    /// stands, and a line the parse never classified says nothing rather than
    /// inventing a category for it.
    private var categoryLabel: String? {
        if !item.tagPath.isEmpty { return item.tagPath }
        return item.parsedCategory
    }
}

// MARK: - Item editor

/// One line of the item block, opened for correction.
private struct ItemEditorView: View {
    @Binding var item: EditedItemDraft
    let tags: [ItemTag]

    var body: some View {
        Form {
            Section("Description") {
                TextField("Description", text: $item.description, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }

            Section {
                LabeledContent("Price") {
                    TextField("0.00", text: $item.price)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                Stepper("Quantity: \(item.quantity)",
                        value: $item.quantity, in: 1...99)
            }

            Section {
                NavigationLink {
                    TagPickerView(selection: $item.tagPath, tags: tags)
                } label: {
                    LabeledContent("Category", value: categoryValue)
                }
            } footer: {
                Text(item.tagPath.isEmpty
                     ? "Filed automatically from the description. Pick a category "
                       + "to overrule that for this line."
                     : "You picked this category, so the description won't change it.")
            }
        }
        .navigationTitle("Item")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var categoryValue: String {
        if item.tagPath.isEmpty {
            return item.parsedCategory.map { "\($0) (automatic)" } ?? "Automatic"
        }
        return tags.first { $0.path == item.tagPath }?.display ?? item.tagPath
    }
}

// MARK: - Tag picker

/// The tag vocabulary in force, as a list to pick from.
///
/// Over `tags()` rather than `categories()` on purpose: `categories()` is only
/// the paths that map to an account, and 11 of the bundled tags deliberately map
/// to none — `grocery/dairy/milk` and `grocery/meat/chicken` among them — while
/// still being the honest name for a line. Core walks a picked path to its
/// nearest mapped ancestor for exactly this reason, so offering only the mapped
/// ones would hide the specific labels for no gain.
private struct TagPickerView: View {
    @Binding var selection: String
    let tags: [ItemTag]
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    selection = ""
                    dismiss()
                } label: {
                    row(title: "Automatic", subtitle: "File it from the description",
                        isSelected: selection.isEmpty)
                }
            }

            Section {
                ForEach(matches, id: \.path) { tag in
                    Button {
                        selection = tag.path
                        dismiss()
                    } label: {
                        row(title: tag.display, subtitle: tag.path,
                            isSelected: selection == tag.path)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Find a category")
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Matched on both halves: the display name is what someone reads, and the
    /// path is what distinguishes two tags that share one ("Chicken" under meat,
    /// and a chicken under deli).
    private var matches: [ItemTag] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return tags }
        return tags.filter {
            $0.display.lowercased().contains(needle) || $0.path.lowercased().contains(needle)
        }
    }

    private func row(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.bbAccent)
            }
        }
    }
}

// MARK: - Previews

// `#if DEBUG` because `ReceiptResult.previewFull` is itself DEBUG-only
// (`ContentView.swift`), and `#Preview` expands in every configuration — so an
// unguarded one referencing it fails the **Release** build, which is the
// configuration an archive uses and the only one whose numbers `SpendPerf`
// trusts. Same guard `BatchImportView`'s previews carry, for the same reason.
#if DEBUG
#Preview("Editor") {
    ReceiptEditorView(original: .previewFull) { _ in }
}
#endif
