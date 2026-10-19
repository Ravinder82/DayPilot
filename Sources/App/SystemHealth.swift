import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import os

/// One capability probe run during the DayPilot launch health check.
struct SystemCheck: Sendable {

    enum Severity: Sendable {
        case pass
        case warn
        case failure

        /// Glyph used by both the stdout report and unified logging.
        var glyph: String {
            switch self {
            case .pass: "✓"
            case .warn: "⚠"
            case .failure: "✗"
            }
        }
    }

    /// Short capability label, left-aligned in the report column.
    let title: String

    /// One-line evidence for the outcome.
    let detail: String

    let severity: Severity

    /// `true` when the probe gates execution: a failing required probe makes
    /// `--selftest` exit non-zero. Permission probes are advisory because they
    /// resolve at runtime, after the user answers the first TCC prompt.
    let isRequired: Bool
}

/// Stateless, `nonisolated` probes for the capabilities DayPilot depends on.
///
/// Every probe is side-effect free — none of them triggers a TCC prompt — so
/// the health check can be run at any time, or from CI, without changing the
/// machine's privacy state. The result is reportable as a `SystemCheck` array
/// so callers decide how to render it.
enum SystemHealth {

    private static let logger = Logger(subsystem: AppInfo.identifier, category: "health")

    /// `SCShareableContent` needs macOS 12.3; DayPilot's floor is higher, but
    /// the probe is checked against the framework's own floor, not ours.
    private static let screenCaptureKitMajor = 12
    private static let screenCaptureKitMinor = 3

    /// Compiled architecture of this binary.
    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }

    /// `true` for a native Apple Silicon process. An arm64 slice can never be
    /// translated, so this is effectively a compile-time constant guarded by a
    /// runtime check for the x86_64 case.
    private static var isNativeAppleSilicon: Bool {
        architecture == "arm64" && !isTranslatedProcess()
    }

    // MARK: - Probes

    /// Runs every probe in reporting order.
    static func evaluate() async -> [SystemCheck] {
        [
            operatingSystemCheck(),
            architectureCheck(),
            neuralEngineCheck(),
            computeCheck(),
            screenCaptureKitCheck(),
            await screenCapturePermissionCheck(),
            accessibilityPermissionCheck(),
            briefHygieneCheck(),
        ]
    }

    /// Drives a deliberately awful brief through the sanitizer and checks that
    /// emoji, placeholder sections, canned phrases, and invented artifacts are
    /// all stripped — the last line of defence between the model and the
    /// user's desk.
    private static func briefHygieneCheck() -> SystemCheck {
        let dirty = """
        # ⚡ Indie Velocity Debrief — 2026-10-17

        ### 1. 🚀 Shipped Velocity (The Needle Movers)
        - Nothing shipped in this session.

        ### 2. 🧠 The Reality Mirror
        - Let's delve into the blockers. No ephemeral logs were captured in this session.

        ### 3. 🎯 Tomorrow's Zero-Friction Launchpad
        - **Target File:** `DayPilotApp.swift`
        - **Command:** `open DayPilot.xcodeproj`
        """

        let cleaned = BriefSanitizer.sanitize(
            reportMarkdown: dirty,
            payloadCorpus: "{\"session_id\":\"check\",\"note\":\"nothing was on screen\"}",
            date: Date(timeIntervalSince1970: 0)
        )

        let lowered = cleaned.lowercased()
        let headings = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#") }
        // "### 1. 🚀 Shipped Velocity (The Needle Movers)" — stage number, icon
        // and nickname. The editor's pass strips all three; this fails if any
        // comes back.
        let decoratedHeading = headings.contains { heading in
            let body = heading.drop(while: { $0 == "#" || $0 == " " })
            return body.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) != nil
                || body.hasSuffix(")")
        }

        let failures = [
            cleaned.contains("⚡") || cleaned.contains("🚀") || cleaned.contains("🧠") || cleaned.contains("🎯"),
            decoratedHeading,
            lowered.contains("nothing shipped"),
            lowered.contains("delve"),
            lowered.contains("no ephemeral logs"),
            lowered.contains("daypilotapp.swift"),
            lowered.contains("xcodeproj"),
            !cleaned.hasPrefix("# Day Brief — "),
        ]
        let passed = !failures.contains(true)

        return SystemCheck(
            title: "Brief hygiene",
            detail: passed
                ? "emoji, stage decoration, placeholder sections, canned phrases and fabricated artifacts never reach a report"
                : "the sanitizer failed a synthetic slop case",
            severity: passed ? .pass : .failure,
            isRequired: true
        )
    }

    private static func operatingSystemCheck() -> SystemCheck {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let satisfied = version.majorVersion >= AppInfo.minimumOSMajor

        return SystemCheck(
            title: "macOS \(version.majorVersion).\(version.minorVersion) (\(marketingName(major: version.majorVersion)))",
            detail: satisfied
                ? "meets the \(AppInfo.minimumOSVersion) deployment floor"
                : "DayPilot requires macOS \(AppInfo.minimumOSVersion) or later",
            severity: satisfied ? .pass : .failure,
            isRequired: true
        )
    }

    private static func architectureCheck() -> SystemCheck {
        SystemCheck(
            title: "Architecture: \(architecture)",
            detail: isNativeAppleSilicon
                ? "native Apple Silicon process"
                : "rebuild for arm64 — Rosetta cannot drive the Neural Engine",
            severity: isNativeAppleSilicon ? .pass : .failure,
            isRequired: true
        )
    }

    private static func neuralEngineCheck() -> SystemCheck {
        SystemCheck(
            title: "Apple Neural Engine",
            detail: isNativeAppleSilicon
                ? "VNRecognizeTextRequest executes on the ANE, CPU stays free"
                : "on-device OCR needs an Apple Silicon Mac",
            severity: isNativeAppleSilicon ? .pass : .failure,
            isRequired: true
        )
    }

    private static func computeCheck() -> SystemCheck {
        let process = ProcessInfo.processInfo
        let gigabytes = Double(process.physicalMemory) / 1_073_741_824

        return SystemCheck(
            title: "Compute",
            detail: "\(format(gigabytes)) GB unified memory, \(process.activeProcessorCount) cores",
            severity: gigabytes >= 8 ? .pass : .warn,
            isRequired: true
        )
    }

    private static func screenCaptureKitCheck() -> SystemCheck {
        let available = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(
                majorVersion: screenCaptureKitMajor,
                minorVersion: screenCaptureKitMinor,
                patchVersion: 0
            )
        )

        return SystemCheck(
            title: "ScreenCaptureKit",
            detail: available
                ? "SCShareableContent ready for the 15s sampling loop"
                : "ScreenCaptureKit requires macOS 12.3 or later",
            severity: available ? .pass : .failure,
            isRequired: true
        )
    }

    private static func screenCapturePermissionCheck() async -> SystemCheck {
        // Use a live probe instead of CGPreflightScreenCaptureAccess(), which
        // can return stale false values after a rebuild with a new signature.
        let granted: Bool
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            granted = !content.displays.isEmpty
        } catch {
            granted = false
        }

        return SystemCheck(
            title: "Screen capture permission",
            detail: granted
                ? "TCC granted — frame sampling cleared"
                : "grant it in System Settings › Privacy & Security › Screen Recording",
            severity: granted ? .pass : .warn,
            isRequired: false
        )
    }

    private static func accessibilityPermissionCheck() -> SystemCheck {
        // AXIsProcessTrusted() reports the prompt-time trust flag without
        // prompting, keeping launch clean.
        let trusted = AXIsProcessTrusted()

        return SystemCheck(
            title: "Accessibility permission",
            detail: trusted
                ? "TCC granted — window titles available"
                : "grant it in System Settings › Privacy & Security › Accessibility",
            severity: trusted ? .pass : .warn,
            isRequired: false
        )
    }

    // MARK: - Reporting

    /// Emits every probe through unified logging so results stay visible in
    /// Console.app even when DayPilot runs from its `.app` bundle, where
    /// stdout is discarded.
    ///
    /// Level mapping is deliberate: on this platform `Logger.warning` is
    /// `OSLogType.error`, so an advisory must not use it or every pending
    /// permission would land in the error channel. `notice` (default level)
    /// is visible by default without implying a fault; `error`/`fault` stay
    /// reserved for real breakage.
    static func log(_ checks: [SystemCheck]) {
        for check in checks {
            let message = "\(check.severity.glyph) \(check.title): \(check.detail)"
            switch check.severity {
            case .pass: logger.info("\(message, privacy: .public)")
            case .warn: logger.notice("\(message, privacy: .public)")
            case .failure: logger.error("\(message, privacy: .public)")
            }
        }
        logger.notice("\(summary(checks), privacy: .public)")
    }

    /// Renders the stdout block used by `--selftest`.
    static func formatReport(_ checks: [SystemCheck], version: String) -> String {
        let rule = String(repeating: "─", count: 78)
        let titleWidth = 32
        var lines = ["\(AppInfo.name) \(version) · system health check", rule]

        for check in checks {
            let title = check.title.padding(toLength: titleWidth, withPad: " ", startingAt: 0)
            lines.append("  \(check.severity.glyph)  \(title)\(check.detail)")
        }

        lines.append(rule)
        lines.append("  \(summary(checks))")
        return lines.joined(separator: "\n")
    }

    /// Full verdict line for the report and the system log.
    static func summary(_ checks: [SystemCheck]) -> String {
        let failures = checks.count { $0.severity == .failure }

        let verdict: String
        if failures > 0 {
            verdict = "blocked — \(failures) required capability missing"
        } else if checks.contains(where: { $0.severity == .warn }) {
            verdict = "operational — permissions pending"
        } else {
            verdict = "fully operational"
        }

        return "\(checks.count) checks · \(passedCount(checks)) passed · \(warnCount(checks)) warnings · \(failures) failures → \(verdict)"
    }

    /// Compact verdict for the status bar menu.
    static func abbreviatedSummary(_ checks: [SystemCheck]) -> String {
        "\(passedCount(checks)) passed · \(warnCount(checks)) warnings · \(failedCount(checks)) failures"
    }

    /// `true` when a probe that gates execution failed.
    static func hasBlockingFailure(_ checks: [SystemCheck]) -> Bool {
        checks.contains { $0.isRequired && $0.severity == .failure }
    }

    // MARK: - Helpers

    private static func passedCount(_ checks: [SystemCheck]) -> Int {
        checks.count { $0.severity == .pass }
    }

    private static func warnCount(_ checks: [SystemCheck]) -> Int {
        checks.count { $0.severity == .warn }
    }

    private static func failedCount(_ checks: [SystemCheck]) -> Int {
        checks.count { $0.severity == .failure }
    }

    private static func marketingName(major: Int) -> String {
        switch major {
        case 14: "Sonoma"
        case 15: "Sequoia"
        case 26: "Tahoe"
        default: "macOS \(major)"
        }
    }

    private static func format(_ gigabytes: Double) -> String {
        gigabytes >= 16
            ? String(format: "%.0f", gigabytes)
            : String(format: "%.1f", gigabytes)
    }

    private static func isTranslatedProcess() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size

        // Non-zero only for an x86_64 process running under Rosetta.
        let status = sysctlbyname("sysctl.prob_translated", &translated, &size, nil, 0)
        return status == 0 && translated == 1
    }
}
