import Foundation
import Security
import os

/// Minimal Keychain wrapper for secrets (cloud API keys) — keeps them out of
/// plaintext preferences/env vars. Items are device-only (never synced to iCloud
/// Keychain), and failures are logged rather than silently ignored.
enum KeychainStore {
    private static let service = "pavi.Forge"
    static let cloudKeyAccount = "cloudAPIKey"
    private static let log = Logger(subsystem: "pavi.Forge", category: "Keychain")

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing item
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Device-only: API keys must NOT sync to iCloud Keychain / other devices.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Keychain set failed for \(account, privacy: .public): OSStatus \(status)")
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Keychain delete failed for \(account, privacy: .public): OSStatus \(status)")
        }
    }
}
