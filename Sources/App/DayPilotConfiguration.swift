import Foundation

/// A high-value ephemeral surface: a place where the user works with transient
/// thoughts that would otherwise be lost when the window closes.
struct EphemeralTarget: Sendable, Hashable {
    let bundleIdentifier: String
    let category: String
    let priority: String
}

/// Every runtime knob for DayPilot, in one place.
///
/// Values mirror `.opencode/skills/daypilot-tracker/daypilot-tracker.config.json`,
/// which is the project's declared source of truth. They are compiled in rather
/// than read at runtime because the packaged app must run standalone, without
/// the skill repository present on the machine — and so that a malformed
/// config file can never change capture behaviour at runtime.
enum DayPilotConfiguration {

    // MARK: Capture engine (`capture_engine`)

    /// Seconds between frame samples. Applied as SCK's `minimumFrameInterval`
    /// so the scheduler, not a polling timer, controls cadence.
    static let captureIntervalSeconds: TimeInterval = 2

    /// Resolution of the grayscale grid sampled for the perceptual gate.
    static let thumbnailResolution = 64

    /// A frame whose luminance delta from the previous frame is below this is
    /// dropped before Vision ever runs: the screen is static, or the user is
    /// reading it. 0.03 == "fewer than 3% of luminance units changed".
    static let maximumSignificantFrameDelta = 0.03

    /// `phash_similarity_threshold` from the config, applied as a second-stage
    /// gate: a difference-hash similarity at or above this means the frame is
    /// perceptually identical to the last one (blinking caret, clock, progress
    /// bar), so it is dropped even when raw pixels moved.
    static let perceptualHashSimilarityThreshold = 0.95

    /// Upper bound on stored events per session; the coordinator stops
    /// recording past this instead of letting the database grow unbounded.
    static let maxStoredEventsPerSession = 5000

    // MARK: Pruning (`pruning_rules`)

    /// Seconds of no-screen-change after which a session is considered idle.
    static let idleTimeoutSeconds = 120

    /// Minimum dwell before a surface counts as meaningful work.
    static let minimumMeaningfulDwellSeconds = 30

    // MARK: - Synthesis

    /// Upper bound on events included in a synthesis prompt. A very long day is
    /// compressed to its head and tail rather than truncated from one end,
    /// because the start and the finish of a day say the most about it.
    static let maxPromptEvents = 40

    /// Cap on characters of OCR delta carried per event. One window that scrolls
    /// a long page otherwise swamps the prompt.
    static let maxCharactersPerEvent = 1800

    /// Directory (relative to Application Support) holding archived reports.
    static let reportsDirectoryName = "Reports"

    /// Sessions shorter than this are not worth a synthesis call.
    static let minimumSessionSecondsForSynthesis = 0

    /// Sessions below this length are probes, not workdays: DayPilot skips the
    /// model call and archives a two-line note instead of a padded briefing.
    static let probeSessionSeconds: TimeInterval = 120

    /// A session this short with at most `probeSessionMaxEvents` events had
    /// nothing on screen; it is a probe too.
    static let probeSessionMaxEventsWindow: TimeInterval = 300
    static let probeSessionMaxEvents = 2

    /// Token ceiling sent to the provider for one debrief. One day of pruned
    /// telemetry plus the standing rules sits comfortably under this.
    static let synthesisMaxTokens = 4096

    /// Token ceiling for the Settings connection probe. Deliberately tiny: the
    /// probe proves the key works, so it must not cost real money.
    static let connectionProbeMaxTokens = 5

    // MARK: Policy (`app_filters`)

    /// Screen capture and OCR are suppressed outright while any of these owns
    /// the keyboard focus. Capturing a password manager's window is never
    /// worth the risk, so these are enforced before pixels are touched.
    static var sensitiveBundleIdentifiers: Set<String> {
        // Read from onboarding preferences, fall back to defaults
        if let stored = UserDefaults.standard.array(forKey: "onboarding.sensitiveBundleIDs") as? [String], !stored.isEmpty {
            return Set(stored)
        }
        return [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.apple.keychainaccess",
            "com.apple.MobileSMS",
            "com.apple.FaceTime"
        ]
    }

    /// `fnmatch` glob patterns matched against window titles and the browser
    /// address bar, to catch sensitive surfaces that have no known bundle ID.
    static let sensitiveURLPatterns: [String] = [
        "*bank*",
        "*login*",
        "*auth0*",
        "*accounts.google.com*",
        "*private_token*"
    ]

    /// Surfaces that hold transient, high-value thoughts — the "discarded
    /// insight" harvest targets.
    static let ephemeralTargets: [EphemeralTarget] = [
        .init(bundleIdentifier: "com.apple.Stickies", category: "quick_notes", priority: "high"),
        .init(bundleIdentifier: "com.apple.Notes", category: "personal_notes", priority: "high"),
        .init(bundleIdentifier: "com.apple.TextEdit", category: "scratchpad", priority: "medium"),
        .init(bundleIdentifier: "com.apple.Terminal", category: "cli_scratchpad", priority: "high"),
        .init(bundleIdentifier: "com.googlecode.iterm2", category: "cli_scratchpad", priority: "high")
    ]

    /// Domains where the user is exploring rather than shipping. These still
    /// get flagged as ephemeral because AI chats and threads are exactly where
    /// the harvestable fragments live.
    static let exploratoryDomains: Set<String> = [
        "x.com",
        "twitter.com",
        "aistudio.google.com",
        "claude.ai",
        "chatgpt.com",
        "github.com",
        "openrouter.ai"
    ]

    /// Applications where the user is genuinely shipping code.
    static let coreDevelopmentBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.google.antigravity",
        "dev.opencode.client"
    ]

    // MARK: Storage (`storage_paths`)

    /// `~/Library/Application Support/DayPilot`
    static let memoryDirectoryName = "Library/Application Support/DayPilot"

    static let databaseFileName = "DayPilot.sqlite"
    static let userMemoryFileName = "user_memory.json"
}
