import Foundation
import os

/// User preferences that are not secrets.
///
/// Keys go in the Keychain; preferences go in `UserDefaults`. Nothing else: a
/// second settings file would be a second source of truth that does not sync
/// with the system's backup and restore.
@MainActor
final class AppSettings: ObservableObject {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "settings")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    /// Writes first-launch defaults, so a fresh install has a working sampling
    /// interval rather than a blank picker.
    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.captureIntervalSeconds: DayPilotConfiguration.captureIntervalSeconds,
            Keys.preferredProviderID: ""
        ])
    }

    private enum Keys {
        static let captureIntervalSeconds = "settings.captureIntervalSeconds"
        static let preferredProviderID = "settings.preferredProviderID"
        static let selectedModelByProvider = "settings.selectedModelByProvider"
    }

    // MARK: - Provider and model

    /// The provider the user chose, or `""` to let DayPilot pick whichever
    /// provider has a key available.
    var preferredProviderID: String {
        get { defaults.string(forKey: Keys.preferredProviderID) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.preferredProviderID)
            objectWillChange.send()
        }
    }

    /// The model chosen per provider. Stored per provider, because switching
    /// provider and inheriting an expensive model you never chose there is how
    /// an unintended request gets paid for.
    private var selectedModelByProvider: [String: String] {
        get { defaults.dictionary(forKey: Keys.selectedModelByProvider) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.selectedModelByProvider) }
    }

    /// The model for a provider: the user's choice, or the configured default.
    func model(for provider: SkillConfiguration.AIProvider) -> String {
        selectedModelByProvider[provider.id] ?? provider.model
    }

    /// Records the model for a provider. An empty string means none is chosen.
    func select(model: String, forProvider id: String) {
        var map = selectedModelByProvider
        map[id] = model
        selectedModelByProvider = map
        objectWillChange.send()
    }

    /// Forgets the model for a provider, used when a custom provider is removed.
    func clearModel(forProvider id: String) {
        var map = selectedModelByProvider
        map.removeValue(forKey: id)
        selectedModelByProvider = map
        objectWillChange.send()
    }

    // MARK: - Perception

    /// Seconds between frame samples, bounded so a bad value cannot either flood
    /// the Neural Engine or silently stop capturing.
    var captureIntervalSeconds: Double {
        get {
            let stored = defaults.double(forKey: Keys.captureIntervalSeconds)
            guard stored > 0 else { return DayPilotConfiguration.captureIntervalSeconds }
            return stored.clamped(to: 5...300)
        }
        set {
            defaults.set(newValue.clamped(to: 5...300), forKey: Keys.captureIntervalSeconds)
            objectWillChange.send()
        }
    }

    /// Restores every preference to its default. Keychain keys are not touched.
    func resetToDefaults() {
        defaults.removeObject(forKey: Keys.captureIntervalSeconds)
        defaults.removeObject(forKey: Keys.preferredProviderID)
        defaults.removeObject(forKey: Keys.selectedModelByProvider)
        registerDefaults()
        objectWillChange.send()
        logger.notice("Preferences restored to their defaults")
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
