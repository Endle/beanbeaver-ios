import Foundation

/// Single source of truth for whether premium features are unlocked. Every
/// feature gate reads ``isPremium`` and nothing reads the backing store
/// directly, so turning on real monetization later is a change here — no call
/// site moves. The Money Manager export is the first gated feature.
enum Entitlements {
    /// UserDefaults key behind the "Enable premium features" switch (Settings).
    static let premiumEnabledKey = "premiumEnabled"

    /// ⚠️ STUB — replace with the real StoreKit entitlement check before any App
    /// Store release. BeanBeaver is TestFlight-only for now, so there's nothing
    /// to buy: premium is simply a switch the tester controls, defaulting on so
    /// the beta audience has it without hunting for the toggle.
    static var isPremium: Bool {
        UserDefaults.standard.object(forKey: premiumEnabledKey) as? Bool ?? true
    }
}
