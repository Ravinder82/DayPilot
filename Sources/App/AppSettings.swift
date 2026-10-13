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

    /// Writes first-launch defaults, so a fresh install has a working voice and
    /// sampling interval rather than a blank picker.
    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.autoPlayDebrief: true,
            Keys.captureIntervalSeconds: DayPilotConfiguration.captureIntervalSeconds,
            Keys.selectedVoiceIdentifier: "",
            Keys.preferredProviderID: ""
        ])
    }

    private enum Keys {
        static let autoPlayDebrief = "settings.autoPlayDebrief"
        static let captureIntervalSeconds = "settings.captureIntervalSeconds"
        static let selectedVoiceIdentifier = "settings.selectedVoiceIdentifier"
        static let preferredProviderID = "settings.preferredProviderID"
        static let selectedModelByProvider = "settings.selectedModelByProvider"
        // Pomodoro
        static let pomodoroWorkDuration = "settings.pomodoroWorkDuration"
        static let pomodoroShortBreakDuration = "settings.pomodoroShortBreakDuration"
        static let pomodoroLongBreakDuration = "settings.pomodoroLongBreakDuration"
        static let pomodoroCyclesBeforeLongBreak = "settings.pomodoroCyclesBeforeLongBreak"
        static let pomodoroAutoStartBreaks = "settings.pomodoroAutoStartBreaks"
        static let pomodoroAutoStartWork = "settings.pomodoroAutoStartWork"
        static let pomodoroSoundEnabled = "settings.pomodoroSoundEnabled"
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

    // MARK: - Voice

    /// Speak the debrief when a session stops. On by default, because the
    /// spoken briefing is the product.
    var autoPlayDebrief: Bool {
        get { defaults.bool(forKey: Keys.autoPlayDebrief) }
        set {
            defaults.set(newValue, forKey: Keys.autoPlayDebrief)
            objectWillChange.send()
        }
    }

    /// The voice the user picked, or `""` for the automatic choice.
    var selectedVoiceIdentifier: String {
        get { defaults.string(forKey: Keys.selectedVoiceIdentifier) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.selectedVoiceIdentifier)
            objectWillChange.send()
        }
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
        defaults.removeObject(forKey: Keys.autoPlayDebrief)
        defaults.removeObject(forKey: Keys.captureIntervalSeconds)
        defaults.removeObject(forKey: Keys.selectedVoiceIdentifier)
        defaults.removeObject(forKey: Keys.preferredProviderID)
        defaults.removeObject(forKey: Keys.selectedModelByProvider)
        defaults.removeObject(forKey: Keys.pomodoroWorkDuration)
        defaults.removeObject(forKey: Keys.pomodoroShortBreakDuration)
        defaults.removeObject(forKey: Keys.pomodoroLongBreakDuration)
        defaults.removeObject(forKey: Keys.pomodoroCyclesBeforeLongBreak)
        defaults.removeObject(forKey: Keys.pomodoroAutoStartBreaks)
        defaults.removeObject(forKey: Keys.pomodoroAutoStartWork)
        defaults.removeObject(forKey: Keys.pomodoroSoundEnabled)
        registerDefaults()
        objectWillChange.send()
        logger.notice("Preferences restored to their defaults")
    }

    // MARK: - Pomodoro

    /// Work duration in seconds (default 25 minutes).
    var pomodoroWorkDuration: Double {
        get {
            let stored = defaults.double(forKey: Keys.pomodoroWorkDuration)
            return stored > 0 ? stored : 25 * 60
        }
        set {
            defaults.set(newValue.clamped(to: 60...3600), forKey: Keys.pomodoroWorkDuration)
            objectWillChange.send()
        }
    }

    /// Short break duration in seconds (default 5 minutes).
    var pomodoroShortBreakDuration: Double {
        get {
            let stored = defaults.double(forKey: Keys.pomodoroShortBreakDuration)
            return stored > 0 ? stored : 5 * 60
        }
        set {
            defaults.set(newValue.clamped(to: 30...1800), forKey: Keys.pomodoroShortBreakDuration)
            objectWillChange.send()
        }
    }

    /// Long break duration in seconds (default 15 minutes).
    var pomodoroLongBreakDuration: Double {
        get {
            let stored = defaults.double(forKey: Keys.pomodoroLongBreakDuration)
            return stored > 0 ? stored : 15 * 60
        }
        set {
            defaults.set(newValue.clamped(to: 60...3600), forKey: Keys.pomodoroLongBreakDuration)
            objectWillChange.send()
        }
    }

    /// Number of work cycles before a long break (default 4).
    var pomodoroCyclesBeforeLongBreak: Int {
        get {
            let stored = defaults.integer(forKey: Keys.pomodoroCyclesBeforeLongBreak)
            return stored > 0 ? stored : 4
        }
        set {
            let clamped = Swift.max(2, Swift.min(10, newValue))
            defaults.set(clamped, forKey: Keys.pomodoroCyclesBeforeLongBreak)
            objectWillChange.send()
        }
    }

    /// Automatically start breaks when work phase ends.
    var pomodoroAutoStartBreaks: Bool {
        get { defaults.bool(forKey: Keys.pomodoroAutoStartBreaks) }
        set {
            defaults.set(newValue, forKey: Keys.pomodoroAutoStartBreaks)
            objectWillChange.send()
        }
    }

    /// Automatically start next work phase when break ends.
    var pomodoroAutoStartWork: Bool {
        get { defaults.bool(forKey: Keys.pomodoroAutoStartWork) }
        set {
            defaults.set(newValue, forKey: Keys.pomodoroAutoStartWork)
            objectWillChange.send()
        }
    }

    /// Play sound on phase transitions.
    var pomodoroSoundEnabled: Bool {
        get { defaults.object(forKey: Keys.pomodoroSoundEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.pomodoroSoundEnabled)
            objectWillChange.send()
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
