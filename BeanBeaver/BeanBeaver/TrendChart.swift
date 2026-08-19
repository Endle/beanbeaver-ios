import SwiftUI

/// The weekly spend line — a sparkline, not a chart.
///
/// Hand-drawn rather than built on Swift Charts because there are no axes, no
/// gridlines, no legend and no interaction: the whole thing is one polyline, a
/// baseline, and a dot on the newest point. Swift Charts would contribute a plot
/// area, its own insets and a scale to fight, for a shape that is thirty lines
/// of `Path`.
///
/// # It draws no numbers, and that is the point
///
/// Amount masking is **on by default** (`AmountPrivacy`), and a line whose
/// height encodes dollars leaks the shape of a month even with every figure
/// replaced by `$•••`. So the callers hide this entirely while masked rather
/// than normalising it — see `TrendChart.masked`.
struct TrendChart: View {
    /// Oldest first. Fewer than two points draws nothing — a single dot is not
    /// a trend, and a zero-width line looks like a rendering bug.
    let amounts: [Double]
    var height: CGFloat = 86
    /// The dashed reference line, when the design asks for one. `nil` on home,
    /// where the card is short and the extra line is noise.
    var mean: Double?
    /// Labels under each end of the line. Empty strings draw nothing.
    var leadingLabel: String = ""
    var trailingLabel: String = ""
    /// The `mean` line's own label, centred. Ignored when `mean` is nil.
    var meanLabel: String = ""

    private var range: (min: Double, max: Double) {
        let lo = amounts.min() ?? 0
        let hi = amounts.max() ?? 0
        // A flat series (every week identical, or all zero) would divide by
        // zero. Give it a nominal span so the line lands mid-height instead of
        // collapsing onto the baseline, where it would read as "spent nothing".
        return hi - lo < 0.005 ? (lo - 1, hi + 1) : (lo, hi)
    }

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        let (lo, hi) = range
        // Inset top and bottom by the newest dot's radius so it can't be
        // clipped by the frame when the newest week is the highest or lowest.
        let inset: CGFloat = 5
        let usable = max(size.height - inset * 2, 1)
        let fraction = (amounts[index] - lo) / (hi - lo)
        let x = amounts.count == 1
            ? size.width / 2
            : size.width * CGFloat(index) / CGFloat(amounts.count - 1)
        return CGPoint(x: x, y: inset + usable * (1 - fraction))
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    // Baseline: the floor the line is read against. Without it a
                    // gently falling series and a flat one look alike.
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: size.height))
                        p.addLine(to: CGPoint(x: size.width, y: size.height))
                    }
                    .stroke(Color.bbChartBaseline, lineWidth: 1)

                    if let mean, amounts.count > 1 {
                        let (lo, hi) = range
                        let y = 5 + max(size.height - 10, 1) * (1 - (mean - lo) / (hi - lo))
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        .stroke(Color.bbChartMean,
                                style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    }

                    if amounts.count > 1 {
                        Path { p in
                            p.move(to: point(0, in: size))
                            for index in 1..<amounts.count {
                                p.addLine(to: point(index, in: size))
                            }
                        }
                        .stroke(Color.bbAccent,
                                style: StrokeStyle(lineWidth: 2.2,
                                                   lineCap: .round,
                                                   lineJoin: .round))

                        let last = point(amounts.count - 1, in: size)
                        Circle()
                            .fill(Color.bbAccent)
                            .frame(width: 8, height: 8)
                            .position(last)
                    }
                }
            }
            .frame(height: height)

            if !leadingLabel.isEmpty || !trailingLabel.isEmpty || !meanLabel.isEmpty {
                HStack {
                    Text(leadingLabel)
                    Spacer()
                    if !meanLabel.isEmpty {
                        Text(meanLabel)
                        Spacer()
                    }
                    Text(trailingLabel)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Weekly spending trend")
        // The line encodes amounts; VoiceOver reading them out would defeat the
        // masking the card applies to every figure beside it.
        .accessibilityHidden(false)
    }

    /// What stands in for the chart while amounts are masked.
    ///
    /// A blank of the same height rather than nothing at all, so toggling the
    /// eye doesn't make the card jump — and so the card doesn't look broken in
    /// the default state, which *is* masked.
    static func masked(height: CGFloat = 86) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.bbChartBaseline.opacity(0.35))
            .frame(height: height)
            .overlay {
                Image(systemName: "eye.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement()
            .accessibilityLabel("Spending trend hidden")
    }
}
