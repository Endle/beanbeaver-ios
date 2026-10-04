import XCTest
import BBReceiptKit
@testable import BeanBeaver

@MainActor
final class ReliabilityTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func sample(_ id: String? = nil) -> ReceiptResult {
        var result = ReceiptResult.previewFull
        result.beanbeaverId = id
        return result
    }

    func testCorruptStoreIsPreservedAndMutationsStayBlockedUntilRecovery() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("spend.json")
        let corrupt = Data("{interrupted".utf8)
        try corrupt.write(to: url)
        let store = SpendStore(fileURL: url)
        XCTAssertFalse(store.canModify)
        XCTAssertNotNil(store.storageIssue)
        XCTAssertNil(store.record(result: sample(), captureFilename: nil, wallMs: nil))
        store.removeAll()
        store.retryPersistence()
        store.flushPendingWrites()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        // Simulate restoration of a valid archive, then retry the blocked read.
        try Data("{\"records\":[]}".utf8).write(to: url)
        store.retryPersistence()
        XCTAssertTrue(store.canModify)
        XCTAssertNil(store.storageIssue)
        let id = store.record(result: sample(), captureFilename: nil, wallMs: nil)
        store.flushPendingWrites()
        XCTAssertEqual(SpendStore(fileURL: url).records.first?.id, id)
    }

    func testUnreadablePathIsNotTreatedAsMissingFile() throws {
        let dir = try directory()
        let file = JSONFile<[Int]>(url: dir)
        XCTAssertNil(file.load())
        XCTAssertTrue(file.loadFailed)
        XCTAssertFalse(file.save([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testFailedWriteRetainsMemoryAndRetryPersistsLatestSnapshot() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("spend.json")
        let store = SpendStore(fileURL: url)
        XCTAssertTrue(store.canModify) // No file yet is a normal first launch.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let first = store.record(result: sample("one"), captureFilename: nil, wallMs: nil)
        store.flushPendingWrites()
        XCTAssertNotNil(store.storageIssue)
        let second = store.record(result: sample("two"), captureFilename: nil, wallMs: nil)
        store.flushPendingWrites()
        XCTAssertEqual(store.records.count, 2)
        try FileManager.default.removeItem(at: url)
        store.retryPersistence()
        store.flushPendingWrites()
        XCTAssertNil(store.storageIssue)
        XCTAssertEqual(SpendStore(fileURL: url).records.map(\.id), [second!, first!])
    }

    func testEncodeFailurePreservesPreviousAtomicSnapshot() throws {
        let url = try directory().appendingPathComponent("values.json")
        let file = JSONFile<[Double]>(url: url)
        _ = file.load()
        XCTAssertTrue(file.save([1]))
        let before = try Data(contentsOf: url)
        XCTAssertFalse(file.save([.nan]))
        XCTAssertNotNil(file.issue)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testOrderedWritesAndStableIdentitySurviveRelaunch() throws {
        let url = try directory().appendingPathComponent("spend.json")
        let store = SpendStore(fileURL: url)
        let id = try XCTUnwrap(store.record(result: sample("original"), captureFilename: nil, wallMs: nil))
        XCTAssertEqual(store.record(result: sample("original"), captureFilename: nil, wallMs: nil), id)
        var edited = sample("corrected-date-id")
        edited.date = "2026-09-28"
        for i in 0..<20 {
            edited.merchant = "Edit \(i)"
            store.updateResult(id, to: edited)
        }
        store.flushPendingWrites()
        let loaded = SpendStore(fileURL: url)
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.records.first?.id, id)
        XCTAssertEqual(loaded.records.first?.result.merchant, "Edit 19")
        XCTAssertEqual(loaded.records.first?.result.beanbeaverId, "corrected-date-id")
    }

    func testRulesAndBatchProtectCorruptArchives() throws {
        let dir = try directory()
        let corrupt = Data("broken".utf8)
        let rulesURL = dir.appendingPathComponent("item_rules.json")
        let batchURL = dir.appendingPathComponent("batch.json")
        try corrupt.write(to: rulesURL)
        try corrupt.write(to: batchURL)
        let rules = ItemRuleStore(fileURL: rulesURL)
        XCTAssertNotNil(rules.storageIssue)
        XCTAssertThrowsError(try rules.importDocument(named: "empty", toml: ""))
        rules.remove(atOffsets: [])
        let batch = ReceiptBatch(directory: dir, store: SpendStore(ephemeralRecords: []))
        XCTAssertNotNil(batch.storageIssue)
        if case .failed = batch.add(Data([1])) {} else { XCTFail("Import must be blocked") }
        batch.discardAll()
        XCTAssertEqual(try Data(contentsOf: rulesURL), corrupt)
        XCTAssertEqual(try Data(contentsOf: batchURL), corrupt)
    }

    func testLegacyBatchRecoversStableRecordIDFromPhoto() throws {
        let dir = try directory()
        let store = SpendStore(ephemeralRecords: [])
        let batch = ReceiptBatch(directory: dir, store: store)
        _ = batch.add(Data([1]))
        var draft = try XCTUnwrap(batch.drafts.first)
        let result = sample() // No export ID: the photo is the migration key.
        draft.state = .parsed(result)
        let id = store.record(result: result, captureFilename: draft.captureFilename, wallMs: nil)
        struct Archive: Encodable { let drafts: [ReceiptDraft] }
        let bytes = try JSONEncoder().encode(Archive(drafts: [draft]))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("recordID"))
        try bytes.write(to: dir.appendingPathComponent("batch.json"))
        let loaded = ReceiptBatch(directory: dir, store: store)
        XCTAssertEqual(loaded.drafts.first?.recordID, id)
        var corrected = result
        corrected.merchant = "Legacy corrected"
        loaded.updateResult(draft.id, to: corrected)
        XCTAssertEqual(store.records.first?.result.merchant, "Legacy corrected")
        XCTAssertEqual(ReceiptBatch(directory: dir, store: store).drafts.first?.recordID, id)
    }

    func testWarningKindsSurvivePersistence() throws {
        var result = sample()
        let kinds: [ReceiptWarningKind] = [.totalMismatch, .subtotalMismatch,
            .possibleMissedItem, .priceAutoCorrected, .droppedImplausiblePrice,
            .uncategorizedItem, .tenderMismatch, .implausibleSummary]
        result.warnings = kinds.enumerated().map {
            ReceiptWarning(kind: $0.element, message: "Warning \($0.offset)", afterItemIndex: Int32($0.offset))
        }
        let decoded = try JSONDecoder().decode(ReceiptResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.warnings, result.warnings)
    }

    func testPipelineResetRejectsLateCompletionAndRepeatedStart() async throws {
        let dir = try directory()
        let scanner = ControlledScanner()
        let store = SpendStore(ephemeralRecords: [])
        let pipeline = ReceiptPipeline(scanner: scanner, store: store, captureDirectory: dir)
        let task = Task { await pipeline.scan(imageData: Data([1])) }
        await scanner.started()
        await pipeline.scan(imageData: Data([2]))
        XCTAssertEqual(scanner.calls, 1)
        pipeline.reset()
        scanner.complete(sample())
        await task.value
        if case .idle = pipeline.status {} else { XCTFail("Late result reopened the pipeline") }
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    func testPipelineEditsReceiptWithoutExportID() async throws {
        let dir = try directory()
        let scanner = ControlledScanner()
        let store = SpendStore(fileURL: dir.appendingPathComponent("spend.json"))
        let pipeline = ReceiptPipeline(scanner: scanner, store: store, captureDirectory: dir)
        let task = Task { await pipeline.scan(imageData: Data([1])) }
        await scanner.started()
        scanner.complete(sample())
        await task.value
        let id = try XCTUnwrap(pipeline.recordID)
        var edited = sample()
        edited.merchant = "Corrected"
        pipeline.replaceResult(with: edited)
        store.flushPendingWrites()
        let loaded = SpendStore(fileURL: dir.appendingPathComponent("spend.json"))
        XCTAssertEqual(loaded.records.first?.id, id)
        XCTAssertEqual(loaded.records.first?.result.merchant, "Corrected")
        pipeline.reset()
        pipeline.replaceResult(with: sample())
        if case .idle = pipeline.status {} else { XCTFail("Edit resurrected dismissed result") }
    }

    func testDiscardAndRemoveDuringBatchScanDoNotResurrectReceipts() async throws {
        for discardAll in [false, true] {
            let dir = try directory()
            let scanner = ControlledScanner()
            let store = SpendStore(ephemeralRecords: [])
            let batch = ReceiptBatch(directory: dir, store: store, scanner: scanner)
            _ = batch.add(Data([1]))
            batch.startParsing()
            await scanner.started()
            if discardAll { batch.discardAll() } else { batch.remove(batch.drafts[0].id) }
            scanner.complete(sample())
            await stopped(batch)
            XCTAssertTrue(store.records.isEmpty)
            XCTAssertTrue(batch.drafts.isEmpty)
            XCTAssertTrue(ReceiptBatch(directory: dir, store: store).drafts.isEmpty)
        }
    }

    func testBatchPauseKeepsInflightResultAndResumeStartsOnce() async throws {
        let dir = try directory()
        let scanner = ControlledScanner()
        let store = SpendStore(ephemeralRecords: [])
        let batch = ReceiptBatch(directory: dir, store: store, scanner: scanner)
        _ = batch.add(Data([1]))
        _ = batch.add(Data([2]))
        batch.startParsing()
        await scanner.started()
        batch.stopParsing()
        batch.startParsing()
        scanner.complete(sample())
        await stopped(batch)
        XCTAssertEqual(scanner.calls, 1)
        XCTAssertEqual(batch.parsedCount, 1)
        XCTAssertEqual(batch.pendingParseCount, 1)
        batch.startParsing()
        batch.startParsing()
        await scanner.started()
        scanner.complete(sample())
        await stopped(batch)
        XCTAssertEqual(scanner.calls, 2)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(batch.parsedCount, 2)

        let reloaded = ReceiptBatch(directory: dir, store: store)
        let id = try XCTUnwrap(reloaded.drafts[0].recordID)
        var edited = sample()
        edited.merchant = "Batch correction"
        reloaded.updateResult(reloaded.drafts[0].id, to: edited)
        XCTAssertEqual(store.records.first(where: { $0.id == id })?.result.merchant, "Batch correction")
    }

    func testBatchFailureCanBeRetried() async throws {
        let dir = try directory()
        let scanner = ControlledScanner()
        let batch = ReceiptBatch(directory: dir, store: SpendStore(ephemeralRecords: []), scanner: scanner)
        _ = batch.add(Data([1]))
        batch.startParsing()
        await scanner.started()
        scanner.fail()
        await stopped(batch)
        XCTAssertEqual(batch.failedCount, 1)
        batch.retry(batch.drafts[0].id)
        await scanner.started()
        scanner.complete(sample())
        await stopped(batch)
        XCTAssertEqual(batch.parsedCount, 1)
        XCTAssertEqual(batch.failedCount, 0)
    }

    func testSharedWorkerSerializesConcurrentScans() async throws {
        let sample = sample()
        let probe = WorkerProbe()
        let scanner = ReceiptScanService { _ in
            probe.enter()
            defer { probe.leave() }
            Thread.sleep(forTimeInterval: 0.01)
            return sample
        }
        let request = ReceiptScanRequest(imageData: Data(), creditCardAccount: "Liabilities:Card",
            currency: "CAD", taxAccount: "Expenses:Tax", options: ParseOptions(ruleDocuments: [], knownMerchants: []))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await scanner.scan(request) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(probe.maximum, 1)
        XCTAssertEqual(probe.count, 8)
    }

    func testCacheInvalidatesAfterMutationsAndDayChange() throws {
        var today = Date(timeIntervalSince1970: 1_790_000_000)
        let store = SpendStore(ephemeralRecords: [], now: { today })
        let id = try XCTUnwrap(store.record(result: sample(), captureFilename: nil, wallMs: nil))
        let month = store.defaultMonthId
        func verify() {
            XCTAssertEqual(store.month(month).receiptTotal, SpendSummary.month(month, from: store.records).receiptTotal)
            XCTAssertEqual(store.facts(month), SpendSummary.facts(month, from: store.records, today: today))
            XCTAssertEqual(store.trend(), SpendSummary.trend(from: store.records, today: today))
            XCTAssertEqual(store.inputs.count, store.records.count)
        }
        verify()
        store.setExcluded(true, for: id)
        verify()
        store.setExcluded(false, for: id)
        var corrected = sample()
        corrected.total = "$19.99"
        store.updateResult(id, to: corrected)
        verify()
        today = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        verify()
        store.remove(id)
        verify()
        XCTAssertTrue(store.monthIds.isEmpty)
        _ = store.defaultMonthId
        today = Calendar.current.date(byAdding: .month, value: 1, to: today)!
        XCTAssertEqual(store.defaultMonthId, SpendSummary.currentMonthId(today))
    }

    private func stopped(_ batch: ReceiptBatch, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if !batch.isParsing { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Batch did not stop", file: file, line: line)
    }
}

@MainActor
private final class ControlledScanner: ReceiptScanning {
    private var pending: CheckedContinuation<ReceiptResult, Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func scan(_ request: ReceiptScanRequest) async throws -> ReceiptResult {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func started() async {
        if pending != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func complete(_ result: ReceiptResult) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: result)
    }

    func fail() {
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: NSError(domain: "test.scan", code: 1))
    }
}

private final class WorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0
    private(set) var count = 0
    func enter() {
        lock.lock()
        active += 1
        count += 1
        maximum = max(maximum, active)
        lock.unlock()
    }
    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
