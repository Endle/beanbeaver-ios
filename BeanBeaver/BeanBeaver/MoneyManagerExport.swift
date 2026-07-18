import Foundation
import BBReceiptKit

/// Turns scanned receipts into an `.xlsx` that Realbyte's *Money Manager* app
/// imports (More → Backup → Import excel file). One row per line item, so the
/// per-item categorization BeanBeaver produces survives the trip — the whole
/// reason to itemize in the first place.
///
/// Realbyte's fixed column order is
/// `Date, Account, Category, Subcategory, Note, Amount, Income/Expense, Description`,
/// dates `MM/dd/yyyy`, and both `Account` and `Category` must be non-empty
/// (ideally matching names already set up in the user's Money Manager). See
/// help.realbyteapps.com/hc/en-us/articles/360043223253. The container itself is
/// built by ``MoneyManagerWorkbook``.
enum MoneyManagerExport {
    /// UserDefaults key the settings screen writes and this reads, so the
    /// exported `Account` column matches an account in the user's Money Manager.
    static let accountKey = "moneyManagerAccount"
    static let defaultAccount = "Cash"

    /// The configured account name, or ``defaultAccount`` when unset/blank —
    /// never empty, since Realbyte rejects a blank `Account`.
    static var account: String {
        let raw = UserDefaults.standard.string(forKey: accountKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw.map { !$0.isEmpty } ?? false) ? raw! : defaultAccount
    }

    static let header = ["Date", "Account", "Category", "Subcategory",
                         "Note", "Amount", "Income/Expense", "Description"]

    /// Header row followed by one row per line item across every result. A
    /// receipt with no parsed items still contributes a single row for its total,
    /// so nothing scanned is silently dropped from the export.
    static func rows(for results: [ReceiptResult], account: String, today: Date = Date()) -> [[String]] {
        var rows: [[String]] = [header]
        for result in results {
            let date = dateString(result, today: today)
            if result.items.isEmpty {
                rows.append(row(category: "Uncategorized", note: result.merchant,
                                price: result.total, merchant: result.merchant,
                                date: date, account: account))
            } else {
                for item in result.items {
                    let note = item.quantity > 1 ? "\(item.description) ×\(item.quantity)" : item.description
                    rows.append(row(category: category(for: item), note: note,
                                    price: item.price, merchant: result.merchant,
                                    date: date, account: account))
                }
            }
        }
        return rows
    }

    /// Serialize `results` to a temp `.xlsx` and return its URL, ready for the
    /// share sheet.
    static func makeFile(for results: [ReceiptResult],
                         account: String = MoneyManagerExport.account,
                         today: Date = Date()) throws -> URL {
        let data = MoneyManagerWorkbook.xlsx(
            sheetName: "Transactions",
            rows: rows(for: results, account: account, today: today))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(today: today))
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Row mapping

    private static func row(category: String, note: String, price: String,
                            merchant: String, date: String, account: String) -> [String] {
        let amount = amountString(price)
        return [
            date,
            account,
            category,
            "",                                        // Subcategory — unused in v1
            note,
            amount.magnitude,
            amount.isNegative ? "Income" : "Expense",  // a negative line is a discount/refund
            merchant,
        ]
    }

    /// The most-specific classifier tag, capitalized — the same label the result
    /// screen shows (``CategoryDisplay/tagDisplay(for:)``). Never empty.
    private static func category(for item: ReceiptItem) -> String {
        CategoryDisplay.tagDisplay(for: item.tags).primary ?? "Uncategorized"
    }

    /// `result.date` (ISO `yyyy-MM-dd`) as `MM/dd/yyyy`. A missing or placeholder
    /// date falls back to today — Realbyte requires a real date, and the scan
    /// date is the best stand-in.
    private static func dateString(_ result: ReceiptResult, today: Date) -> String {
        if !result.dateIsPlaceholder, let iso = result.date, let date = isoParser.date(from: iso) {
            return usFormatter.string(from: date)
        }
        return usFormatter.string(from: today)
    }

    /// Parse a loosely-formatted price to a plain, positive 2-dp number string
    /// plus its sign — mirrors ``PriceFormat`` but emits a bare number (Money
    /// Manager wants the amount with no currency symbol). Unparseable → "0.00"
    /// positive, so a row never carries a blank amount.
    private static func amountString(_ raw: String) -> (magnitude: String, isNegative: Bool) {
        let filtered = raw.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = Double(filtered) else { return ("0.00", false) }
        return (String(format: "%.2f", abs(value)), value < 0)
    }

    private static func fileName(today: Date) -> String {
        "beanbeaver-moneymanager-\(fileStampFormatter.string(from: today)).xlsx"
    }

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let usFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy"
        return f
    }()

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
