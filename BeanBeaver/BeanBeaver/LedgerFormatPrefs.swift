import Foundation

/// Per-device ledger output settings that aren't tied to any one exporter:
/// the operating currency and the tax account applied to every generated
/// beancount entry. Configured in `SettingsView`, read by the scan pipeline.
///
/// Per the Sync-vs-Settings rule in CLAUDE.md, these are *cross-cutting* output
/// prefs (they shape the beancount every backend emits), so they live in the
/// general Settings page, not the per-exporter Sync page.
enum LedgerFormatPrefs {
    static let currencyKey = "ledgerCurrency"
    static let taxAccountKey = "ledgerTaxAccount"

    /// Fallbacks used when the locale can't offer a currency and the user
    /// hasn't picked one — matches the app's historical Canadian defaults.
    static let defaultCurrency = "CAD"
    static let defaultTaxAccount = "Expenses:Tax:HST"

    /// The device locale's ISO 4217 currency, if it exposes one.
    static var localeCurrency: String? { Locale.current.currency?.identifier }

    /// Effective operating currency: the user's stored choice, else the device
    /// locale's currency, else `defaultCurrency`. Read at scan time so a change
    /// in Settings takes effect on the next scan.
    static var currency: String {
        let stored = UserDefaults.standard.string(forKey: currencyKey)
        if let stored, !stored.isEmpty { return stored }
        return localeCurrency ?? defaultCurrency
    }

    /// Effective tax account: the user's stored choice, else `defaultTaxAccount`.
    static var taxAccount: String {
        let stored = UserDefaults.standard.string(forKey: taxAccountKey)
        if let stored, !stored.isEmpty { return stored }
        return defaultTaxAccount
    }
}
