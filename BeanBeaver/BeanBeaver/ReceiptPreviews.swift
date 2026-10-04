import SwiftUI
import BBReceiptKit

#if DEBUG
extension ScanTimings {
    /// Plausible on-device stage split for previews/screenshots.
    static let preview = ScanTimings(spans: [
        PhaseSpan(phase: .decode, ms: 12),
        PhaseSpan(phase: .prep, ms: 28),
        PhaseSpan(phase: .detect, ms: 322),
        PhaseSpan(phase: .classify, ms: 41),
        PhaseSpan(phase: .recognize, ms: 408),
        PhaseSpan(phase: .parse, ms: 17),
    ])
}

extension ReceiptResult {
    /// A rich, fully-populated result (mirrors the bundled Costco fixture).
    /// Categories are realistic colon-delimited beancount account paths, as
    /// emitted by the on-device classifier.
    static let previewFull = ReceiptResult(
        merchant: "Costco Wholesale",
        merchantMatch: MerchantMatch(
            raw: "Costco Wholesale", canonical: "Costco Wholesale", status: .exact, score: 1.0),
        merchantDetails: MerchantDetails(
            streetAddress: "65 Kirkham Drive", city: "Markham", region: "ON",
            postalCode: "L3S 0A9", phoneNumber: "(905) 555-0143", storeNumber: "545",
            rawLines: ["65 Kirkham Drive", "Markham, ON L3S 0A9", "Whse:545 Trm:8"]),
        date: "2026-02-18",
        dateIsPlaceholder: false,
        total: "$148.73",
        tax: "$9.42",
        subtotal: "$139.31",
        items: [
            ReceiptItem(giftCard: nil, description: "ORG BANANAS", itemNumber: nil, price: "$2.49", quantity: 1, account: "Expenses:Food:Grocery", tagPath: "grocery/fruit", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/fruit", display: "Fruit")]),
            ReceiptItem(giftCard: nil, description: "ROTISSERIE CHICKEN", itemNumber: nil, price: "$4.99", quantity: 1, account: "Expenses:Food:Grocery:PreparedMeal", tagPath: "grocery/prepared_meal", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/meat", display: "Meat"),
                          .init(path: "grocery/meat/chicken", display: "Chicken"),
                          .init(path: "grocery/prepared_meal", display: "Prepared Meal")]),
            ReceiptItem(giftCard: nil, description: "KIRKLAND OLIVE OIL 2L", itemNumber: nil, price: "$21.99", quantity: 1, account: "Expenses:Food:Grocery", tagPath: "grocery/staple", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/staple", display: "Staple")]),
            ReceiptItem(giftCard: nil, description: "BATH TISSUE 30 ROLL", itemNumber: nil, price: "$24.99", quantity: 1, account: "Expenses:Home", tagPath: "household/supply", tags: [.init(path: "household", display: "Household"), .init(path: "household/supply", display: "Supply")]),
            ReceiptItem(giftCard: nil, description: "GASOLINE REGULAR", itemNumber: nil, price: "$58.40", quantity: 1, account: "Expenses:Driving:Gas", tagPath: "driving/gas", tags: [.init(path: "driving", display: "Driving"), .init(path: "driving/gas", display: "Gas")]),
            ReceiptItem(giftCard: nil, description: "MYSTERY ITEM", itemNumber: nil, price: "$3.00", quantity: 2, account: nil, tagPath: nil, tags: []),
        ],
        warnings: [],
        rawText: "",
        imageFilename: "receipt.jpg",
        tenders: [],
        beancount: """
        2026-02-18 * "Costco Wholesale"
          Expenses:Food:Grocery        54.45 USD
          Expenses:Home                24.99 USD
          Expenses:Driving:Gas         58.40 USD
          Expenses:Uncategorized        6.00 USD
          Liabilities:CreditCard     -148.73 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview,
        confidence: FieldConfidences(
            merchant: 1.0, date: 0.98, total: 0.99, itemsCategorized: 0.83, needsReview: false),
        detections: []
    )

    /// A sparse result: no line items, inferred date, parser warnings.
    static let previewMinimal = ReceiptResult(
        merchant: "Corner Cafe",
        merchantMatch: MerchantMatch(
            raw: "Corner Cafe", canonical: nil, status: .unknown, score: 0.0),
        merchantDetails: .empty,
        date: nil,
        dateIsPlaceholder: true,
        total: "$6.50",
        tax: nil,
        subtotal: nil,
        items: [],
        warnings: [
            ReceiptWarning(kind: .subtotalMismatch,
                           message: "No line items detected", afterItemIndex: -1),
            ReceiptWarning(kind: .possibleMissedItem,
                           message: "maybe missed item near price 4.99", afterItemIndex: -1),
        ],
        rawText: "",
        imageFilename: "receipt.jpg",
        tenders: [],
        beancount: """
        2026-06-24 * "Corner Cafe"
          Expenses:Uncategorized       6.50 USD
          Liabilities:CreditCard      -6.50 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview,
        confidence: FieldConfidences(
            merchant: 0.2, date: 0.1, total: 0.9, itemsCategorized: 0.0, needsReview: true),
        detections: []
    )

    /// A low-confidence merchant: OCR read "COSCO" and the matcher offers
    /// "Costco" as an uncorroborated suggestion — the display name stays raw and
    /// the guess appears in grey.
    static let previewSuggestedMerchant = ReceiptResult(
        merchant: "Cosco",
        merchantMatch: MerchantMatch(
            raw: "Cosco", canonical: "Costco", status: .suggested, score: 0.83),
        merchantDetails: .empty,
        date: "2026-02-18",
        dateIsPlaceholder: false,
        total: "$42.10",
        tax: "$2.68",
        subtotal: "$39.42",
        items: [
            ReceiptItem(giftCard: nil, description: "PAPER TOWELS", itemNumber: nil, price: "$18.99", quantity: 1, account: "Expenses:Home", tagPath: "household/supply", tags: [.init(path: "household", display: "Household"), .init(path: "household/supply", display: "Supply")]),
            ReceiptItem(giftCard: nil, description: "ORG EGGS 24CT", itemNumber: nil, price: "$9.49", quantity: 1, account: "Expenses:Food:Grocery", tagPath: "grocery/dairy", tags: [.init(path: "grocery", display: "Grocery"), .init(path: "grocery/dairy", display: "Dairy")]),
        ],
        warnings: [],
        rawText: "",
        imageFilename: "receipt.jpg",
        tenders: [],
        beancount: """
        2026-02-18 * "Cosco"
          Expenses:Home                18.99 USD
          Expenses:Food:Grocery         9.49 USD
          Liabilities:CreditCard      -42.10 USD
        """,
        beanbeaverId: nil,
        documentRelpath: nil,
        timings: .preview,
        confidence: FieldConfidences(
            merchant: 0.83, date: 0.95, total: 0.9, itemsCategorized: 1.0, needsReview: true),
        detections: []
    )
}

#Preview("Result – full") {
    ScrollView { ReceiptResultView(result: .previewFull, wallMs: 816, capturedImageURL: nil, exporter: LedgerExporter()).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Result – minimal") {
    ScrollView { ReceiptResultView(result: .previewMinimal, wallMs: 300, capturedImageURL: nil, exporter: LedgerExporter()).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Result – suggested merchant") {
    ScrollView { ReceiptResultView(result: .previewSuggestedMerchant, wallMs: 640, capturedImageURL: nil, exporter: LedgerExporter()).padding() }
        .background(Color(.systemGroupedBackground))
}

#Preview("Screen – home") {
    ContentView()
}

#Preview("Screen – scanning") {
    ContentView(previewPipeline: .preview(.scanning))
}

#Preview("Screen – done") {
    ContentView(previewPipeline: .preview(.done(.previewFull)))
}

#Preview("Screen – failed") {
    ContentView(previewPipeline: .preview(.failed("Couldn't read this receipt. Try retaking the photo in better light.")))
}
#endif
