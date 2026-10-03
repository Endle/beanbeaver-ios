import Foundation
import BBReceiptKit

/// Launch with -checkReceiptPersistence for a native persistence/FFI regression
/// check. Synthetic receipts only; never writes SpendStore or ReceiptBatch.
/// The report in Documents lets scripts distinguish failure from a stale run.
enum ReceiptPersistenceCheck {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static let today = DateYmd(year: 2026, month: 10, day: 3)
    static let options = ParseOptions(ruleDocuments: [], knownMerchants: [])

    static func parse(_ text: String) throws -> ReceiptResult {
        let detections = text.split(separator: "\n").enumerated().map { index, line in
            let y = 80.0 + Double(index) * 35.0
            return DetectionInput(pointsXy: [80, y, 600, y, 600, y + 20, 80, y + 20],
                                  text: String(line), confidence: 0.99)
        }
        return try parseDetections(detections: detections, paddedWidth: 800, paddedHeight: 1600,
                                   padding: 50, imageFilename: "synthetic.jpg", today: today,
                                   creditCardAccount: "Liabilities:Card", currency: "CAD",
                                   taxAccount: "Expenses:Tax", imageSha256: nil, options: options)
    }

    static func reformat(_ previous: ReceiptResult, edits: ReceiptEdits) throws -> ReceiptResult {
        try reformatReceipt(previous: previous, today: today, creditCardAccount: "Liabilities:Card",
                            currency: "CAD", taxAccount: "Expenses:Tax", imageSha256: nil,
                            edits: edits, options: options)
    }

    static func roundTrip(_ result: ReceiptResult, at url: URL) throws -> ReceiptResult {
        try JSONEncoder().encode(result).write(to: url, options: .atomic)
        return try JSONDecoder().decode(ReceiptResult.self, from: Data(contentsOf: url))
    }

    static func export(_ result: ReceiptResult) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReceiptExportJSON(result))) as! NSDictionary
    }

    static func check(at url: URL) throws {
        let receipt = try parse("LCBO\nBOTTLE 59.70\nTOTAL 59.70\nGift Card 50.00\n123456xxxxx9876543x EXP:NONE\nAUTHOR.#:123456 BAL:0.00\nGift Card 9.70\n123456xxxxx1112223x EXP:NONE\nAUTHOR.#:789012 BAL:90.30")
        try require(receipt.tenders.count == 2, "split tender extraction")
        try require(receipt.tenders[0].giftCard?.remainingBalanceCents == 0, "reported zero")
        try require(receipt.tenders[1].giftCard?.remainingBalanceCents == 9030, "second card balance")
        var correctedTenders = receipt.tenders
        correctedTenders[1].giftCard!.remainingBalanceCents = 9000
        let corrected = try reformat(receipt, edits: ReceiptEdits(
            tenders: correctedTenders, merchant: nil, dateIso: nil, items: nil,
            total: nil, tax: nil, subtotal: nil))
        let loaded = try roundTrip(corrected, at: url)
        try require(loaded.tenders == corrected.tenders, "all tender fields after disk reload")
        try require(loaded.tenders[1].giftCard!.correctedFields == ["remaining_balance_cents"], "correction provenance")
        try require(loaded.tenders[1].giftCard!.evidence == receipt.tenders[1].giftCard!.evidence, "original evidence")
        try require(try export(loaded) == export(corrected), "export after reload")
        var draft = ReceiptEditDraft(result: loaded)
        draft.merchant = "LCBO corrected"
        let edited = try reformat(loaded, edits: draft.edits()!)
        try require(edited.tenders == loaded.tenders, "native edit after reload retains tenders")
        try require(try roundTrip(edited, at: url).tenders == edited.tenders, "edited tenders reload")

        // Exercise every expiry state, missing balance, unresolved fields, exact
        // Int64 money above Double's integer precision, and ordinary payments.
        var variants = receipt
        for (index, expiry) in [GiftCardExpiry.unknown, .noExpiry, .printedDate].enumerated() {
            var tender = receipt.tenders[0]
            tender.giftCard!.expiry = expiry
            tender.giftCard!.expiryDate = expiry == .printedDate ? "2030-01-02" : nil
            tender.giftCard!.remainingBalanceCents = index == 0 ? nil : 9_007_199_254_740_993
            tender.giftCard!.unresolvedFields = ["printed_identifier"]
            tender.account = nil
            variants.tenders = [tender, ReceiptTender(giftCard: nil, amount: "9.70", account: nil,
                                                      kind: "card", rawLabel: "Mastercard")]
            try require(try roundTrip(variants, at: url).tenders == variants.tenders, "optional/enum/integer tender round trip")
        }

        let purchase = try parse("COSTCO\n399 DOORDASH2X50 79.99\nPC 111111 ACTIVATED\n399 DOORDASH2X50 79.99\nPC 222222 ACTIVATED\nSUBTOTAL 159.98\nTOTAL 159.98\nMASTERCARD 159.98")
        try require(purchase.items.count == 2 && purchase.items.allSatisfy { $0.giftCard != nil }, "repeated packs extraction")
        let loadedPurchase = try roundTrip(purchase, at: url)
        var purchaseDraft = ReceiptEditDraft(result: loadedPurchase)
        purchaseDraft.items.reverse()
        try require(purchaseDraft.hasChanges, "identical packs with distinct references count as a reorder")
        let moved = try reformat(loadedPurchase, edits: purchaseDraft.edits()!)
        let movedLoaded = try roundTrip(moved, at: url)
        try require(movedLoaded.items[0].giftCard == purchase.items[1].giftCard, "moved pack keeps occurrence")
        try require(movedLoaded.items[1].giftCard == purchase.items[0].giftCard, "second pack keeps occurrence")
        try require(try export(movedLoaded) == export(moved), "purchase export after edit/reload")
        let exported = try export(movedLoaded)
        let exportedItems = exported["items"] as! [[String: Any]]
        let gift = exportedItems[0]["giftCard"] as! [String: Any]
        try require(gift["reference"] as? String == "222222", "export includes correct purchase")
        let tenderExport = try export(loaded)["tenders"] as! [[String: Any]]
        try require((tenderExport[1]["giftCard"] as? [String: Any])?["remainingBalanceCents"] as? Int == 9000,
                    "export includes corrected redemption")

        // A pre-metadata store has neither key. Decode without guessing or
        // recovering fields from Beancount, descriptions, or amounts.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(purchase)) as! [String: Any]
        legacy.removeValue(forKey: "tenders")
        var items = legacy["items"] as! [[String: Any]]
        for index in items.indices { items[index].removeValue(forKey: "giftCard") }
        legacy["items"] = items
        let old = try JSONDecoder().decode(ReceiptResult.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(old.tenders.isEmpty && old.items.allSatisfy { $0.giftCard == nil }, "legacy records")
        legacy["tenders"] = NSNull()
        try require(try JSONDecoder().decode(ReceiptResult.self, from: JSONSerialization.data(withJSONObject: legacy)).tenders.isEmpty,
                    "null tenders")
    }

    static func run() {
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("receipt-persistence-check.txt")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result: String
        do {
            try check(at: scratch)
            result = "PASS: extraction, corrections, edit/save/reload/export, repeated packs, optional balances, expiry, exact cents, legacy records\n"
        } catch { result = "FAIL: \(error)\n" }
        try? result.write(to: report, atomically: true, encoding: .utf8)
        NSLog("[ReceiptPersistenceCheck] %@", result)
    }
}
