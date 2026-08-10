import Foundation
import BBReceiptKit

/// Stored budget configuration: which tracked root carries a monthly target, and
/// what that target is. Mirrors `LedgerFormatPrefs` — a couple of
/// `UserDefaults`-backed settings read at compute time, so a change in Settings
/// takes effect on the very next render.
///
/// Deliberately *not* an input to `SpendSummary`: the spend arithmetic is the
/// product and stands on its own, while a target is an optional overlay one
/// screen draws on top of it. Nothing here can change a number.
@MainActor
enum BudgetPrefs {
    static let rootKey = "budgetRootTag"
    static let amountKey = "budgetMonthlyAmount"

    /// Fallback when nothing is declared and nothing is stored — the app's most
    /// common use case names it directly rather than falling back to an
    /// arbitrary first tag. Defined by the shared crate so Android cannot
    /// disagree.
    static let fallbackRoot = spendFallbackBudgetRoot()

    /// Root tags the current rule corpus actually declares, first-path-segment
    /// only, in the order `RuleBook.tags()` returns them, de-duplicated. What
    /// the root picker offers — never a hardcoded category list.
    static func declaredRoots() -> [String] {
        spendDeclaredRoots(tags: (ItemRuleStore.shared.book?.tags() ?? []).map(\.spendTag))
    }

    /// The target's root tag: the user's stored choice if the corpus still
    /// declares it, else `fallbackRoot` if that's declared, else whatever the
    /// corpus declares first. Never empty as long as the corpus declares
    /// anything.
    ///
    /// The *rule* lives in the shared Rust crate (`spend_resolve_budget_root`)
    /// so Android resolves it identically; only the storage is this platform's.
    /// The "still declares it" clause is the one that matters — a stored root
    /// can outlive the rule that produced it, and a target pointing at a
    /// category the corpus no longer has would silently draw against nothing.
    static var root: String {
        get {
            spendResolveBudgetRoot(stored: UserDefaults.standard.string(forKey: rootKey),
                                   declared: declaredRoots())
        }
        set { UserDefaults.standard.set(newValue, forKey: rootKey) }
    }

    /// The monthly target, or nil for tracking-only — the default, and a
    /// complete way to use the app. Stored as a plain Double; `0` and unset both
    /// read as nil, since a $0 target has no meaningful bar to draw.
    static var monthlyAmount: Double? {
        get {
            let value = UserDefaults.standard.double(forKey: amountKey)
            return value > 0 ? value : nil
        }
        set {
            if let newValue, newValue > 0 {
                UserDefaults.standard.set(newValue, forKey: amountKey)
            } else {
                UserDefaults.standard.removeObject(forKey: amountKey)
            }
        }
    }
}

/// What a month of scanned receipts adds up to, grouped the way the items were
/// classified.
///
/// **The arithmetic itself is no longer here.** It lives in the shared Rust
/// crate `spend-core` (beanbeaver-mobile-util), reached through the
/// `bb_mobile_ffi` UniFFI namespace, so this app and `beanbeaver-android`
/// compute spending from one implementation instead of two hand-synced ports.
/// What remains is the part that is genuinely this platform's:
///
/// - **the projection** — `SpendRecord` down to the slim `SpendInput` Rust
///   reads, including resolving `scannedAt` to a local calendar date, which
///   needs a timezone database Rust deliberately does not carry;
/// - **re-attachment** — Rust identifies a receipt by id and an item by index,
///   so the types below hand back the app's own `SpendRecord` / `ReceiptItem`
///   objects the views draw from.
///
/// The public surface is unchanged, so no view had to move. Computed fresh
/// rather than cached, as before.
///
/// **Every figure comes from `result.items`, not `result.total`.** A bank feed
/// already knows a Costco run was $148.73; only this app knows it was $54.45
/// grocery, $24.99 household and $58.40 gas. `receiptTotal` is carried along
/// solely to reconcile against, never to spend from.
///
/// The behaviour is pinned by `spend-core`'s 28 Rust tests — the first
/// automated coverage this file's logic has ever had on the iOS side.
enum SpendSummary {
    /// One leaf category — the most specific label the classifier reached.
    struct Leaf: Identifiable {
        let id: String
        let label: String
        let amount: Double
        let itemCount: Int
    }

    /// One top-level category and the leaves beneath it. The unit the spending
    /// screen lists, so a month reads as "where the money went", largest first.
    struct RootGroup: Identifiable {
        /// The raw root tag (`"grocery"`) — matches `BudgetPrefs.root`, which is
        /// how the one group carrying a target is found.
        let id: String
        /// The authored display label (`"Grocery"`), from the tag vocabulary.
        let label: String
        let amount: Double
        let itemCount: Int
        /// Largest first.
        let leaves: [Leaf]
    }

    struct Month: Identifiable {
        let id: String                  // "2026-07"
        let label: String               // "July 2026"
        /// The headline: every tracked item plus tax. What the month cost.
        let tracked: Double
        /// Items alone — what `roots` sums to, and `tracked` minus `tax`.
        let itemsTotal: Double
        /// Largest first, "Uncategorized" included so nothing scanned vanishes.
        let roots: [RootGroup]
        let tax: Double
        let receiptTotal: Double        // sum of result.total — the reconciliation number
        let receiptCount: Int
        let excludedCount: Int
        let unreadablePriceCount: Int
        /// Includes excluded rows: the Receipts list still shows them.
        let records: [SpendRecord]
        /// The largest single leaf anywhere in the month, so every category bar
        /// on screen shares one scale and is actually comparable.
        let maxLeafAmount: Double
        /// How far `tracked` sits from what the receipts themselves totalled, or
        /// nil when they agree. Non-nil is normal rather than alarming: a scan
        /// that reads every item but misses a `-5.00` discount line lands here.
        let unaccounted: Double?

        /// The group for `root`, or nil when the month has no spend under it.
        func group(_ root: String) -> RootGroup? {
            roots.first { $0.id == root }
        }
    }

    // MARK: - Month bucketing

    /// The current calendar month's id.
    static func currentMonthId(_ now: Date = Date()) -> String {
        spendCurrentMonthId(today: now.spendDate)
    }

    /// The calendar month a record belongs to: `result.date` unless it's missing
    /// or a placeholder, in which case the row's own `scannedAt` steps in — so a
    /// bucket can't drift with the clock on a later run.
    static func monthId(for record: SpendRecord) -> String {
        spendMonthId(record: record.spendInput)
    }

    /// Every month with at least one record, newest first.
    static func monthIds(from records: [SpendRecord]) -> [String] {
        spendMonthIds(records: records.map(\.spendInput))
    }

    /// The month a screen opens on: the newest one with receipts in it, falling
    /// back to the current calendar month when there are none at all.
    ///
    /// Deliberately *not* "the current month": scanning happens in bursts, and a
    /// screen that opens on a $0.00 October because the last receipt was in
    /// September shows nothing and looks broken.
    static func defaultMonthId(from records: [SpendRecord]) -> String {
        spendDefaultMonthId(records: records.map(\.spendInput), today: Date().spendDate)
    }

    /// `"2026-07"` -> `"July 2026"`, or `id` unchanged if it isn't a month id.
    static func monthLabel(for id: String) -> String {
        spendMonthLabel(id: id)
    }

    // MARK: - Classification

    /// Sentinel root for items the classifier left untagged.
    static let uncategorizedRoot = spendUncategorizedRoot()

    /// The item's display leaf.
    ///
    /// **Twin of `CategoryDisplay.tagDisplay`'s `primary`, and they must not
    /// drift** — the spending screen groups by this while the result card labels
    /// by `tagDisplay`, so a divergence shows one item under two names. The rule
    /// now lives in Rust (`spend_core::leaf_label`); this delegates rather than
    /// reimplementing so there is only one place to change.
    static func leafLabel(of item: ReceiptItem) -> String {
        spendLeafLabel(tags: item.tags.map(\.spendTag))
    }

    // MARK: - Drill-down

    /// One line item, with the receipt it came from. What a category total is
    /// actually made of — tapping "Dairy $19.38" asks *which items*.
    struct ItemEntry: Identifiable {
        /// Stable within a month: a record's id plus the item's index in it.
        let id: String
        let item: ReceiptItem
        let record: SpendRecord
        let amount: Double
    }

    /// One receipt's contribution to a category: the items of it that landed
    /// under the tapped category, and the receipt they were printed on.
    struct ReceiptGroup: Identifiable {
        var id: UUID { record.id }
        let record: SpendRecord
        /// The matching items, in the order they were printed.
        let entries: [ItemEntry]
        /// This receipt's share of the category total.
        let amount: Double
        /// The whole receipt's total, or nil when it didn't parse. Context only.
        let receiptTotal: Double?
    }

    /// What a category is selected by — a whole top-level group, or one leaf
    /// inside it. A root is selected by its **raw tag id**, not its display
    /// label: matching on the label would drop every item in the group that
    /// didn't itself carry the root tag.
    enum Category: Equatable {
        case root(String)
        case leaf(String)

        var ffi: SpendCategory {
            switch self {
            case .root(let id): return .root(id: id)
            case .leaf(let label): return .leaf(label: label)
            }
        }
    }

    /// Every item in `records` under `category`, in store order (newest receipt
    /// first) and within a receipt in the order the items were printed.
    /// Excluded receipts are left out, matching every other figure.
    static func items(_ category: Category, from records: [SpendRecord]) -> [ItemEntry] {
        let byId = Dictionary(records.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        return spendItems(category: category.ffi, records: records.map(\.spendInput))
            .compactMap { $0.reattached(in: byId) }
    }

    /// `items(_:from:)`, grouped by the receipt each item was printed on.
    static func receipts(_ category: Category, from records: [SpendRecord]) -> [ReceiptGroup] {
        let byId = Dictionary(records.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        return spendReceiptGroups(category: category.ffi, records: records.map(\.spendInput))
            .compactMap { group in
                guard let record = byId[group.recordId] else { return nil }
                return ReceiptGroup(record: record,
                                    entries: group.entries.compactMap { $0.reattached(in: byId) },
                                    amount: group.amount,
                                    receiptTotal: group.receiptTotal)
            }
    }

    // MARK: - Arithmetic

    static func month(_ id: String, from records: [SpendRecord]) -> Month {
        let byId = Dictionary(records.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let m = spendMonth(id: id, records: records.map(\.spendInput))
        return Month(
            id: m.id,
            label: m.label,
            tracked: m.tracked,
            itemsTotal: m.itemsTotal,
            roots: m.roots.map { root in
                RootGroup(id: root.id, label: root.label, amount: root.amount,
                          itemCount: Int(root.itemCount),
                          leaves: root.leaves.map {
                              Leaf(id: $0.label, label: $0.label, amount: $0.amount,
                                   itemCount: Int($0.itemCount))
                          })
            },
            tax: m.tax,
            receiptTotal: m.receiptTotal,
            receiptCount: Int(m.receiptCount),
            excludedCount: Int(m.excludedCount),
            unreadablePriceCount: Int(m.unreadablePriceCount),
            records: m.recordIds.compactMap { byId[$0] },
            maxLeafAmount: m.maxLeafAmount,
            unaccounted: m.unaccounted
        )
    }
}

// MARK: - Projection and re-attachment
//
// The seam's own code, and this file's real risk now that the arithmetic is
// shared.

extension Date {
    /// Resolved here rather than in Rust: turning an instant into a calendar
    /// date needs a timezone database *and* the offset in force at that instant,
    /// which `Calendar.current` already has and gets right across DST.
    var spendDate: SpendDate {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return SpendDate(year: Int32(c.year ?? 1970),
                         month: UInt32(c.month ?? 1),
                         day: UInt32(c.day ?? 1))
    }
}

extension ItemTag {
    var spendTag: SpendTag { SpendTag(path: path, display: display) }
}

extension SpendRecord {
    /// This record as the shared crate reads it. Drops `rawText`, `beancount`,
    /// the photo state and the export state — none of which the arithmetic
    /// touches, and the first two of which are large strings that would
    /// otherwise be copied across the FFI on every render.
    var spendInput: SpendInput {
        SpendInput(id: id.uuidString,
                   dateIso: result.date,
                   dateIsPlaceholder: result.dateIsPlaceholder,
                   scannedOn: scannedAt.spendDate,
                   isExcluded: isExcluded,
                   total: result.total,
                   tax: result.tax,
                   items: result.items.map {
                       SpendItem(description: $0.description,
                                 price: $0.price,
                                 tags: $0.tags.map(\.spendTag))
                   })
    }
}

extension SpendItemEntry {
    /// Put the app's own objects back on an entry Rust identified by id and
    /// index.
    ///
    /// Nil — and so dropped — if either lookup misses. That cannot happen for a
    /// list Rust derived from the very records passed in, and silently skipping
    /// beats an index trap on a spending screen if it ever does.
    func reattached(in byId: [String: SpendRecord]) -> SpendSummary.ItemEntry? {
        guard let record = byId[recordId] else { return nil }
        let index = Int(itemIndex)
        guard record.result.items.indices.contains(index) else { return nil }
        return SpendSummary.ItemEntry(id: id, item: record.result.items[index],
                                      record: record, amount: amount)
    }
}
