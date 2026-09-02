import SwiftUI

/// The App Store pointer, shown on the home screen and in Settings.
///
/// BeanBeaver is released — it has a listing, and that is where updates come
/// from. This exists for the copies that did **not** come from there: a build
/// made from this repo, an old TestFlight install, a phone someone was handed.
/// Those keep working and say nothing about themselves, so whoever is holding
/// one has no way to learn there is a shipping app unless the app says so.
///
/// **One declaration, two screens.** The home card and the Settings row show
/// the same sentence and open the same URL, because a store link copied into
/// two files is a link that will eventually differ between them.
enum ReleaseNotice {
    static let title = "BeanBeaver is on the App Store"
    static let message =
        "This app is already officially released. Use the App Store version to get updates."
    static let linkTitle = "Open in the App Store"
    static let urlString = "https://apps.apple.com/us/app/beanbeaver/id6790981690"

    /// Optional rather than force-unwrapped, the same way `SettingsView`'s
    /// feedback rooms are: a typo'd URL should drop a row, not trap the app.
    static let url = URL(string: urlString)
}

/// The home screen's copy of the notice: a card, in the same paper as every
/// other card on that screen, that opens the listing when tapped.
///
/// It carries the whole sentence rather than a bare link because the card is
/// the *only* place the message appears on that screen — someone who never
/// opens Settings has to be able to read it here and know what to do.
struct ReleaseNoticeCard: View {
    var body: some View {
        if let url = ReleaseNotice.url {
            Link(destination: url) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.bbAccent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ReleaseNotice.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.bbInk)
                        // `fixedSize` on the vertical axis only: without it the
                        // sentence is truncated to one line inside a card that
                        // has the width to wrap it.
                        Text(ReleaseNotice.message)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.bbInkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Text(ReleaseNotice.linkTitle)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.bbAccent)
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .bbCard()
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the App Store listing")
        }
    }
}
