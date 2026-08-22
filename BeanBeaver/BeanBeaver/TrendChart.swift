import SwiftUI
import BBReceiptKit

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

/// The same six weeks as `TrendChart`, drawn as bars — and what the home card
/// uses now.
///
/// **Bars because the series is six discrete totals.** A line implies you could
/// read a value between two points, and there is nothing between two weekly
/// buckets to read; it also hides the thing most worth seeing, which is that the
/// newest bucket is a *partial* week. A bar that is visibly shorter because the
/// week is three days old reads as three days old. The line version was drawn
/// side by side and rejected — it is option `5b` in the design file.
///
/// Masking applies exactly as it does to the line: a bar's height encodes
/// dollars, so the caller hides the whole chart rather than the figures beside
/// it. `TrendChart.masked(height:)` is the shared placeholder, so toggling the
/// eye can't make the card jump.
struct TrendBars: View {
    /// Oldest first. The last is the week containing today.
    let amounts: [Double]
    /// One label per bar, under it. Empty strings draw nothing.
    var labels: [String] = []
    var height: CGFloat = 62

    /// Bars are read against each other, not against zero-that-is-off-screen,
    /// so the tallest fills the frame. A series of identical weeks therefore
    /// draws six full-height bars, which is the honest picture: they *are* the
    /// same.
    private var scale: Double {
        max(amounts.max() ?? 0, 0.01)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(Array(amounts.enumerated()), id: \.offset) { index, amount in
                    let isCurrent = index == amounts.count - 1
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isCurrent ? Color.bbAccent : Color.bbInk.opacity(0.16))
                        // A floor of 2pt, so a week with nothing in it draws a
                        // seat rather than a gap. An absent bar reads as missing
                        // data; a flat one reads as a quiet week, which is what
                        // it is.
                        .frame(height: max(height * CGFloat(amount / scale), 2))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)

            if !labels.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        Text(label)
                            .font(.bbMono(10.5))
                            .foregroundStyle(index == labels.count - 1
                                             ? Color.bbAccent : Color.bbInkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Weekly spending, six weeks")
    }
}

/// How the weekly series reads — the axis labels and the delta sentence.
///
/// **Here rather than on each screen** because Home and Spending both draw this
/// series, and the two must not be able to word the same buckets differently.
/// They already did once: one said `↑ $225.06` and the other `+$225.06 vs last
/// wk` for the same number.
extension SpendTrend {
    /// The six week-start dates, with the newest reading `now`.
    ///
    /// `now` rather than a date because the last bucket is the week *containing*
    /// today: labelling it with its start date invites reading the bar as a
    /// finished week, which is exactly the misreading bars are here to avoid.
    var weekLabels: [String] {
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return points.enumerated().map { index, point in
            if index == points.count - 1 { return "now" }
            var c = DateComponents()
            c.year = Int(point.range.start.year)
            c.month = Int(point.range.start.month)
            c.day = Int(point.range.start.day)
            guard let date = Calendar.current.date(from: c) else { return "" }
            return date.formatted(format)
        }
    }

    /// The week-over-week delta, signed and masked.
    ///
    /// A `+`/`−` rather than an arrow: the figure sits inches from a chart whose
    /// bars already point, and two directional signals disagree in a way a sign
    /// cannot. The crate rounds to cents, so "no change" is an exact test rather
    /// than an epsilon — and it gets words, because `+$0.00` is what an
    /// unrounded float would have rendered forever.
    @MainActor
    var deltaText: String {
        if isFlat { return "No change" }
        let sign = delta > 0 ? "+" : "−"
        let figure = AmountPrivacy.shared.text(PriceFormat.currency(abs(delta)))
        return "\(sign)\(figure) vs last wk"
    }
}

/// The delta figure as both screens draw it: accent when there is a change,
/// quiet when there isn't.
///
/// A view rather than a string so the colour rule travels with the wording. It
/// also carries the shrink-to-fit, which is load-bearing: `+$1,225.06 vs last
/// wk` beside a mono eyebrow overruns the card, and it did.
struct TrendDeltaLabel: View {
    let trend: SpendTrend

    var body: some View {
        Text(trend.deltaText)
            .font(.bbMono(13, .semibold))
            .foregroundStyle(trend.isFlat ? Color.bbInkSecondary : Color.bbAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // Wins the space contest against the eyebrow beside it: the eyebrow
            // is a fixed label anyone can guess, the figure is the news.
            .layoutPriority(1)
    }
}
