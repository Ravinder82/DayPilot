import Darwin
import Foundation

/// Decides whether a surface is safe to capture at all.
///
/// This runs before any pixel work. Capturing a password manager or a banking
/// tab is not a risk worth taking for a productivity debrief, so the shield is
/// conservative: an unknown-sensitive bundle ID or a matching title pattern
/// drops the frame entirely.
enum SensitiveAppShield {

    static func suppresses(bundleIdentifier: String?, windowTitle: String?, addressBarText: String?) -> Bool {
        // DayPilot never records itself: the menu bar and the smoke-test output
        // are the app talking, not the user working.
        if let bundleIdentifier,
           bundleIdentifier == AppInfo.identifier {
            return true
        }

        if let bundleIdentifier,
           DayPilotConfiguration.sensitiveBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        let candidates = [windowTitle, addressBarText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            for pattern in DayPilotConfiguration.sensitiveURLPatterns
            where globMatch(pattern, candidate) {
                return true
            }
        }
        return false
    }

    /// Package-private so `WindowManager` can explain *why* a frame was
    /// suppressed in the log.
    static func suppressionReason(
        bundleIdentifier: String?,
        windowTitle: String?,
        addressBarText: String?
    ) -> String? {
        if let bundleIdentifier,
           bundleIdentifier == AppInfo.identifier {
            return "DayPilot's own UI"
        }

        if let bundleIdentifier,
           DayPilotConfiguration.sensitiveBundleIdentifiers.contains(bundleIdentifier) {
            return "sensitive bundle ID \(bundleIdentifier)"
        }

        let candidates = [windowTitle, addressBarText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            for pattern in DayPilotConfiguration.sensitiveURLPatterns
            where globMatch(pattern, candidate) {
                return "title/URL matched pattern '\(pattern)'"
            }
        }
        return nil
    }

    /// Matches the `*bank*` style globs from the config with `fnmatch(3)`.
    private static func globMatch(_ pattern: String, _ value: String) -> Bool {
        pattern.withCString { patternPointer in
            value.withCString { valuePointer in
                fnmatch(patternPointer, valuePointer, 0) == 0
            }
        }
    }
}

/// Outcome of classifying the active surface.
struct EphemeralClassification: Sendable, Equatable {
    /// `true` when the surface holds transient, harvestable thought.
    let isEphemeral: Bool
    /// `quick_notes`, `cli_scratchpad`, `exploratory`, `browser`, `core_work`.
    let category: String
    /// Host the user is looking at, when the address bar yielded one.
    let host: String?
}

/// Decides whether the active surface is ephemeral work.
///
/// Ephemeral surfaces are where discarded insights live: a note half-written in
/// Stickies, a prompt being tested in AI Studio, an abandoned regex in a
/// terminal. They are flagged per event so the harvester can find them later
/// without re-reading the screen.
enum EphemeralSurfaceClassifier {

    static func classify(bundleIdentifier: String?, addressBarText: String?) -> EphemeralClassification {
        if let bundleIdentifier,
           let target = DayPilotConfiguration.ephemeralTargets
            .first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return EphemeralClassification(isEphemeral: true, category: target.category, host: nil)
        }

        let host = Self.host(from: addressBarText)

        if let host {
            let root = Self.registrableDomain(host)
            if DayPilotConfiguration.exploratoryDomains.contains(root) {
                return EphemeralClassification(isEphemeral: true, category: "exploratory", host: host)
            }
            return EphemeralClassification(isEphemeral: false, category: "browser", host: host)
        }

        if let bundleIdentifier,
           DayPilotConfiguration.coreDevelopmentBundleIdentifiers.contains(bundleIdentifier) {
            return EphemeralClassification(isEphemeral: false, category: "core_work", host: nil)
        }

        return EphemeralClassification(isEphemeral: false, category: "unclassified", host: nil)
    }

    /// Extracts a host from an address bar string.
    ///
    /// Deliberately strict: a title like "Stickies", or an Xcode window title
    /// like "DayPilot.xcodeproj \u2014 SessionCoordinator.swift", must never be
    /// mistaken for a URL, because a false positive files a note app under
    /// browsing and the model then never sees it as a harvested fragment. A
    /// host must be dotted and contain only domain characters.
    ///
    /// Bare input (`x.com/home`) is accepted; a bare word (`Stickies`) is not.
    static func host(from addressBarText: String?) -> String? {
        guard var raw = addressBarText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let hadScheme = raw.contains("://")
        if !hadScheme {
            raw = "https://\(raw)"
        }
        guard let components = URLComponents(string: raw),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // A registrable domain is dotted and contains no whitespace.
        guard host.contains("."),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              !host.hasPrefix("."), !host.hasSuffix(".") else {
            return nil
        }

        // Without a scheme a slash is also required, so a single dotted word is
        // still never promoted to a hostname.
        guard hadScheme || raw.contains("/") else {
            return nil
        }

        return host
    }

    /// `claude.ai`, `aistudio.google.com` and `openrouter.ai` are all matched by
    /// their registrable-domain tail, so `sub.openrouter.ai` matches too.
    private static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host.lowercased() }

        // Two-label suffixes, plus the multi-part public suffixes DayPilot's
        // exploratory domains can actually appear under.
        let twoLabelSuffixes: Set<String> = [
            "co.uk", "com.au", "co.jp", "com.br", "co.in", "com.cn", "co.za", "com.mx"
        ]
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if twoLabelSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }
}
