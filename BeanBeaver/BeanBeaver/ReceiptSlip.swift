import SwiftUI

/// The block at the top of Home and Spending: a card rounded on its top corners
/// only, with a torn paper edge along the bottom.
///
/// **One torn edge per screen, and this is it.** The receipt idea is carried by
/// the palette and by the mono figures; the tear is the single literal gesture,
/// and it earns its place only by being rare. A second one on a list card would
/// make both read as decoration. Earlier rounds put tears on every card and dot
/// leaders in every row — see the handoff's turn 2 — and the version that
/// shipped is the one that spends the effect once.
///
/// It also solves the complaint that started this: Home's month card used to sit
/// below a large blank band under the nav bar. This starts at the top of the
/// content area, so the first thing on the screen is the number the app exists
/// to produce.
struct ReceiptSlip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .bbSlipCard(padding: 0)

            TornEdge()
                .fill(Color.bbCardFill)
                .frame(height: TornEdge.height)
                .shadow(color: Color.bbCardShadow, radius: 6, y: 4)
        }
    }
}

/// The sawtooth strip under the slip: teeth pointing down, a straight top.
///
/// Drawn as one `Path` rather than a repeating image or a stack of triangles so
/// the shadow follows the actual outline. That is the difference between a torn
/// edge and a strip of paper lying beneath the card — with a rectangular
/// shadow the illusion collapses immediately.
///
/// The top edge is deliberately straight and butted against the card with zero
/// spacing: the seam has to be invisible, and any gap at all turns one sheet
/// into two.
struct TornEdge: Shape {
    /// Tall enough to read as torn at a glance, short enough not to become a
    /// design element in its own right.
    static let height: CGFloat = 11
    /// Distance between tooth tips. Wider teeth read as a pinking shear, much
    /// narrower ones vanish into a rough line at this height.
    static let pitch: CGFloat = 15

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Runs past the trailing edge on purpose. A partial tooth at the end is
        // what a real tear looks like; stopping at the last whole one leaves a
        // flat run in the corner that reads as a mistake. The shape is clipped
        // by its frame.
        var x = rect.minX
        while x < rect.maxX {
            path.addLine(to: CGPoint(x: x + Self.pitch / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + Self.pitch, y: rect.minY))
            x += Self.pitch
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The eye that masks every money figure on the screen it sits on.
///
/// Its own view because Home and Spending both carry one and they must be the
/// same control — same glyph, same 44pt target, same single piece of state. The
/// Settings toggle writes that state too; three places, one value.
///
/// Always present, never only-while-masked: it is a toggle, so hiding it after
/// a reveal would strand someone with no way back short of Settings.
struct AmountPrivacyEye: View {
    @State private var privacy = AmountPrivacy.shared
    var size: CGFloat = 20

    var body: some View {
        Button {
            privacy.toggle()
        } label: {
            Image(systemName: privacy.hideAmounts ? "eye" : "eye.slash")
                .font(.system(size: size))
                .foregroundStyle(Color.bbInkSecondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(privacy.hideAmounts ? "Show amounts" : "Hide amounts")
    }
}

/// A money figure at display size: mono, tight, with the cents stepped back.
///
/// The cents are drawn at 40% opacity rather than smaller. Shrinking them is the
/// other common treatment and it costs the alignment — a column of totals stops
/// lining up the moment two of them have differently-sized tails. Opacity keeps
/// the metrics and still says "the dollars are the number".
///
/// Masked figures render whole: `$•••` has no cents to step back, and splitting
/// on a decimal point that isn't there would silently dim the last three
/// characters of the placeholder.
struct DisplayAmount: View {
    let amount: Double
    var size: CGFloat = 46
    /// The design's −2 at 46pt, −1 at smaller display sizes.
    var tracking: CGFloat = -2

    @State private var privacy = AmountPrivacy.shared

    var body: some View {
        let text = privacy.text(PriceFormat.currency(amount))
        Group {
            if let dot = text.lastIndex(of: "."), !privacy.isMasked {
                Text(text[text.startIndex..<dot])
                    + Text(text[dot...]).foregroundColor(Color.bbInk.opacity(0.4))
            } else {
                Text(text)
            }
        }
        .font(.bbMono(size, .semibold))
        .tracking(tracking)
        .foregroundStyle(Color.bbInk)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}
