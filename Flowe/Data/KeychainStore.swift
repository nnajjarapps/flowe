import Foundation
import Security

/// Minimal Keychain wrapper for small secrets (the stable Apple user id).
/// The Keychain — not UserDefaults — is the correct place for an auth identifier.
enum KeychainStore {
    /// `synchronizable` stores the item in the iCloud Keychain, so it follows the user's Apple ID to
    /// their other devices and survives a reinstall. Used for the messaging key, whose loss would make
    /// past end-to-end-encrypted messages unreadable. A synchronizable and a non-synchronizable item
    /// with the same account are distinct entries, so reads must pass the same flag that wrote them.
    static func set(_ value: String?, for key: String, synchronizable: Bool = false) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        if synchronizable { query[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any }
        SecItemDelete(query as CFDictionary)

        guard let value, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String, synchronizable: Bool = false) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if synchronizable { query[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
