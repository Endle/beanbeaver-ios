import Foundation
import Security

/// Minimal wrapper over a `kSecClassGenericPassword` item, used to store the
/// GitHub access token off `UserDefaults` (which is world-readable in backups).
/// Values are namespaced by `account` under this app's service identifier.
enum Keychain {
    private static let service = "com.beanbeaver.BeanBeaver.tokens"

    /// Store (or replace) a secret. Passing `nil`/empty removes it.
    static func set(_ value: String?, for account: String) {
        remove(account)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    struct Item {
        let account: String
        let byteCount: Int
    }

    /// Every item stored under this app's Keychain service — for the data-dump
    /// debug screen. Never returns the secret itself, only its account name and
    /// size, so the dump can't leak a live token.
    static func allItems() -> [Item] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            let byteCount = (item[kSecValueData as String] as? Data)?.count ?? 0
            return Item(account: account, byteCount: byteCount)
        }
    }
}
