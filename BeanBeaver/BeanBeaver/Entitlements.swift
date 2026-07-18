import Foundation

/// Single source of truth for whether premium features are unlocked. Every
/// feature gate reads ``isPremium`` and nothing reads the backing store
/// directly, so turning monetization on later is a change here — no call site
/// moves. The Money Manager export is the first gated feature: `LedgerExportButtons`
/// and the batch menu simply omit its button when this is false.
///
/// **TestFlight phase (now):** ``premiumRequiresPurchase`` is `false`, so premium
/// is open to every tester while the gate stays wired in and exercised.
///
/// **At publish:** set ``premiumRequiresPurchase`` to `true` and implement the
/// StoreKit entitlement check in ``isPremium``'s release branch. That pair of
/// edits — both in this file — is the entire "turn on monetization" change.
enum Entitlements {
    /// UserDefaults key behind the DEBUG "Enable premium features" toggle
    /// (Settings › Debug). Read only through ``isPremium``.
    static let debugPremiumKey = "debugPremiumEnabled"

    /// Master switch. While `false` (the TestFlight phase) premium is open to
    /// everyone; flip it to `true` at publish to start enforcing the gate.
    static let premiumRequiresPurchase = false

    static var isPremium: Bool {
        #if DEBUG
        // Local dev: the Settings toggle drives the gate, so both the locked and
        // unlocked experiences are testable before launch (default off = locked).
        return UserDefaults.standard.bool(forKey: debugPremiumKey)
        #else
        // TestFlight phase: open to every tester. At publish, flip
        // `premiumRequiresPurchase` and return the StoreKit entitlement here.
        if !premiumRequiresPurchase { return true }
        return false // TODO(publish): StoreKit entitlement active
        #endif
    }
}
