import Foundation
import SwiftUI
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

    /// Exercise the drafts bound to the correction forms, then persist the
    /// corrected results for a second process to verify after relaunch.
    static func checkEditors() throws {
        for (input, expected) in [("0", Int64(0)), ("12.3", 1230), ("12,34", 1234),
                                  ("90071992547409.93", 9_007_199_254_740_993),
                                  ("92233720368547758.07", Int64.max)] {
            try require(try GiftCardInput.cents(input, field: "Balance") == expected, "exact editor cents")
        }
        try require(try GiftCardInput.cents(" ", field: "Balance") == nil, "blank means unknown")
        for input in ["-1", "1.234", "1,234.00", "1e2", "NaN", "92233720368547758.08"] {
            try require((try? GiftCardInput.cents(input, field: "Balance")) == nil, "invalid money rejected: \(input)")
        }
        let receipt = try parse("LCBO\nBOTTLE 59.70\nTOTAL 59.70\nGift Card 50.00\n123456xxxxx9876543x EXP:NONE\nAUTHOR.#:123456 BAL:0.00\nGift Card 9.70\n123456xxxxx1112223x EXP:NONE\nAUTHOR.#:789012 BAL:90.30")
        var draft = ReceiptEditDraft(result: receipt)
        var payment = GiftCardRedemptionDraft(draft.tenders[1])
        draft.tenders[1] = try payment.applied()
        try require(!draft.hasChanges, "applying untouched payment is a no-op")
        payment.identifier = "123456xxxxx7654321x"
        payment.balance = "123.45"
        payment.authorization = "corrected-reference"
        payment.expiry = .printedDate
        try require((try? payment.applied()) == nil, "printed expiry requires date")
        payment.expiryDate = "2030/12/31"
        draft.tenders[1] = try payment.applied()
        try require(draft.tendersChanged, "payment edit reaches receipt draft")
        let corrected = try reformat(receipt, edits: draft.edits()!)
        let gift = corrected.tenders[1].giftCard!
        try require(gift.normalizedIdentifier == "123456*****7654321*", "Rust normalizes corrected mask")
        try require(gift.remainingBalanceCents == 12345 && gift.expiryDate == "2030/12/31", "form values applied")
        try require(gift.evidence == receipt.tenders[1].giftCard!.evidence, "payment correction keeps original evidence")
        try require(gift.correctedFields.contains("printed_identifier") && gift.correctedFields.contains("remaining_balance_cents"), "payment provenance")
        try require(corrected.tenders[0] == receipt.tenders[0], "other payment untouched")
        payment.balance = ""; payment.expiry = .unknown
        let clearedPayment = try payment.applied()
        try require(clearedPayment.giftCard!.remainingBalanceCents == nil && clearedPayment.giftCard!.expiryDate == nil, "clear balance and expiry")
        payment.amount = ""
        try require((try? payment.applied()) == nil, "payment amount is required")

        let purchase = try parse("COSTCO\n399 DOORDASH2X50 79.99\nPC 111111 ACTIVATED\n399 DOORDASH2X50 79.99\nPC 222222 ACTIVATED\nSUBTOTAL 159.98\nTOTAL 159.98\nMASTERCARD 159.98")
        var purchaseDraft = ReceiptEditDraft(result: purchase)
        var pack = GiftCardPurchaseDraft(purchase.items[0].giftCard!)
        purchaseDraft.items[0].giftCard = try pack.applied()
        try require(!purchaseDraft.hasChanges, "applying untouched purchase is a no-op")
        pack.count = "0"
        try require((try? pack.applied()) == nil, "zero card count rejected")
        pack.count = "3"; pack.denomination = "25.00"
        pack.reference = "corrected-pack"
        purchaseDraft.items[0].giftCard = try pack.applied()
        let correctedPurchase = try reformat(purchase, edits: purchaseDraft.edits()!)
        let correctedPack = correctedPurchase.items[0].giftCard!
        try require(correctedPack.totalFaceValueCents == 7500 && correctedPack.faceValueDerived, "face value derives from corrected count/value")
        try require(correctedPurchase.items[0].price == "79.99", "face value does not change price paid")
        try require(correctedPack.evidence == purchase.items[0].giftCard!.evidence, "purchase evidence retained")
        try require(correctedPack.correctedFields.contains("card_count"), "purchase provenance")
        try require(correctedPurchase.items[1].giftCard == purchase.items[1].giftCard, "other pack untouched")
        pack.count = "4294967295"; pack.denomination = "92233720368547758.07"
        try require((try? pack.applied()) == nil, "derived face value overflow rejected")
        pack.derived = false; pack.count = ""; pack.denomination = ""; pack.totalFaceValue = ""
        pack.activation = .unknown
        let unknown = try pack.applied()
        try require(unknown.totalFaceValueCents == nil && unknown.cardCount == nil && unknown.activation == .unknown,
                    "unknown purchase values remain absent")
        try JSONEncoder().encode([corrected, correctedPurchase]).write(to: archiveURL, options: .atomic)
    }

    static var archiveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("receipt-persistence-relaunch.json")
    }

    static func checkRelaunch() throws {
        let receipts = try JSONDecoder().decode([ReceiptResult].self, from: Data(contentsOf: archiveURL))
        try require(receipts.count == 2, "relaunch archive")
        let payment = receipts[0].tenders[1].giftCard!
        let purchase = receipts[1].items[0].giftCard!
        try require(payment.remainingBalanceCents == 12345 && payment.normalizedIdentifier == "123456*****7654321*", "payment correction after process relaunch")
        try require(payment.correctedFields.contains("printed_identifier") && !payment.evidence.isEmpty, "payment evidence after relaunch")
        try require(purchase.reference == "corrected-pack" && purchase.totalFaceValueCents == 7500, "purchase correction after process relaunch")
        try require(purchase.correctedFields.contains("card_count") && !purchase.evidence.isEmpty, "purchase evidence after relaunch")
        let tenders = try export(receipts[0])["tenders"] as! [[String: Any]]
        try require((tenders[1]["giftCard"] as! [String: Any])["remainingBalanceCents"] as? Int == 12345, "corrected payment export after relaunch")
        let items = try export(receipts[1])["items"] as! [[String: Any]]
        try require((items[0]["giftCard"] as! [String: Any])["totalFaceValueCents"] as? Int == 7500, "corrected purchase export after relaunch")
        try FileManager.default.removeItem(at: archiveURL)
    }

    static func run(relaunch: Bool = false) {
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("receipt-persistence-check.txt")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result: String
        do {
            if relaunch {
                try checkRelaunch()
            } else {
                try check(at: scratch)
                try checkEditors()
            }
            result = "PASS: extraction, corrections, edit/save/reload/export, repeated packs, optional balances, expiry, exact cents, legacy records, correction forms (relaunch=\(relaunch))\n"
        } catch { result = "FAIL: \(error)\n" }
        try? result.write(to: report, atomically: true, encoding: .utf8)
        NSLog("[ReceiptPersistenceCheck] %@", result)
    }
}

/// Launch-only synthetic previews for inspecting these forms without putting
/// test receipts in the spending store. They use the production views.
struct ReceiptPersistencePreview: View {
    let mode: String
    @State private var result: ReceiptResult?
    @State private var error: String?

    static var requestedMode: String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-previewGiftCard") }
    }

    var body: some View {
        NavigationStack {
            if let result {
                switch mode {
                case "-previewGiftCardPaymentEditor":
                    GiftCardRedemptionEditor(tender: result.tenders[1]) { tender in
                        var draft = ReceiptEditDraft(result: result)
                        draft.tenders[1] = tender
                        apply(draft, to: result)
                    }
                case "-previewGiftCardPurchaseEditor":
                    GiftCardPurchaseEditor(gift: result.items[0].giftCard!) { gift in
                        var draft = ReceiptEditDraft(result: result)
                        draft.items[0].giftCard = gift
                        apply(draft, to: result)
                    }
                case "-previewGiftCardReceiptEditor":
                    ReceiptEditorView(original: result) { self.result = $0 }
                case "-previewGiftCardPurchase":
                    ScrollView {
                        GiftCardPurchaseDetails(item: result.items[0], gift: result.items[0].giftCard!)
                            .padding()
                    }.navigationTitle("Gift-card purchase")
                default:
                    ScrollView {
                        VStack(spacing: 24) {
                            ForEach(result.tenders.indices, id: \.self) { index in
                                if let gift = result.tenders[index].giftCard {
                                    GiftCardPaymentDetails(tender: result.tenders[index], gift: gift, number: index + 1)
                                }
                            }
                        }.padding()
                    }.navigationTitle("Gift-card payments")
                }
            } else {
                Text(error ?? "Loading synthetic receipt…")
            }
        }
        .tint(.bbAccent)
        .task {
            do {
                if mode.contains("Purchase") {
                    result = try ReceiptPersistenceCheck.parse("COSTCO\n399 DOORDASH2X50 79.99\nPC 111111 ACTIVATED\nSUBTOTAL 79.99\nTOTAL 79.99\nMASTERCARD 79.99")
                } else {
                    result = try ReceiptPersistenceCheck.parse("LCBO\nBOTTLE 59.70\nTOTAL 59.70\nGift Card 50.00\n123456xxxxx9876543x EXP:NONE\nAUTHOR.#:123456 BAL:0.00\nGift Card 9.70\n123456xxxxx1112223x EXP:NONE\nAUTHOR.#:789012 BAL:90.30")
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func apply(_ draft: ReceiptEditDraft, to previous: ReceiptResult) {
        guard let edits = draft.edits() else { return }
        do { result = try ReceiptPersistenceCheck.reformat(previous, edits: edits) }
        catch { self.error = error.localizedDescription }
    }
}
