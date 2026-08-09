import SwiftUI
import BBReceiptKit

/// How loudly this app reports a parser finding.
///
/// The core reports *what* it found and says nothing about what it's worth —
/// `ReceiptWarningKind` deliberately carries no severity, because the ledger
/// formatter, the matcher and this app all rank the same finding differently.
/// This file is where the phone answers the question, and it should stay the
/// only place that does: no view should re-derive severity from a kind, and
/// nothing anywhere should read `message` to work out what happened.
enum WarningSeverity: Int, Comparable {
    /// True, recorded, and not worth a word of the user's attention. The card
    /// may already be showing it by other means.
    case info
    /// Worth reading before filing, not worth flagging the whole receipt over.
    case notice
    /// The numbers are wrong or incomplete — the receipt gets a badge.
    case attention

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Colors are attached here rather than at each call site so "orange means
    /// notice" can't drift between the banner and any future list.
    var tint: Color {
        switch self {
        case .attention: return .bbAccent
        case .notice: return .orange
        case .info: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .attention: return "exclamationmark.circle.fill"
        case .notice: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }
}

extension ReceiptWarningKind {
    var severity: WarningSeverity {
        switch self {
        // The transaction doesn't add up. Nothing else here is as bad, and
        // both of these mean a posting is missing or duplicated.
        case .totalMismatch, .subtotalMismatch:
            return .attention

        // Something was probably lost — a price with no description, or a line
        // thrown away for being implausible. Worth showing; not proof of a
        // defect, since receipts print stray amounts that are not items.
        case .possibleMissedItem, .droppedImplausiblePrice:
            return .notice

        // The payment block and the TOTAL row disagree, so one of the two is
        // definitely misread — worth a look before filing. Not `.attention`
        // though: the core cannot tell which side is wrong from the arithmetic
        // alone, so it repairs nothing and the formatter falls back to a single
        // payment posting. The entry still balances; what is unreliable is the
        // breakdown of *how* it was paid.
        case .tenderMismatch:
            return .notice

        // The parser repaired a mangled price and reconciled it against the
        // summary. Nothing to do — the note exists so the repair is auditable.
        case .priceAutoCorrected:
            return .info

        // An item matched no rule. Normal on any real receipt (166 of them
        // across the 124-receipt corpus), and the item row already says
        // "Uncategorized" in place of its tags — so it must never badge. This
        // is the whole reason kinds exist: as an untyped warning it made two
        // receipts in three look broken.
        case .uncategorizedItem:
            return .info

        // Kinds are additive: a core release may introduce one this build has
        // never heard of. Degrade to "show it quietly" rather than crash or
        // silently swallow it.
        @unknown default:
            return .notice
        }
    }
}

extension ReceiptWarning {
    var severity: WarningSeverity { kind.severity }
}

extension Array where Element == ReceiptWarning {
    /// The findings worth showing in the result card.
    var worthShowing: [ReceiptWarning] {
        filter { $0.severity >= .notice }
    }

    var highestSeverity: WarningSeverity? {
        map(\.severity).max()
    }
}
