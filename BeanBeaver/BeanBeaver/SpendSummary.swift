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
    /// arbitrary first tag.
    static let fallbackRoot = "grocery"

    /// Root tags the current rule corpus actually declares, first-path-segment
    /// only, in the order `RuleBook.tags()` returns them, de-duplicated. What
    /// the root picker offers — never a hardcoded category list.
    static func declaredRoots() -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for tag in ItemRuleStore.shared.book?.tags() ?? [] {
            guard let root = tag.path.split(separator: "/").first.map(String.init),
                  !seen.contains(root) else { continue }
            seen.insert(root)
            roots.append(root)
        }
        return roots
    }

    /// The target's root tag: the user's stored choice if the corpus still
    /// declares it, else `fallbackRoot` if that's declared, else whatever the
    /// corpus declares first. Never empty as long as the corpus declares
    /// anything.
    static var root: String {
        get {
            let roots = declaredRoots()
            if let stored = UserDefaults.standard.string(forKey: rootKey), roots.contains(stored) {
                return stored
            }
            if roots.contains(fallbackRoot) { return fallbackRoot }
            return roots.first ?? fallbackRoot
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

/// Pure arithmetic over `SpendRecord`s — what a month of scanned receipts adds
/// up to, grouped the way the items were classified. Computed fresh rather than
/// cached, since the substrate (a few thousand records at most) is cheap to
/// re-scan. No view code and no `UserDefaults` reads, so this is checkable by
/// hand from `-dumpSpending`.
///
/// **Every figure comes from `result.items`, not `result.total`.** A bank feed
/// already knows a Costco run was $148.73; only this app knows it was $54.45
/// grocery, $24.99 household and $58.40 gas. `receiptTotal` is carried along
/// solely to reconcile against, never to spend from.
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
        /// The authored display label (`"Grocery"`), taken from the tag
        /// vocabulary when it's available rather than capitalized here — the
        /// same reason `CategoryDisplay.tagDisplay` uses `display` verbatim.
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
        let records: [SpendRecord]

        /// The group for `root`, or nil when the month has no spend under it —
        /// how the spending screen finds the one group a target applies to.
        func group(_ root: String) -> RootGroup? {
            roots.first { $0.id == root }
        }

        /// The largest single leaf anywhere in the month, so every category bar
        /// on screen shares one scale and is actually comparable. Scaling per
        /// group would put each root on its own invisible scale.
        var maxLeafAmount: Double {
            roots.flatMap(\.leaves).map(\.amount).max() ?? 0
        }

        /// How far `tracked` sits from what the receipts themselves totalled, or
        /// nil when they agree. Non-nil is normal rather than alarming: a scan
        /// that reads every item but misses a `-5.00` discount line lands here,
        /// as does one whose `total` didn't parse. The screen names it instead
        /// of leaving the reader to subtract two numbers.
        var unaccounted: Double? {
            let gap = tracked - receiptTotal
            return abs(gap) >= 0.01 ? gap : nil
        }
    }

    // MARK: - Month bucketing

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthIdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// The current calendar month's id — what a screen shows before anything has
    /// been scanned into it.
    static func currentMonthId(_ now: Date = Date()) -> String {
        monthIdFormatter.string(from: now)
    }

    /// The calendar month a record belongs to: `result.date` unless it's missing
    /// or a placeholder, in which case the row's own `scannedAt` steps in —
    /// mirroring `MoneyManagerExport.dateString`'s fallback, but with the row's
    /// own scan time instead of "today", so a bucket can't drift with the clock
    /// on a later run.
    static func monthId(for record: SpendRecord) -> String {
        let date: Date
        if !record.result.dateIsPlaceholder, let iso = record.result.date,
           let parsed = isoParser.date(from: iso) {
            date = parsed
        } else {
            date = record.scannedAt
        }
        return monthIdFormatter.string(from: date)
    }

    /// Every month with at least one record, newest first.
    static func monthIds(from records: [SpendRecord]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for record in records {
            let id = monthId(for: record)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            ids.append(id)
        }
        return ids.sorted(by: >)
    }

    /// The month a screen opens on: the newest one with receipts in it, falling
    /// back to the current calendar month when there are none at all.
    ///
    /// Deliberately *not* "the current month": scanning happens in bursts, and a
    /// screen that opens on a $0.00 October because the last receipt was in
    /// September shows nothing and looks broken. Both the home card and
    /// `SpendingView` route through this, so the number on the card is the month
    /// tapping it lands on.
    static func defaultMonthId(from records: [SpendRecord]) -> String {
        monthIds(from: records).first ?? currentMonthId()
    }

    /// "2026-07" -> "July 2026", or `id` unchanged if it isn't a month id.
    static func monthLabel(for id: String) -> String {
        guard let date = monthIdFormatter.date(from: id) else { return id }
        return monthLabelFormatter.string(from: date)
    }

    // MARK: - Classification

    /// Sentinel root for items the classifier left untagged. Kept as a real
    /// group rather than dropped, so the breakdown always reconciles against
    /// what was actually scanned — same intent as `MoneyManagerExport.rows(for:)`.
    static let uncategorizedRoot = "uncategorized"

    /// The item's top-level category. The classifier emits tags broad→specific
    /// (`["grocery", "meat", "chicken"]` — `CategoryDisplay.tagDisplay` reads
    /// `.last` for the most specific on the same assumption), so the *first* tag
    /// carries the root. A path may itself be nested (`"grocery/meat"`), hence
    /// the split.
    private static func root(of item: ReceiptItem) -> String {
        guard let first = item.tags.first,
              let segment = first.path.split(separator: "/").first
        else { return uncategorizedRoot }
        return String(segment)
    }

    /// The authored label for a root, when this item's tag list carries the root
    /// tag itself — the vocabulary's own wording beats capitalizing a raw path
    /// segment (`"personalcare"` -> `"Personal Care"`, not `"Personalcare"`).
    private static func rootLabel(of item: ReceiptItem, root: String) -> String? {
        item.tags.first { $0.path == root && !$0.display.isEmpty }?.display
    }

    /// The item's display leaf — the app's existing label
    /// (`CategoryDisplay.tagDisplay(for:)`), so spending, the result card and the
    /// Money Manager export agree by construction.
    private static func leafLabel(of item: ReceiptItem) -> String {
        CategoryDisplay.tagDisplay(for: item.tags).primary ?? "Uncategorized"
    }

    // MARK: - Arithmetic

    /// Insertion-ordered accumulation so ties in amount keep a stable order
    /// through the largest-first sorts.
    private struct RootAccumulator {
        var label: String
        var amount = 0.0
        var itemCount = 0
        var leaves: [(label: String, amount: Double, count: Int)] = []

        mutating func add(leaf: String, _ amount: Double) {
            self.amount += amount
            itemCount += 1
            if let index = leaves.firstIndex(where: { $0.label == leaf }) {
                leaves[index].amount += amount
                leaves[index].count += 1
            } else {
                leaves.append((label: leaf, amount: amount, count: 1))
            }
        }
    }

    static func month(_ id: String, from records: [SpendRecord]) -> Month {
        let monthRecords = records.filter { monthId(for: $0) == id }
        let excludedCount = monthRecords.filter { $0.isExcluded }.count
        let tracked = monthRecords.filter { !$0.isExcluded }

        var itemsTotal = 0.0
        var tax = 0.0
        var receiptTotal = 0.0
        var unreadablePriceCount = 0
        var rootOrder: [String] = []
        var rootTotals: [String: RootAccumulator] = [:]

        for record in tracked {
            let result = record.result
            receiptTotal += PriceFormat.value(result.total) ?? 0
            if let rawTax = result.tax, let value = PriceFormat.value(rawTax) {
                tax += value
            }
            for item in result.items {
                // An unreadable price is counted and carried at zero rather than
                // dropped: the item still happened, and the footer says how many
                // couldn't be read.
                let parsed = PriceFormat.value(item.price)
                if parsed == nil { unreadablePriceCount += 1 }
                let amount = parsed ?? 0
                itemsTotal += amount

                let rootId = root(of: item)
                if rootTotals[rootId] == nil {
                    rootOrder.append(rootId)
                    rootTotals[rootId] = RootAccumulator(
                        label: rootId == uncategorizedRoot ? "Uncategorized" : rootId.capitalized)
                }
                if let authored = rootLabel(of: item, root: rootId) {
                    rootTotals[rootId]!.label = authored
                }
                rootTotals[rootId]!.add(leaf: leafLabel(of: item), amount)
            }
        }

        let roots = rootOrder
            .compactMap { rootId -> RootGroup? in
                guard let acc = rootTotals[rootId] else { return nil }
                let leaves = acc.leaves
                    .sorted { $0.amount > $1.amount }
                    .map { Leaf(id: $0.label, label: $0.label, amount: $0.amount, itemCount: $0.count) }
                return RootGroup(id: rootId, label: acc.label, amount: acc.amount,
                                 itemCount: acc.itemCount, leaves: leaves)
            }
            .sorted { $0.amount > $1.amount }

        return Month(id: id, label: monthLabel(for: id),
                     tracked: itemsTotal + tax, itemsTotal: itemsTotal, roots: roots,
                     tax: tax, receiptTotal: receiptTotal, receiptCount: tracked.count,
                     excludedCount: excludedCount, unreadablePriceCount: unreadablePriceCount,
                     records: monthRecords)
    }
}
