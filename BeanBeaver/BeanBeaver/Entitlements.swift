import Foundation
import Observation

/// Single source of truth for whether premium features are unlocked. Every
/// feature gate reads ``shared`` and nothing else knows how the answer is
/// reached, so turning on real monetization is a change to `refresh()` — no
/// call site moves. The Money Manager export is the first gated feature.
///
/// The shape here deliberately mirrors the StoreKit 2 flow it will become:
/// entitlements are *fetched* (async, at launch) rather than read synchronously,
/// and they can flip mid-session — so this is `@Observable` and any view that
/// reads `isPremium` in its `body` re-renders when a purchase lands, without
/// being handed the object. That's the part a plain `static var` can't do, and
/// it's why the seam is a live object rather than a constant.
@MainActor
@Observable
final class Entitlements {
    static let shared = Entitlements()

    /// Whether premium features are unlocked right now.
    ///
    /// Starts unlocked so nothing flashes a lock during the launch fetch. Once
    /// there are real products this should start from the last known value
    /// (persisted) instead, since "unlocked until proven otherwise" stops being
    /// the safe default the moment it's something people pay for.
    private(set) var isPremium = true

    private init() {}

    /// Bring entitlements up to date and keep them there. Called once from the
    /// app's root task; the real implementation never returns, because the
    /// `Transaction.updates` listener has to stay alive for the whole process
    /// to catch purchases that complete outside the app (Ask to Buy approvals,
    /// interrupted purchases, buys made on another device).
    func start() async {
        await refresh()

        // Real implementation, once products exist:
        //
        //     for await update in Transaction.updates {
        //         if let transaction = try? update.payloadValue {
        //             await transaction.finish()
        //             await refresh()
        //         }
        //     }
        //
        // Nothing can change the answer yet, so today this simply returns.
    }

    /// Fetch the current entitlement state.
    ///
    /// ⚠️ STUB — there are no products to buy, so premium is open to everyone
    /// and this only re-asserts that. Replace the body with a scan of
    /// `Transaction.currentEntitlements` for the premium product ID; the async
    /// signature and the assignment to `isPremium` are already what that needs.
    ///
    /// `-lockPremium` forces the locked state on, which is the only way to reach
    /// the paywall UI (`moneyManagerLockedSection`, the 🔒 labels) now that no
    /// user-facing switch exists — without it that code would quietly rot before
    /// there's anything to sell.
    private func refresh() async {
        isPremium = !ProcessInfo.processInfo.arguments.contains("-lockPremium")
    }
}
