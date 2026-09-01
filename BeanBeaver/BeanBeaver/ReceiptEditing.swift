import BBReceiptKit
import CryptoKit
import Foundation

// The non-UI half of the Review & Fix screen: the identity a re-render has to
// preserve, the draft the screen edits, and the `ReceiptEdits` it sends. Kept
// out of `ReceiptEditorView` because none of it is view code — this is what
// decides whether an edited receipt is still the same receipt.

// MARK: - Identity

/// Recovering the image SHA-256 that a re-render has to be handed.
///
/// `reformat_receipt` takes the hash as an argument rather than deriving it,
/// and it is not cosmetic: the hash is what produces `beanbeaver-id`, the
/// `document:` link, and the `beanbeaver-image-sha256` line. Pass nil and all
/// three vanish from the re-rendered beancount — which would strand the record,
/// because `beanbeaver-id` is what `SpendStore` dedups new scans against and
/// what `markExported` matches an exported receipt by.
///
/// Truncating is not an option either. The 8-char token in an existing
/// `beanbeaver-id` would reproduce the id and the document path, but the
/// metadata line carries the *full* hash, and a receipt whose stated sha256 is
/// eight characters followed by nothing is a false claim in someone's ledger.
enum ReceiptIdentity {
    /// The hash the previous render used, read back out of its own beancount.
    ///
    /// Preferred over re-hashing the photo because it is the value that was
    /// actually used: it keeps the id stable even if the JPEG on disk has since
    /// been re-encoded, and it works for a receipt whose photo the user cleared.
    static func imageSha256(inBeancount text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(metadataKey) else { continue }
            let value = trimmed.dropFirst(metadataKey.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Re-hash the capture. The fallback for a receipt parsed before the
    /// metadata line existed, or one whose beancount was never rendered.
    static func imageSha256(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The hash to hand `reformat_receipt` for `result`, best source first.
    ///
    /// Nil is a real answer, not a failure: a parse that never had an image hash
    /// had no id or document link to preserve, so a re-render that also has none
    /// is unchanged rather than degraded.
    static func imageSha256(for result: ReceiptResult, imageURL: URL?) -> String? {
        if let recovered = imageSha256(inBeancount: result.beancount) { return recovered }
        if let imageURL { return imageSha256(ofFileAt: imageURL) }
        return nil
    }

    private static let metadataKey = "beanbeaver-image-sha256:"
}

// MARK: - Draft

/// One line of the item block while it is being edited.
///
/// Identified by a `UUID` minted here rather than by list position, so a row
/// keeps its identity — and its focus, and its half-typed price — across an
/// insert, a delete, or a drag that renumbers everything below it.
struct EditedItemDraft: Identifiable, Equatable {
    let id = UUID()
    var description: String
    /// Free text while typing, normalized on save. Held as the user typed it so
    /// a half-entered "12." isn't rewritten under the cursor.
    var price: String
    var quantity: Int32
    /// The tag path the user picked, or empty to let the rules classify
    /// `description`.
    ///
    /// Empty is the initial value for **every** row, including rows whose
    /// category the parse already got right, and that is the point: core keeps
    /// the parse's own classification for a line whose description is unchanged,
    /// so empty means "leave this line's category alone" for an untouched row
    /// and "re-read it from my new text" for a renamed one. Seeding it with the
    /// parsed path instead would turn all of them into user overrides.
    var tagPath: String = ""
    /// What the parse classified this line as, for the row to show while
    /// `tagPath` is empty. Nil on a line the user added, which has no parse.
    var parsedCategory: String?

    init(item: ReceiptItem) {
        description = item.description
        price = item.price
        quantity = item.quantity
        parsedCategory = item.tags.last?.display
    }

    /// A blank line for the user to fill in — the "add the row an orphaned price
    /// belongs to" case.
    init() {
        description = ""
        price = ""
        quantity = 1
        parsedCategory = nil
    }
}

/// Everything the editor holds, and the `ReceiptEdits` it turns into.
///
/// Split out of the view so the "did anything actually change?" question has
/// one answer. Every field of `ReceiptEdits` is "leave it alone" when absent,
/// so the draft sends only what the user touched — an edit to the date must not
/// re-open the item block, and an edit to one price must not restate the
/// merchant.
struct ReceiptEditDraft {
    var merchant: String
    /// Nil when the receipt has no date and the user hasn't given it one.
    var date: Date?
    var items: [EditedItemDraft]
    var total: String
    var tax: String
    var subtotal: String

    private let original: ReceiptResult

    init(result: ReceiptResult) {
        original = result
        merchant = result.merchant
        date = result.date.flatMap(Self.isoFormatter.date(from:))
        items = result.items.map(EditedItemDraft.init(item:))
        total = result.total
        tax = result.tax ?? ""
        subtotal = result.subtotal ?? ""
    }

    // MARK: Change detection

    var merchantChanged: Bool { merchant.trimmed != original.merchant }

    var dateChanged: Bool { dateISO != original.date }

    /// True when the block differs in shape or in any field. Compared against
    /// the parse rather than tracked with a dirty flag, so an edit typed and
    /// then undone is correctly not an edit.
    var itemsChanged: Bool {
        guard items.count == original.items.count else { return true }
        for (draft, parsed) in zip(items, original.items) {
            if draft.description.trimmed != parsed.description { return true }
            if Self.normalizedAmount(draft.price) != Self.normalizedAmount(parsed.price) { return true }
            if draft.quantity != parsed.quantity { return true }
            if !draft.tagPath.isEmpty { return true }
        }
        return false
    }

    var totalChanged: Bool { changed(total, from: original.total) }

    var taxChanged: Bool { changed(tax, from: original.tax) }

    var subtotalChanged: Bool { changed(subtotal, from: original.subtotal) }

    var hasChanges: Bool {
        merchantChanged || dateChanged || itemsChanged
            || totalChanged || taxChanged || subtotalChanged
    }

    /// A blank amount field means "leave what was parsed", not "set it to
    /// nothing" — there is no way to *remove* a summary amount through
    /// `ReceiptEdits`, and a receipt that genuinely printed no tax is said with
    /// `0.00` rather than by clearing the field.
    ///
    /// So an emptied field is deliberately **not** a change: reporting it as one
    /// would light up Save for an edit that is then silently dropped on the way
    /// out, since the field it would set can only be sent as a value.
    private func changed(_ value: String, from parsed: String?) -> Bool {
        let entered = Self.normalizedAmount(value)
        guard let entered else { return false }
        return entered != Self.normalizedAmount(parsed ?? "")
    }

    var dateISO: String? {
        date.map { Self.isoFormatter.string(from: $0) }
    }

    // MARK: Validation

    /// Why the item block can't be sent, or nil when it can.
    ///
    /// Only the two things core would reject anyway, caught here so the message
    /// names the row instead of arriving as a parse error about the receipt.
    var itemProblem: String? {
        for (index, item) in items.enumerated() {
            let row = index + 1
            if item.description.trimmed.isEmpty {
                return "Item \(row) has no description."
            }
            if Self.normalizedAmount(item.price) == nil {
                return "Item \(row) (\(item.description.trimmed)) has no readable price."
            }
        }
        return nil
    }

    // MARK: Arithmetic

    /// What the edited lines add up to — the figure that should meet the
    /// subtotal.
    var itemsSum: Double {
        items.reduce(0) { $0 + (PriceFormat.value($1.price) ?? 0) }
    }

    /// The receipt's own identity: subtotal + tax = total. Nil when a field it
    /// needs is blank or unreadable, since a check that can't be made shouldn't
    /// be reported as a failure.
    var summaryDifference: Double? {
        guard let total = PriceFormat.value(total),
              let subtotal = PriceFormat.value(subtotal) else { return nil }
        let tax = PriceFormat.value(self.tax) ?? 0
        return total - (subtotal + tax)
    }

    /// Difference between the item lines and the subtotal, when both are
    /// readable.
    var itemsDifference: Double? {
        guard let subtotal = PriceFormat.value(subtotal) else { return nil }
        return itemsSum - subtotal
    }

    // MARK: Output

    /// The edits to send, or nil when nothing changed.
    func edits() -> ReceiptEdits? {
        guard hasChanges else { return nil }
        return ReceiptEdits(
            merchant: merchantChanged ? merchant.trimmed : nil,
            dateIso: dateChanged ? dateISO : nil,
            items: itemsChanged ? items.map(Self.edited(from:)) : nil,
            total: totalChanged ? Self.normalizedAmount(total) : nil,
            tax: taxChanged ? Self.normalizedAmount(tax) : nil,
            subtotal: subtotalChanged ? Self.normalizedAmount(subtotal) : nil
        )
    }

    private static func edited(from draft: EditedItemDraft) -> EditedItem {
        EditedItem(
            description: draft.description.trimmed,
            price: normalizedAmount(draft.price) ?? draft.price.trimmed,
            quantity: draft.quantity,
            tagPath: draft.tagPath
        )
    }

    /// A typed amount as the decimal string core parses, or nil when the field
    /// is blank or unreadable. Normalizing here is what lets "$12.5", "12.50 "
    /// and "12.5" all mean the same edit — and what stops a stray currency
    /// symbol arriving as a parse error.
    static func normalizedAmount(_ raw: String) -> String? {
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty, let value = PriceFormat.value(trimmed) else { return nil }
        return String(format: "%.2f", value)
    }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// File-scoped, matching `GitHubLedger.swift`'s own copy — the codebase keeps
/// this one-liner private per file rather than sharing a utilities header.
private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
