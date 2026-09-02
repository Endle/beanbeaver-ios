import Foundation
import BBReceiptKit

/// A launch-flag benchmark for the spend seam — the projection across the FFI
/// and the screens built on it.
///
/// **Not `#if DEBUG`, deliberately.** A Debug build inverts the ranking of
/// everything here: the Swift projection is unoptimized while the Rust behind
/// the FFI is the same release staticlib either way, so a Debug measurement
/// would overstate the Swift half and understate the crossing. The numbers are
/// only meaningful from a Release build, which is exactly the configuration
/// `#if DEBUG` would compile this out of. It follows the same
/// launch-argument-gated pattern the app already ships for `-showAmounts`
/// (`Theme.swift`) and `-lockPremium` (`Entitlements.swift`), and it is
/// unreachable without the flag.
///
/// ```
/// xcrun simctl launch --console-pty booted com.beanbeaver.BeanBeaver -benchSpend
/// ```
///
/// # What it measures
///
/// Two layers, because they answer different questions:
///
/// - **Primitives** — one `SpendSummary` call each. What a single crossing
///   costs, so a screen's cost can be predicted from how many it makes.
/// - **Screen replicas** — the exact sequence of `SpendSummary` calls one body
///   pass of `HomeView`, `SpendingView` and `ReceiptsView` makes. These mirror
///   the views by hand and must be updated with them; each one names the lines
///   it is standing in for. A replica rather than the real view because
///   driving SwiftUI's body evaluation from a harness measures SwiftUI, not
///   this seam.
///
/// # The corpus is real, not hand-written
///
/// One scan of the bundled sample supplies the item count, the descriptions and
/// the tag distribution; the records are that parse repeated across months with
/// distinct ids and dates. A hand-written fixture would let the benchmark
/// quietly diverge from what a receipt actually carries — which is what makes
/// the projection expensive.
@MainActor
enum SpendPerf {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-benchSpend")
    }

    /// Corpus sizes to sweep. 200 is roughly a year of weekly shopping; 800 is
    /// the same user four years in, and it is there to show the growth curve
    /// rather than to describe anyone today.
    private static let sizes = [50, 200, 800]
    /// How many months the corpus spreads over — the multiplier on every
    /// per-month loop in the screens.
    private static let months = 8

    static func run() async {
        log("start · \(BBReceiptCore.version) · \(configuration)")

        let pipeline = ReceiptPipeline()
        await pipeline.scanBundledSample(named: "costco_20260301_redact")
        guard case .done(let sample) = pipeline.status else {
            log("FAILED: could not scan the bundled sample for a corpus seed")
            return
        }
        log("seed: \(sample.merchant) · \(sample.items.count) items · "
            + "\(sample.items.reduce(0) { $0 + $1.tags.count }) tags")

        for size in sizes {
            let store = SpendStore(ephemeralRecords: corpus(from: sample, count: size))
            log("--- \(size) receipts over \(months) months ---")
            verify(store)
            primitives(store)
            screens(store)
        }
        log("done")
    }

    // MARK: - Corpus

    /// `count` records built from one real parse, spread evenly over `months`
    /// calendar months ending this one. Each gets its own `UUID` and its own
    /// printed date, so month bucketing and per-record identity both behave the
    /// way they do in a real store.
    private static func corpus(from sample: ReceiptResult, count: Int) -> [SpendRecord] {
        let calendar = Calendar.current
        let now = Date()
        return (0..<count).map { i in
            let monthsBack = i % months
            let date = calendar.date(byAdding: .month, value: -monthsBack, to: now) ?? now
            let c = calendar.dateComponents([.year, .month], from: date)
            let day = (i % 28) + 1
            var result = sample
            result.date = String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, day)
            result.dateIsPlaceholder = false
            // Distinct per record: `SpendStore.record` dedups on it, and
            // `markExported` matches on it.
            result.beanbeaverId = "bench-\(i)"
            return SpendRecord(id: UUID(), result: result, scannedAt: date,
                               captureFilename: nil, wallMs: nil)
        }
    }

    // MARK: - Correctness

    /// Every memoized figure against the uncached `SpendSummary` call it stands
    /// in for.
    ///
    /// The caching is only worth anything if it is invisible, and "invisible" is
    /// a claim about numbers, not about types — a wrong cache key or a
    /// mis-scoped filter would compile and quietly report a different total.
    /// Run before the timings so a benchmark can never report a fast wrong
    /// answer.
    private static func verify(_ store: SpendStore) {
        let records = store.records
        var failures: [String] = []

        func check(_ label: String, _ ok: Bool) {
            if !ok { failures.append(label) }
        }

        check("monthIds", store.monthIds == SpendSummary.monthIds(from: records))
        check("defaultMonthId", store.defaultMonthId == SpendSummary.defaultMonthId(from: records))
        check("monthId(for:)", records.allSatisfy {
            store.monthId(for: $0) == SpendSummary.monthId(for: $0)
        })

        for id in store.monthIds {
            let cached = store.month(id)
            let direct = SpendSummary.month(id, from: records)
            check("month(\(id)).tracked", cached.tracked == direct.tracked)
            check("month(\(id)).itemsTotal", cached.itemsTotal == direct.itemsTotal)
            check("month(\(id)).tax", cached.tax == direct.tax)
            check("month(\(id)).receiptTotal", cached.receiptTotal == direct.receiptTotal)
            check("month(\(id)).receiptCount", cached.receiptCount == direct.receiptCount)
            check("month(\(id)).excludedCount", cached.excludedCount == direct.excludedCount)
            check("month(\(id)).unreadable", cached.unreadablePriceCount == direct.unreadablePriceCount)
            check("month(\(id)).maxLeaf", cached.maxLeafAmount == direct.maxLeafAmount)
            check("month(\(id)).unaccounted", cached.unaccounted == direct.unaccounted)
            check("month(\(id)).recordIds", cached.records.map(\.id) == direct.records.map(\.id))
            check("month(\(id)).roots", cached.roots.map(\.id) == direct.roots.map(\.id))
            check("month(\(id)).rootAmounts", cached.roots.map(\.amount) == direct.roots.map(\.amount))
            check("month(\(id)).leaves",
                  cached.roots.map { $0.leaves.map(\.label) } == direct.roots.map { $0.leaves.map(\.label) })

            // `records(inMonth:)` replaced a filter over `SpendSummary.monthId`.
            let bucketed = store.records(inMonth: id).map(\.id)
            let filtered = records.filter { SpendSummary.monthId(for: $0) == id }.map(\.id)
            check("records(inMonth: \(id))", bucketed == filtered)

            let facts = store.facts(id)
            let directFacts = SpendSummary.facts(id, from: records)
            check("facts(\(id)).dailyAverage", facts.dailyAverage == directFacts.dailyAverage)
            check("facts(\(id)).previousTotal", facts.previousTotal == directFacts.previousTotal)
            check("facts(\(id)).days", facts.days == directFacts.days)
        }

        // Trend and the drill-downs, for all spending and for each root of the
        // month a screen opens on — the scopes the chips actually offer.
        var scopes: [SpendSummary.Category?] = [nil]
        for root in store.month(store.defaultMonthId).roots {
            scopes.append(.root(root.id))
            for leaf in root.leaves { scopes.append(.leaf(leaf.label)) }
        }
        for scope in scopes {
            let name = scope.map { "\($0)" } ?? "all"
            check("trend(\(name))",
                  store.trend(scope).amounts == SpendSummary.trend(scope, from: records).amounts)
            guard let scope else { continue }
            check("receipts(\(name))",
                  store.receipts(scope).map(\.record.id)
                      == SpendSummary.receipts(scope, from: records).map(\.record.id))
            check("receipts(\(name)).amounts",
                  store.receipts(scope).map(\.amount)
                      == SpendSummary.receipts(scope, from: records).map(\.amount))
            check("items(\(name))",
                  store.items(scope).map(\.id) == SpendSummary.items(scope, from: records).map(\.id))
        }

        if failures.isEmpty {
            log("verify: PASS (\(records.count) records, \(store.monthIds.count) months, "
                + "\(scopes.count) scopes)")
        } else {
            log("verify: FAIL — \(failures.count) mismatch(es): "
                + failures.prefix(8).joined(separator: ", "))
        }
    }

    // MARK: - Primitives

    /// The uncached `SpendSummary` calls, so the cost a memo avoids stays
    /// visible after the memo exists. These deliberately do **not** go through
    /// `SpendStore`.
    private static func primitives(_ store: SpendStore) {
        let records = store.records
        let id = SpendSummary.defaultMonthId(from: records)

        measure("projection only") { sink(records.map(\.spendInput).count) }
        measure("defaultMonthId") { sink(SpendSummary.defaultMonthId(from: records)) }
        measure("monthIds") { sink(SpendSummary.monthIds(from: records)) }
        measure("month") { sink(SpendSummary.month(id, from: records)) }
        measure("facts") { sink(SpendSummary.facts(id, from: records)) }
        measure("trend") { sink(SpendSummary.trend(from: records)) }
        // The per-record crossing behind `Filter.matches` and `monthChips` —
        // measured over the whole corpus, which is how the views used to call it.
        measure("monthId × corpus") {
            for record in records { sink(SpendSummary.monthId(for: record)) }
        }
    }

    // MARK: - Screen replicas

    /// Each screen twice, because the two are different questions.
    ///
    /// - **warm** — the cache is valid, which is every body pass that is not the
    ///   first after a change: a scroll, the privacy eye, a chip, a push and a
    ///   pop. This is the overwhelmingly common case and the one that was
    ///   missing a frame.
    /// - **cold** — a fresh store per iteration, so nothing is memoized. What
    ///   the *first* pass after a scan or an edit costs. It is the honest
    ///   ceiling: caching moves this work from once-per-pass to
    ///   once-per-change, it does not delete it.
    private static func screens(_ store: SpendStore) {
        measure("HomeView warm") { homeBodyPass(store) }
        measure("SpendingView warm") { spendingBodyPass(store) }
        measure("ReceiptsView warm") { receiptsBodyPass(store) }

        let records = store.records
        measure("HomeView cold") { homeBodyPass(SpendStore(ephemeralRecords: records)) }
        measure("SpendingView cold") { spendingBodyPass(SpendStore(ephemeralRecords: records)) }
        measure("ReceiptsView cold") { receiptsBodyPass(SpendStore(ephemeralRecords: records)) }
    }

    /// Mirrors `HomeView.loaded` (`:75`, `:76`) and `weeklyCard` (`:144`).
    /// `monthId` is still a computed property read twice — the point is that it
    /// no longer matters what it costs to read one twice.
    private static func homeBodyPass(_ store: SpendStore) {
        sink(store.month(store.defaultMonthId))
        sink(store.facts(store.defaultMonthId))
        sink(store.trend())
    }

    /// Mirrors `SpendingView.content`. `summary` (`:51`) is a computed property
    /// read at `:112`, `:161`×2, `:190`, `:211`, `:272`, `:436` (once per root
    /// card) and `:569`–`:597`; each read also re-runs `activeMonthID` (`:48`).
    /// Plus `facts` (`:232`) and `trend` (`:297`).
    private static func spendingBodyPass(_ store: SpendStore) {
        func summary() -> SpendSummary.Month { store.month(store.defaultMonthId) }
        let roots = summary().roots.count
        // The fixed reads, then one per root card.
        for _ in 0..<(18 + roots) { sink(summary()) }
        sink(store.facts(store.defaultMonthId))
        sink(store.trend(nil))
    }

    /// Mirrors `ReceiptsView` unscoped with no chip selected — the state every
    /// fresh navigation into the list starts in.
    ///
    /// `monthChips` (`:222`) costs one crossing per record per month, and
    /// `activeFilter` → `defaultFilter` (`:67`) re-evaluates it for every chip.
    /// `categoryShare` (`:371`) is three whole-corpus calls and is read once per
    /// row from `detail(for:)` (`:386`).
    private static let visibleRows = 10

    private static func receiptsBodyPass(_ store: SpendStore) {
        let records = store.records

        func monthChips() -> [String] {
            let ids = store.monthIds
            for id in ids { sink(store.records(inMonth: id).count) }
            return ids
        }
        func categoryShare() {
            guard let root = store.month(store.defaultMonthId).roots.first else { return }
            sink(store.receipts(.root(root.id)))
        }

        // `filterChips` reads both once now, so the chip count no longer
        // multiplies anything — kept in the shape of the old measurement so the
        // two runs compare.
        sink(monthChips())
        // `records` (`:73`) filters the corpus through `Filter.matches`.
        let filter = ReceiptsFilterProbe.month(store.defaultMonthId)
        sink(records.filter { filter.matches($0, in: store) }.count)
        // One share for the whole list, not one per row.
        categoryShare()
    }

    /// Stands in for `ReceiptsView.Filter`, which is private to that view. Same
    /// month case, same call into the store — the only one that ever cost
    /// anything.
    private enum ReceiptsFilterProbe {
        case month(String)

        @MainActor
        func matches(_ record: SpendRecord, in store: SpendStore) -> Bool {
            switch self {
            case .month(let id): return store.monthId(for: record) == id
            }
        }
    }

    // MARK: - Timing

    /// Runs `body` until at least `minDuration` has elapsed, then reports the
    /// mean. A single run of a fast primitive is dominated by whatever else the
    /// scheduler was doing; a fixed iteration count either wastes seconds on the
    /// slow cases or under-samples the fast ones.
    private static let minDuration = 0.35
    private static let maxIterations = 2000

    /// Keeps a measured value alive so the optimizer cannot delete the work
    /// that produced it. Without this, `projection only` is dead code in a
    /// Release build and reports a time that is not the projection's.
    @inline(never)
    private static func sink<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }

    private static func measure(_ label: String, _ body: () -> Void) {
        // One untimed pass: the first call through a UniFFI function resolves
        // its symbol and warms the Rust side's allocator.
        body()
        var iterations = 0
        let started = Date()
        var elapsed = 0.0
        while elapsed < minDuration && iterations < maxIterations {
            body()
            iterations += 1
            elapsed = Date().timeIntervalSince(started)
        }
        let meanMs = elapsed / Double(iterations) * 1000
        log(String(format: "%-24s %8.3f ms  (n=%d)",
                   (label as NSString).utf8String!, meanMs, iterations))
    }

    private static var configuration: String {
        #if DEBUG
        return "DEBUG BUILD — numbers are not comparable to Release"
        #else
        return "release"
        #endif
    }

    private static func log(_ message: String) {
        NSLog("[SpendPerf] %@", message)
    }
}
