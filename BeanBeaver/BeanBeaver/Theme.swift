import SwiftUI
import BBReceiptKit

extension Color {
    /// Primary brand accent — a legible red, not flag-saturated.
    static let bbAccent = Color(red: 0.80, green: 0.11, blue: 0.15)

    /// Soft red tint for badges/banners over a white/system background.
    static let bbAccentSoft = Color.bbAccent.opacity(0.12)

    /// "This receipt reached your ledger." Deliberately *not* `bbAccent`: red is
    /// the tap-me colour (see `BBQuietButton`), and export state is a readout,
    /// never an action.
    static let bbExported = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.78, blue: 0.44, alpha: 1)   // lifted for dark
            : UIColor(red: 0.14, green: 0.54, blue: 0.24, alpha: 1)   // #248A3D
    })

    /// "Not filed yet." Amber rather than red because a backlog is a *pending*
    /// state, not an error — nothing is wrong with a receipt you scanned two
    /// minutes ago.
    static let bbUnexported = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.91, green: 0.60, blue: 0.32, alpha: 1)
            : UIColor(red: 0.78, green: 0.41, blue: 0.16, alpha: 1)   // #C7692A
    })
}

/// The receipt-paper palette — **light mode only**, by design.
///
/// The redesign puts the app's surfaces on warm paper rather than the system's
/// cool grey: a cream canvas, an off-white card, and a warm near-black ink. It
/// is the cheapest half of "this app is about receipts" — no illustration, no
/// texture, just a ground that isn't `systemGroupedBackground`.
///
/// **Every one of these is a pair, and the dark half is the system colour.**
/// Dark mode was not designed, and a warm palette invented for it here would be
/// a guess that ships. So in dark each token resolves to exactly what the app
/// used before, which means a dark build is unchanged and a light build is the
/// redesign. Things derived from these — the torn edge, the hairlines — follow
/// automatically.
///
/// Scoped to the redesigned surfaces (Home, Spending, Receipts, the scan result
/// and their pushes) — plus **Settings**, which was left platform-standard by
/// the original handoff and looked like a different app once it became a tab
/// root sitting beside Home. Its list takes the canvas the same way
/// `ReceiptsView`'s does: `.scrollContentBackground(.hidden)` for the ground,
/// `.listRowBackground(.bbCardFill)` per section for the rows.
///
/// The pages *pushed from* Settings — Sync (`LedgerSettingsView`), Categories &
/// Tags, the bundled documents, the debug screens — are still platform-standard.
/// That is the handoff's rule holding where it still applies: only what was
/// designed gets restyled.
extension Color {
    /// The canvas behind the cards. Replaces `Color(.systemGroupedBackground)`.
    static let bbCanvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemGroupedBackground
            : UIColor(red: 0.957, green: 0.945, blue: 0.918, alpha: 1)   // #F4F1EA
    })

    /// The card fill. Replaces `Color(.secondarySystemGroupedBackground)`.
    static let bbCardFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .secondarySystemGroupedBackground
            : UIColor(red: 0.988, green: 0.984, blue: 0.973, alpha: 1)   // #FCFBF8
    })

    /// Warm near-black — the primary label on the redesigned surfaces.
    static let bbInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .label
            : UIColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 1)   // #1A1815
    })

    /// Secondary text. **68% ink is the floor for anything under 18pt** — it
    /// clears 4.5:1 on the card, and the lighter values the design tried first
    /// did not. Don't reach for `bbInkTertiary` to quieten a label.
    static let bbInkSecondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .secondaryLabel
            : UIColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 0.68)
    })

    /// **Non-text only** — rules, chevrons, bar fills. It does not clear
    /// contrast for body copy at any size, which is the whole reason the
    /// secondary token above stops at 68%.
    static let bbInkTertiary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .tertiaryLabel
            : UIColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 0.45)
    })

    /// Row and card dividers — a hair, not a `Divider()`.
    static let bbHairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .separator
            : UIColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 0.09)
    })
}

extension Color {
    /// The floor a trend line is read against. The design names
    /// `rgba(60,60,67,0.14)`, which is what `.separator` resolves to in light
    /// mode — taken as the system colour rather than the literal so the charts
    /// don't turn invisible in dark, which is out of scope for this pass but
    /// still shipping.
    static let bbChartBaseline = Color(.separator)
    /// The dashed mean line, a step quieter than the baseline.
    static let bbChartMean = Color(.separator).opacity(0.7)

    /// The scan-result impact chip: "this is what the scan did to your month".
    ///
    /// Green because it is a confirmation, but deliberately **not**
    /// `bbExported`, which means "reached your ledger" and nothing else — a
    /// receipt can land in your month without going anywhere near a ledger.
    static let bbImpactText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.82, blue: 0.52, alpha: 1)
            : UIColor(red: 0.09, green: 0.42, blue: 0.17, alpha: 1)   // #166B2C
    })
    static let bbImpactSoft = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.14, green: 0.54, blue: 0.24, alpha: 0.22)
            : UIColor(red: 0.14, green: 0.54, blue: 0.24, alpha: 0.10)
    })
}

/// Mono for numbers and labels-about-numbers; proportional for prose.
///
/// That is the whole rule, and the exception proves it: an earlier round of the
/// redesign set the row *labels* in mono too, which both slowed reading and
/// overflowed rows that fit before. So SF Mono carries the money, the counts,
/// and the micro-labels that name a figure ("WEEKLY SPEND", "Aug 1–21"), and SF
/// Pro carries everything a person reads as a sentence.
///
/// SF Mono is tabular by construction, so a column of these lines up without
/// `monospacedDigit()`.
extension Font {
    static func bbMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The micro-label above a figure: mono, uppercase, letter-spaced.
///
/// Tracking is in **points**, not em — SwiftUI's `.tracking` is absolute, and
/// the design's `0.13em` at 11pt is 1.43pt. Passing `0.13` would be a
/// hairline's worth of spacing and look like a plain small label.
struct BBEyebrow: ViewModifier {
    var size: CGFloat = 11

    func body(content: Content) -> some View {
        content
            .font(.bbMono(size, .medium))
            .textCase(.uppercase)
            .tracking(size * 0.13)
            .foregroundStyle(Color.bbInkSecondary)
    }
}

extension View {
    func bbEyebrow(size: CGFloat = 11) -> some View { modifier(BBEyebrow(size: size)) }
}

/// One receipt's export state as a single glyph — filled green for filed, a
/// hollow amber ring for a backlog.
///
/// A ring rather than a second fill for `.notExported`: the two states have to
/// be tellable apart at 9pt *and* by someone who can't separate the hues, so
/// they differ in shape first and colour second.
struct ExportStatusDot: View {
    let status: SpendRecord.ExportStatus
    var size: CGFloat = 9

    var body: some View {
        Group {
            switch status {
            case .exported:
                Circle().fill(Color.bbExported)
            case .notExported:
                Circle().strokeBorder(Color.bbUnexported, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.label)
    }
}

/// The quiet tier: actions that are valid and safe to try, but that we don't
/// want to advertise — Settings, More. Sits below the brand buttons (solid
/// `bbAccent` → soft `bbAccentSoft`) and above nothing.
///
/// Outlined rather than filled. Two reasons, both load-bearing:
///
/// 1. It can't read as disabled. iOS renders a disabled button as a *washed-out
///    fill*, so a crisp border plus a full-strength label is a combination the
///    platform never uses for "you can't tap this". Tinting fill *and* label
///    `.secondary` — the thing this replaces — is pixel-for-pixel the disabled
///    look, which is why those buttons read as broken.
/// 2. It keeps the pill rhythm. On the home screen these sit in a stack of
///    capsules; bare text would break the composition and push Settings further
///    down than it deserves. An outline weighs less than a fill without leaving
///    the family.
///
/// The label stays `.primary` deliberately: dimming it is how a *borderless*
/// button renders its disabled state, so a grey label would reintroduce the
/// exact problem the outline is here to solve. `.primary` also flips with the
/// colour scheme — a literal dark grey would be invisible in dark mode.
///
/// Apply via `.buttonStyle(BBQuietButtonStyle())`. The look lives in a
/// ViewModifier so it can also be reached directly as `.bbQuietButton()` on a
/// bare label, but prefer the ButtonStyle — it carries the pressed state.
struct BBQuietButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// `BBQuietButton` as a ButtonStyle, so the press reads as a press. Dimming the
/// whole pill (border included) is the feedback — the quiet tier has no fill to
/// darken the way the brand buttons do.
struct BBQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bbQuietButton()
            .opacity(configuration.isPressed ? 0.45 : 1)
    }
}

/// Card container: warm paper, 20pt continuous corners, one soft shadow.
///
/// `padding` is a parameter because the redesign has rows that must reach the
/// card's edge — a divider inset 16pt from the leading edge only, and a
/// full-bleed rule above a "Show all 14 items" control. Those cards pass
/// `padding: 0` and pad their own rows. Everything else takes the default and
/// looks exactly as it did.
struct BBCard: ViewModifier {
    var padding: CGFloat = 16
    /// Which corners are rounded. The header slip rounds only its top two: a
    /// torn edge is drawn immediately below it and the two have to read as one
    /// piece of paper.
    var corners: RectangleCornerRadii = .init(topLeading: 20, bottomLeading: 20,
                                              bottomTrailing: 20, topTrailing: 20)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.bbCardFill,
                        in: UnevenRoundedRectangle(cornerRadii: corners, style: .continuous))
            .shadow(color: Color.bbCardShadow, radius: 6, y: 4)
    }
}

/// One shadow, defined once, because the torn edge has to carry the *same* one
/// — a strip with its own shadow reads as a second sheet of paper lying under
/// the first.
extension Color {
    static let bbCardShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.30)
            : UIColor(red: 0.102, green: 0.094, blue: 0.082, alpha: 0.07)
    })
}

extension View {
    func bbCard(padding: CGFloat = 16) -> some View { modifier(BBCard(padding: padding)) }

    /// A card rounded on its top corners only — the header slip, which a torn
    /// edge continues.
    func bbSlipCard(padding: CGFloat = 16) -> some View {
        modifier(BBCard(padding: padding,
                        corners: .init(topLeading: 20, bottomLeading: 0,
                                       bottomTrailing: 0, topTrailing: 20)))
    }

    /// The quiet-tier look on a bare view. For an actual control reach for
    /// `.buttonStyle(BBQuietButtonStyle())` instead — same look, plus the press.
    func bbQuietButton() -> some View { modifier(BBQuietButton()) }
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
        /// Most specific tag's authored label (e.g. "Chicken"). No tags → nil.
        let primary: String?
        /// The remaining (broader) labels, least specific first.
        let rest: [String]
    }

    static func tagDisplay(for tags: [ItemTag]) -> TagDisplay {
        let cleaned = tags.filter { !$0.display.isEmpty }
        guard let last = cleaned.last else {
            return TagDisplay(primary: nil, rest: [])
        }
        // `display` is authored in the core's tag vocabulary, so it is used
        // verbatim. This used to capitalize the raw tag, which is why
        // `energy_drink` reached the card as "Energy_drink".
        let rest = cleaned.dropLast().map { $0.display }
        return TagDisplay(primary: last.display, rest: rest)
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

/// Whether money figures are shown or masked on the glanceable surfaces — the
/// home card and the spending screens.
///
/// Exists because the home screen states a month's total, in full, on launch,
/// before any authentication: anyone glancing at the phone reads it. That sits
/// badly against an app whose pitch is that your spending is nobody's business,
/// so this makes the promise something the UI actually does rather than only
/// says.
///
/// **One piece of state**, deliberately. An earlier version had a persisted
/// preference plus a session-only "reveal", so that putting the phone down
/// re-armed the mask. It read as a bug: tapping the eye on the home card showed
/// the figures while Settings still said "Hide amounts" was on. Two controls
/// over what looks like one thing have to agree, and the honest way to make them
/// agree is for there to be only one thing — so the eye *is* the setting.
///
/// **On by default**, for the same reason: not showing a number that turns out
/// to matter is a far cheaper mistake than having already shown it to the room,
/// and one tap of the eye undoes it.
@MainActor
@Observable
final class AmountPrivacy {
    static let shared = AmountPrivacy()
    static let hideKey = "hideAmounts"

    /// What a masked figure reads as. Same `$` the rest of the app hardcodes
    /// (see `PriceFormat`), so a masked column still lines up with an unmasked
    /// one.
    static let placeholder = "$•••"

    /// The one piece of state, and what both the eye and the Settings toggle
    /// write. Written through to `UserDefaults` on change rather than read at
    /// compute time, so this type stays the single source of truth and Settings
    /// can bind straight to it.
    var hideAmounts: Bool {
        didSet { UserDefaults.standard.set(hideAmounts, forKey: Self.hideKey) }
    }

    /// `-showAmounts`: forces real figures for a run that needs them — App Store
    /// screenshots and demos, which would otherwise capture a wall of `$•••`
    /// now that masking is the default. Not `#if DEBUG`, so a Release build can
    /// be screenshotted. Overrides the preference without writing it, so a
    /// capture run can't leave the setting changed behind it.
    private let forcedVisible: Bool

    private init() {
        // `bool(forKey:)` reads false for an unset key, so the on-by-default
        // preference has to be registered rather than assumed.
        UserDefaults.standard.register(defaults: [Self.hideKey: true])
        hideAmounts = UserDefaults.standard.bool(forKey: Self.hideKey)
        forcedVisible = ProcessInfo.processInfo.arguments.contains("-showAmounts")
    }

    var isMasked: Bool { hideAmounts && !forcedVisible }

    /// The figure as it should appear. Every money string on a glanceable
    /// surface goes through here, so a screen can't half-mask.
    func text(_ formatted: String) -> String {
        isMasked ? Self.placeholder : formatted
    }

    /// What the eye does, wherever it appears. The same write the Settings
    /// toggle performs, so the two can't disagree.
    func toggle() { hideAmounts.toggle() }
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

    /// The numeric value behind a raw price string, or nil if it isn't
    /// parseable. Shared by `display(_:)` and every other place that needs the
    /// number rather than a formatted string — the budget arithmetic
    /// (`SpendSummary`) and `MoneyManagerExport.amountString`, so there's one
    /// parse of this loosely-formatted OCR output, not three.
    static func value(_ raw: String) -> Double? {
        Double(raw.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    /// A computed amount as "$X.XX" — the summing side of the app (spending
    /// totals, category rows, the home card) rather than the raw-string side
    /// `display(_:)` handles. Single currency: `$` is hardcoded app-wide today,
    /// same as `display`; reconciling that with `LedgerFormatPrefs.currency` is
    /// pre-existing and out of scope here.
    static func currency(_ amount: Double) -> String {
        let sign = amount < 0 ? "-" : ""
        return "\(sign)$" + String(format: "%.2f", abs(amount))
    }

    static func display(_ raw: String) -> Display {
        guard let val = value(raw) else {
            return Display(text: raw, isNegative: false)
        }
        let sign = val < 0 ? "-" : ""
        let text = "\(sign)$" + String(format: "%.2f", abs(val))
        return Display(text: text, isNegative: val < 0)
    }
}
