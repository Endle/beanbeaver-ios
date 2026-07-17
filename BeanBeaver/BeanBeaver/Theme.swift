import SwiftUI

extension Color {
    /// Primary brand accent — a legible red, not flag-saturated.
    static let bbAccent = Color(red: 0.80, green: 0.11, blue: 0.15)

    /// Soft red tint for badges/banners over a white/system background.
    static let bbAccentSoft = Color.bbAccent.opacity(0.12)
}

/// Card container: system background, rounded corners, soft shadow.
struct BBCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

extension View {
    func bbCard() -> some View { modifier(BBCard()) }
}

/// A receipt line item's category may come back as a colon-delimited
/// beancount account path (e.g. "Expenses:Food:Grocery:Dairy") or as a plain
/// single word (e.g. "Dairy", "Pharmacy", or a brand name like "Coca Cola",
/// observed from real on-device output) — map it to an icon and a friendly
/// leaf label for display.
enum CategoryDisplay {
    struct Style {
        let icon: String
        let label: String
        /// Whether the badge should use the brand accent (a recognized
        /// category) or a neutral gray (uncategorized/unknown).
        let accented: Bool
    }

    static func style(for category: String?) -> Style {
        guard let category, !category.isEmpty else {
            return Style(icon: "tag", label: "Uncategorized", accented: false)
        }
        let segments = category.split(separator: ":").map(String.init)
        let leaf = segments.last ?? category
        return Style(icon: icon(for: category), label: friendlyLabel(leaf), accented: true)
    }

    /// How an item's beanbeaver-internal tags render in the list. The classifier
    /// emits tags broad→specific (e.g. `["grocery", "meat", "chicken"]`), so the
    /// last one is the most specific — we lead with it and keep the rest as
    /// context. This is the source of truth for the row's category display; the
    /// beancount account is no longer reverse-engineered for the label.
    struct TagDisplay {
        /// Most specific tag, capitalized (e.g. "Chicken"). Empty tags → nil.
        let primary: String?
        /// The remaining (broader) tags, capitalized, in classifier order.
        let rest: [String]
    }

    static func tagDisplay(for tags: [String]) -> TagDisplay {
        let cleaned = tags.filter { !$0.isEmpty }
        guard let last = cleaned.last else {
            return TagDisplay(primary: nil, rest: [])
        }
        let rest = cleaned.dropLast().map { $0.capitalized }
        return TagDisplay(primary: last.capitalized, rest: rest)
    }

    /// Keyword → SF Symbol, checked as a substring against the whole
    /// (lowercased) category string so both account-path segments (e.g.
    /// "Food", "Driving") and plain leaf words (e.g. "Dairy", "Pharmacy")
    /// resolve to a specific icon. Order matters — more specific keywords
    /// are checked first. Falls back to a generic cart icon.
    private static let keywordIcons: [(String, String)] = [
        ("dairy", "drop.fill"), ("produce", "carrot.fill"),
        ("bakery", "birthday.cake.fill"), ("meat", "fork.knife"),
        ("drink", "cup.and.saucer.fill"), ("beverage", "cup.and.saucer.fill"),
        ("grocery", "cart.fill"), ("food", "fork.knife"), ("restaurant", "fork.knife"),
        ("pharmacy", "cross.case.fill"), ("health", "cross.case.fill"),
        ("personalcare", "heart.fill"), ("personal care", "heart.fill"),
        ("gas", "fuelpump.fill"), ("driving", "car.fill"), ("parking", "car.fill"),
        ("taxi", "car.fill"), ("travel", "airplane"), ("flight", "airplane"),
        ("hotel", "bed.double.fill"),
        ("furniture", "sofa.fill"), ("utility", "bolt.fill"), ("utilities", "bolt.fill"),
        ("home", "house.fill"), ("household", "house.fill"),
        ("clothing", "tshirt.fill"), ("shopping", "bag.fill"),
        ("entertainment", "ticket.fill"), ("uncategorized", "tag"),
    ]

    private static func icon(for category: String) -> String {
        let lowered = category.lowercased()
        for (keyword, icon) in keywordIcons where lowered.contains(keyword) {
            return icon
        }
        return "cart.fill"
    }

    /// "PreparedMeal" -> "Prepared Meal", "TakeOut" -> "Take Out".
    private static func friendlyLabel(_ leaf: String) -> String {
        var result = ""
        for (index, char) in leaf.enumerated() {
            if index > 0, char.isUppercase {
                result.append(" ")
            }
            result.append(char)
        }
        return result
    }
}

/// Receipt dates arrive from the parser as ISO `YYYY-MM-DD` — render them the
/// way a person writes a date. Falls back to the raw string unchanged if it
/// isn't parseable, so nothing is ever hidden.
enum ReceiptDateFormat {
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    static func friendly(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let parsed = isoFormatter.date(from: raw) else { return raw }
        return displayFormatter.string(from: parsed)
    }
}

/// Receipt prices/totals arrive as loosely-formatted strings from the OCR
/// pipeline (e.g. "17.1900", "-3.5000", or already-clean "$2.49") — normalize
/// them to a consistent "$X.XX" for display. Falls back to the raw string
/// unchanged if it isn't parseable, so nothing is ever hidden or mangled.
enum PriceFormat {
    struct Display {
        let text: String
        let isNegative: Bool
    }

    static func display(_ raw: String) -> Display {
        let filtered = raw.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = Double(filtered) else {
            return Display(text: raw, isNegative: false)
        }
        let sign = value < 0 ? "-" : ""
        let text = "\(sign)$" + String(format: "%.2f", abs(value))
        return Display(text: text, isNegative: value < 0)
    }
}
