import Foundation
import os

/// In-memory singleton that holds the user's selected API configuration.
///
/// Loaded once on app launch (or when saved in Onboarding/Settings), this
/// prevents repeated `SecItemCopyMatching` calls that trigger macOS Keychain
/// password prompts on every session stop or synthesis.
@MainActor
final class AppConfiguration: ObservableObject {

    static let shared = AppConfiguration()

    private let logger = Logger(subsystem: AppInfo.identifier, category: "appconfig")

    @Published private(set) var selectedProviderID: String = ""
    @Published private(set) var apiKey: String = ""
    @Published private(set) var isLoaded: Bool = false

    private init() {}

    /// Loads the selected provider and its API key from Keychain ONCE.
    /// Call this on app launch and after saving a key in Onboarding/Settings.
    func load() {
        let defaults = UserDefaults.standard

        // One-time cleanup: delete stale Keychain items from previous ad-hoc signatures.
        // These items have ACLs tied to the old signature and cause password prompts.
        let cleanupKey = "keychain.cleanup.v2"
        if !defaults.bool(forKey: cleanupKey) {
            let stored = KeychainManager.storedProviders()
            for provider in stored {
                KeychainManager.deleteKey(for: provider)
            }
            defaults.set(true, forKey: cleanupKey)
            logger.notice("Cleaned \(stored.count) stale Keychain items from previous signature")
        }

        let providerID = defaults.string(forKey: "settings.preferredProviderID") ?? ""

        if !providerID.isEmpty {
            selectedProviderID = providerID
            // Read from Keychain once
            if let key = KeychainManager.getKey(for: providerID), !key.isEmpty {
                apiKey = key
                logger.notice("Loaded API key for provider: \(providerID, privacy: .public)")
            } else {
                // Fall back to environment variable
                let skill = SkillConfigurationLoader.load().configuration
                if let provider = skill.allProviders().first(where: { $0.id == providerID }),
                   !provider.apiKeyEnvironmentVariable.isEmpty,
                   let envKey = ProcessInfo.processInfo.environment[provider.apiKeyEnvironmentVariable],
                   !envKey.isEmpty {
                    apiKey = envKey
                    logger.notice("Loaded API key from environment for provider: \(providerID, privacy: .public)")
                }
            }
        } else {
            // No preferred provider — try to find one with a stored key
            let stored = KeychainManager.storedProviders()
            if let first = stored.first {
                selectedProviderID = first
                apiKey = KeychainManager.getKey(for: first) ?? ""
                defaults.set(first, forKey: "settings.preferredProviderID")
                logger.notice("Auto-selected provider with stored key: \(first, privacy: .public)")
            }
        }

        isLoaded = true
    }

    /// Updates the cached key (called after saving in Onboarding/Settings).
    func update(providerID: String, key: String) {
        selectedProviderID = providerID
        apiKey = key
        UserDefaults.standard.set(providerID, forKey: "settings.preferredProviderID")
        logger.notice("Updated cached API key for provider: \(providerID, privacy: .public)")
    }

    /// Clears the cached key (called after removing a key).
    func clear() {
        selectedProviderID = ""
        apiKey = ""
        UserDefaults.standard.removeObject(forKey: "settings.preferredProviderID")
    }

    /// Returns the cached API key for the given provider, or empty string.
    func key(for providerID: String) -> String {
        if providerID == selectedProviderID {
            return apiKey
        }
        // Fallback: read from Keychain (should be rare)
        return KeychainManager.getKey(for: providerID) ?? ""
    }
}
