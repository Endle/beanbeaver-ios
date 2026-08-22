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
/// works, rather than the navigation being broken. **Dropping the compatibility
/// flag is exactly that kind of move** — iOS 26's own bar is a floating capsule
/// inset from the edges, and this offset does not fit it.
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
        // Bottom-aligned in the TabView, then lifted so roughly a third of the
        // circle clears the bar's top edge. The tab item's own label stays
        // visible below it, which is what keeps this recognisable as a tab
        // rather than a floating action button.
        //
        // Measured against the flat bar the compatibility flag restores: the
        // circle sits 15pt proud of a 49pt bar, against the design's 16pt.
        .padding(.bottom, 15)
        // The tab item underneath handles taps that miss the circle, so nothing
        // here needs to swallow them.
        .allowsHitTesting(true)
    }
}

/// Layout facts about the tab shell that the screens inside it need.
enum BBLayout {
    /// Extra bottom clearance for content inside the Home tab.
    ///
    /// **Only the raised button needs clearing, not the bar.** The bar is an
    /// ordinary opaque tab bar (see `TabBarAppearance` and the compatibility
    /// flag), so it is part of the safe area and every screen already stops
    /// above it — the platform does that. What the platform knows nothing about
    /// is `RootTabBarAction`, which is drawn *over* the bar and reaches ~15pt
    /// past its top edge. Without this a pinned export footer sits neatly on the
    /// bar and is then covered by the red circle.
    ///
    /// This was 83pt while the app rendered with iOS 26's floating glass bar,
    /// which is **not** in the safe area and covers whatever is beneath it. If
    /// the compatibility flag is ever dropped, this has to go back up — see the
    /// CLAUDE.md section on the flag.
    static let scanButtonClearance: CGFloat = 24
}

/// Paints the tab bar in the receipt palette.
///
/// # This only works because of `UIDesignRequiresCompatibility`
///
/// Under iOS 26's own design language the tab bar is a floating glass capsule
/// and **every one of these settings is silently ignored** — verified by
/// screenshot, not by reading docs: an opaque cream background, a custom shadow
/// colour and `unselectedItemTintColor` all produced a pixel-identical bar. The
/// compatibility flag restores the flat full-width bar *and* restores the
/// appearance proxy's authority over it. The two are a pair: the flag alone
/// gives a correctly-shaped bar with no fill at all, sitting transparent over
/// the canvas with nothing separating it from the content.
///
/// So if the flag ever goes away, this stops having any effect at the same
/// moment — it does not become wrong, it becomes inert. Which is the good
/// failure mode, but it does mean this file cannot be used to check whether the
/// flag is still doing anything.
enum TabBarAppearance {
    static func apply() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        // Card, not canvas: the bar reads as a surface laid over the page, the
        // same way every card on the screen does.
        appearance.backgroundColor = UIColor(Color.bbCardFill)
        appearance.shadowColor = UIColor(Color.bbHairline)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
