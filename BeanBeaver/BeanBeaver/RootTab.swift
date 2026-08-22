import SwiftUI

/// The three places the tab bar goes.
///
/// **Scan is an action, not a place.** It has a tab item because that is where a
/// thumb goes for the app's main verb, but selecting it opens the camera and
/// leaves you on the tab you were already on — see `ContentView.tabSelection`.
/// So there is no scan screen to restore, and the scan *result* is a
/// full-screen modal over the whole tab bar rather than a fourth destination.
///
/// Spending, Receipts and Import are pushes inside Home. They were pills on the
/// home screen and are rows on it now; giving each a tab would put four
/// equally-weighted destinations in a bar where only one of them is where you
/// start.
enum RootTab: Hashable {
    case home
    case scan
    case settings
}

/// The raised Scan button that sits over the tab bar's middle slot.
///
/// # Why this is drawn rather than configured
///
/// A raised centre action is not something `UITabBar` offers, so it cannot come
/// from the platform however much of the rest of the bar does. What *is* from
/// the platform is everything underneath: the real `TabView` still lays out
/// three slots, draws the bar, handles the safe area, and owns selection and
/// accessibility. This adds one circle on top of the middle slot, and the tab
/// item beneath it stays tappable and does the same thing.
///
/// So the failure mode is mild by construction. If the bar's own metrics move
/// under a future iOS, the circle is mispositioned over a tab item that still
/// works, rather than the navigation being broken.
struct RootTabBarAction: View {
    var action: () -> Void

    /// The design's 52pt circle raised 16pt above the bar.
    private let diameter: CGFloat = 52
    private let lift: CGFloat = 16
    /// Standard tab bar content height, above the home indicator. The circle is
    /// positioned from the bottom safe-area edge, so this is the one number that
    /// depends on the platform's own metrics.
    private let barHeight: CGFloat = 49

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.bbAccent)
                .frame(width: diameter, height: diameter)
                .overlay {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.bbAccent.opacity(0.32), radius: 8, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan a receipt")
        // Bottom-aligned in the TabView, then lifted clear of the bar. The tab
        // item's own label stays visible below the circle, which is what keeps
        // it recognisable as a tab rather than a floating action button.
        .padding(.bottom, 15)
        // The tab item underneath handles taps that miss the circle, so nothing
        // here needs to swallow them.
        .allowsHitTesting(true)
    }
}

/// Layout facts about the tab shell that the screens inside it need.
enum BBLayout {
    /// How far above the bottom edge a screen's content must stop.
    ///
    /// **The tab bar floats over the content rather than shortening it**, so
    /// nothing is inset automatically: a scroll view's last element and a
    /// bottom-pinned footer both land under the glass without this. The figure
    /// covers the bar *and* the raised Scan button above it, which reaches
    /// higher than the bar does and is what a pinned export footer actually
    /// collides with.
    static let tabBarInset: CGFloat = 83
}
