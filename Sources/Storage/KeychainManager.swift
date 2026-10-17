import CSQLite
import Foundation

/// Reads and writes DayPilot's API keys in the macOS Keychain.
///
/// A menu-bar app that stores provider keys in `UserDefaults`, or worse in
/// `~/Library/Application Support/DayPilot` in plaintext, is leaking the user's
/// billing to anything that can read their home directory. The Keychain exists
/// precisely for this, holds the item encrypted at rest, and gates access on
/// this app's code signature — so the item stops being readable if the app is
/// tampered with.
///
/// All methods are `static` and `nonisolated`: the class owns no state, and the
/// Keychain itself provides the serialization, so callers on any thread are safe.
enum KeychainManager {

    /// Every DayPilot key lives under this service.
    static let service = "com.daypilot.apikeys"

    enum KeychainError: LocalizedError {
        case duplicate
        case notFound
        case unexpected(OSStatus)
        case cannotReadValue

        var errorDescription: String? {
            switch self {
            case .duplicate:
                "An item already exists for this provider."
            case .notFound:
                "No key is stored for this provider."
            case .unexpected(let status):
                "The Keychain returned an unhandled status (\(status))."
            case .cannotReadValue:
                "A Keychain item exists but its value could not be read."
            }
        }
    }

    /// Stores or replaces the key for a provider.
    ///
    /// - Parameters:
    ///   - key: The API key. Empty strings are rejected: an empty item would
    ///     silently shadow an environment variable.
    ///   - provider: The provider identifier from the skill config
    ///     (`google_ai_studio`, `openrouter_free`, …), used as the account.
    /// - Returns: `true` when the key is persisted.
    @discardableResult
    static func saveKey(_ key: String, for provider: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "\(provider) API key"
        ]

        // An update of a missing item fails with errSecItemNotFound; a plain add
        // of an existing item fails with errSecDuplicateItem. Only one status
        // pair matters, so a two-step update-then-add keeps this branch-free and
        // avoids a read-then-write race.
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }

        var item: [String: Any] = query
        item.merge(attributes) { current, _ in current }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return true }
        // Raced with another writer, or a delete landed between the two calls.
        // Retrying is safe because the update is idempotent.
        if status == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return false
    }

    /// Returns the stored key for a provider, or `nil` when there is none.
    static func getKey(for provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the stored key for a provider.
    @discardableResult
    static func deleteKey(for provider: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Every provider identifier that currently has a stored key.
    static func storedProviders() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]] else {
            return []
        }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Removes every DayPilot key. Used by "Clear stored keys" in Settings.
    @discardableResult
    static func deleteAll() -> Int {
        let stored = storedProviders()
        for provider in stored {
            deleteKey(for: provider)
        }
        return stored.count
    }
}
