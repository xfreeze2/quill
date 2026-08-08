import Foundation
import Security

/// Storage for the user's own xAI API key.
///
/// The Keychain rather than preferences, deliberately. A value in UserDefaults
/// lands in a plist under ~/Library/Preferences that any process running as the
/// user can read, and it would be swept up by backups and sync. An API key is a
/// billable credential and has no business sitting there.
///
/// `ThisDeviceOnly` means it is never carried to another machine by iCloud
/// Keychain or restored from a backup onto different hardware, and
/// `WhenUnlocked` keeps it unreadable while the Mac is locked.
enum Keychain {

    private static let service = "com.freeze.quill"
    private static let account = "xai-api-key"

    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        // Replace rather than add: a duplicate item would fail with errSecDuplicateItem.
        remove()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Quill — xAI API key",
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        // Never log the key itself, only whether the write worked.
        Log.write("api key stored: \(status == errSecSuccess)")
        return status == errSecSuccess
    }

    static func load() -> String? {
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
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func remove() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static var hasKey: Bool { load() != nil }

    /// Enough to recognise which key is stored, without revealing it.
    static var redacted: String? {
        guard let key = load() else { return nil }
        guard key.count > 10 else { return "•••" }
        return String(key.prefix(6)) + "…" + String(key.suffix(4))
    }
}
