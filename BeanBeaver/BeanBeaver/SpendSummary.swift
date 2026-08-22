import Foundation
import BBReceiptKit

/// **Unused since the monthly budget was removed** — see `SpendingView`. Kept
/// only until `beanbeaver-android` drops its own budget UI, since both read the
/// same shared Rust and android pins its own tag.
///
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
        /// The raw root tag (`"grocery"`), not the display label — what a
        /// `SpendSummary.Category.root` is selected by, and what the Spending
        /// screen's trend chips carry.
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

    // MARK: - Trend

    /// **The weekly trend surfaces are off, and not because they are broken.**
    ///
    /// Turned off 2026-08-19 after the charts were seen against real receipts on
    /// a device: they draw what they claim to draw, but six weekly totals turned
    /// out not to be the information worth a third of the home card. That is a
    /// product answer, not a defect — **don't go looking for a bug here.** The
    /// surface is meant to evolve before it reaches anyone, so the home line,
    /// its delta row, and the Spending screen's whole week-over-week card are
    /// withheld in the meantime.
    ///
    /// The code stays: `spend_trend` and its 29 Rust tests are unaffected, and
    /// `TrendChart` is still built and still masks correctly. Flipping this to
    /// `true` brings all three back at once, which is the point of it being one
    /// flag rather than three comment blocks.
    ///
    /// The **rolling 30-day figure is not gated** — it comes from the same call
    /// but is a plain sum over a window, and nothing about it looked wrong.
    ///
    /// **Back on, 2026-08-21, and the surface it comes back to is different.**
    /// What was withheld was a *line* on the home card under a "vs last week"
    /// row that said the same thing the line did. The redesign draws six
    /// **bars** — discrete weekly totals, the newest visibly partial — with the
    /// delta as the card's own header figure and nothing repeating it. That is
    /// the change that made the surface worth a third of the card. The
    /// Spending screen's scoped week-over-week card comes back with it, on the
    /// same flag.
    static let showWeeklyTrend = true

    /// How many weeks the charts plot. Six is what the design asks for and what
    /// fits the card's width at a legible dot spacing.
    static let trendWeeks: UInt32 = 6
    /// The second figure beside the month total — "$341.08 in the last 30 days".
    static let rollingDays: UInt32 = 30

    // MARK: - Month facts

    /// The two figures the home slip prints under a month's total, and the
    /// windows they cover.
    ///
    /// A second call rather than fields on `month`: `spend_month` is pure over
    /// records and takes no date, and these are clock-relative. See
    /// `spend_month_facts`'s own docs for why that separation is worth one more
    /// crossing on the one screen that needs both.
    ///
    /// Rust decides where the windows begin and end; this file only resolves
    /// "today" (the platform's job — see `Date.spendDate`) and the rendering
    /// formats them.
    static func facts(_ id: String,
                      from records: [SpendRecord],
                      today: Date = Date()) -> SpendMonthFacts {
        spendMonthFacts(id: id, records: records.map(\.spendInput), today: today.spendDate)
    }

    /// The weekly series for `scope`, or all spending when `scope` is nil.
    ///
    /// Everything about *when* a week starts is decided in Rust; the two things
    /// passed in are the two the platform genuinely owns — today as a local
    /// calendar date, and the locale's first weekday.
    static func trend(_ scope: Category? = nil,
                      from records: [SpendRecord],
                      today: Date = Date()) -> SpendTrend {
        spendTrend(records: records.map(\.spendInput),
                   scope: scope?.ffi,
                   today: today.spendDate,
                   firstWeekday: Calendar.current.spendFirstWeekday,
                   weeks: trendWeeks,
                   rollingDays: rollingDays)
    }
}

extension Calendar {
    /// This calendar's first weekday, named.
    ///
    /// `Calendar.firstWeekday` is ICU-numbered (1 = Sunday … 7 = Saturday), and
    /// it used to be handed to Rust as that raw integer — one convention away
    /// from Kotlin's `DayOfWeek`, where `MONDAY = 1`. The seam takes a
    /// `SpendWeekday` now, so the conversion happens here, once, as a switch
    /// that names every day it means.
    ///
    /// `Calendar` guarantees the 1...7 range, so the default is unreachable
    /// rather than a fallback with an opinion.
    var spendFirstWeekday: SpendWeekday {
        switch firstWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return .sunday
        }
    }
}

extension SpendTrend {
    /// Whether the delta is worth calling a change. The crate rounds to cents,
    /// so this is an exact test rather than an epsilon — see `Trend`'s docs.
    var isFlat: Bool { delta == 0 }

    /// The series as plain numbers, oldest first, for drawing.
    var amounts: [Double] { points.map(\.amount) }
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

extension SpendDateRange {
    /// The range as a `Date`, or nil for a date the calendar can't build. Half
    /// open, so `end` is the day *after* the last one covered.
    private var dates: (start: Date, lastDay: Date)? {
        var c = DateComponents()
        c.year = Int(start.year); c.month = Int(start.month); c.day = Int(start.day)
        var e = DateComponents()
        e.year = Int(end.year); e.month = Int(end.month); e.day = Int(end.day)
        let calendar = Calendar.current
        guard let from = calendar.date(from: c),
              let exclusiveEnd = calendar.date(from: e),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd)
        else { return nil }
        return (from, lastDay)
    }

    /// `"Aug 1–21"`, or `"Aug 28 – Sep 3"` when the span crosses a month.
    ///
    /// An en dash, and tight against the numbers within a month — that is how a
    /// date range is set. Spaced when the two sides are two words each, because
    /// `Aug 28–Sep 3` reads as one token.
    ///
    /// The month name is repeated only when it changes. Both windows this
    /// renders — a month to date, and the same stretch of the month before —
    /// sit inside one month in every ordinary case, so the two-month form is
    /// the defensive branch rather than the common one.
    var shortLabel: String {
        guard let (from, lastDay) = dates else { return "" }
        let calendar = Calendar.current
        let day = Date.FormatStyle.dateTime.day()
        let monthDay = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if calendar.isDate(from, equalTo: lastDay, toGranularity: .month) {
            return "\(from.formatted(monthDay))–\(lastDay.formatted(day))"
        }
        return "\(from.formatted(monthDay)) – \(lastDay.formatted(monthDay))"
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
