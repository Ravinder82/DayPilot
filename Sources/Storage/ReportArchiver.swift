import Foundation
import os

/// The result of one synthesis call, before it is written to disk.
struct SynthesisOutcome: Sendable, Equatable {
    let reportMarkdown: String
    let voiceScript: String
    let providerLabel: String
    let model: String
    let temperature: Double
    let promptCharacters: Int
    var rulesHarvested: [String]
    /// True when the "report" is DayPilot's own two-line probe note and no
    /// model was called.
    var isProbe: Bool = false
}

/// Writes the finished debrief to disk and folds what it learned back into
/// `user_memory.json`.
///
/// The archive is the durable half of the product: the spoken briefing is
/// transient, but the report and the accumulated rules of thumb are what make
/// DayPilot smarter on day 30 than on day 1. Both halves are written here so
/// that "session ended" always produces a file, even when synthesis failed.
@MainActor
final class ReportArchiver {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "archive")

    private let memoryStore: UserMemoryStore
    private let reportsDirectory: URL

    /// Outcome of writing a report.
    struct ArchiveOutcome: Sendable, Equatable {
        let reportPath: String
        let rulesHarvested: [String]
        let reportBytes: Int
    }

    init(memoryStore: UserMemoryStore, baseDirectory: URL? = nil) {
        self.memoryStore = memoryStore

        let base = baseDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(DayPilotConfiguration.memoryDirectoryName, isDirectory: true)

        reportsDirectory = base
            .appendingPathComponent(DayPilotConfiguration.reportsDirectoryName, isDirectory: true)
    }

    // MARK: - Archive

    /// Writes the report, then updates the memory profile.
    ///
    /// Order is deliberate: the report lands first, because it is the product
    /// and it must exist even if the memory update fails.
    func archive(
        outcome: SynthesisOutcome,
        context: SessionCompletionContext
    ) async throws -> ArchiveOutcome {
        try ensureDirectory()

        let fileURL = url(for: context)
        let markdown = Self.render(outcome: outcome, context: context)

        let data = Data(markdown.utf8)
        try data.write(to: fileURL, options: .atomic)

        logger.notice(
            "Report archived at \(fileURL.path, privacy: .public) (\(data.count) bytes)"
        )

        let rules = try await applyMemoryUpdates(
            rules: outcome.rulesHarvested,
            context: context
        )

        return ArchiveOutcome(
            reportPath: fileURL.path,
            rulesHarvested: rules,
            reportBytes: data.count
        )
    }

    /// Records a session that could not be synthesised.
    ///
    /// A missing API key or a network failure must still leave a trace: the
    /// session happened, the telemetry is in SQLite, and the user deserves a
    /// file explaining why there is no debrief.
    func recordFailedSession(
        failureReason: String,
        context: SessionCompletionContext
    ) async -> ArchiveOutcome? {
        do {
            try ensureDirectory()

            let outcome = SynthesisOutcome(
                reportMarkdown: """
                # DayPilot — synthesis could not complete

                The session below was captured and its events are stored in \
                `session_events`, but the executive debrief was not generated.

                **Reason:** \(failureReason)

                **Duration:** \(Self.durationDescription(seconds: Int(context.durationSeconds.rounded())))
                **Events captured:** \(context.eventCount) (\(context.breadcrumbCount) ephemeral)

                Raw session data has been purged per Zero-Trace Mode. Only this report remains.
                """,
                voiceScript: "",
                providerLabel: "unavailable",
                model: "unavailable",
                temperature: 0,
                promptCharacters: 0,
                rulesHarvested: []
            )

            let fileURL = url(for: context)
            try Data(Self.render(outcome: outcome, context: context).utf8)
                .write(to: fileURL, options: .atomic)

            let rules = try await applyMemoryUpdates(rules: [], context: context)

            logger.notice(
                "Failed-session report archived at \(fileURL.path, privacy: .public)"
            )
            return ArchiveOutcome(
                reportPath: fileURL.path,
                rulesHarvested: rules,
                reportBytes: 0
            )
        } catch {
            logger.error("Could not archive the failed-session report: \(error.localizedDescription, privacy: .public)")
            // Even a failed archive must not lose the session's telemetry.
            _ = try? await applyMemoryUpdates(rules: [], context: context)
            return nil
        }
    }

    /// Records a probe session: too small to brief, so no model was called.
    func recordProbeSession(context: SessionCompletionContext) async -> ArchiveOutcome? {
        do {
            try ensureDirectory()

            let outcome = SynthesisOutcome(
                reportMarkdown: Self.probeNote(context: context),
                voiceScript: "",
                providerLabel: "not called",
                model: "not called",
                temperature: 0,
                promptCharacters: 0,
                rulesHarvested: [],
                isProbe: true
            )

            let fileURL = url(for: context)
            let data = Data(Self.render(outcome: outcome, context: context).utf8)
            try data.write(to: fileURL, options: .atomic)

            _ = try await applyMemoryUpdates(rules: [], context: context)

            logger.notice("Probe-session note archived at \(fileURL.path, privacy: .public)")
            return ArchiveOutcome(reportPath: fileURL.path, rulesHarvested: [], reportBytes: data.count)
        } catch {
            logger.error("Could not archive the probe-session note: \(error.localizedDescription, privacy: .public)")
            _ = try? await applyMemoryUpdates(rules: [], context: context)
            return nil
        }
    }

    /// The two-line note a probe session leaves behind.
    static func probeNote(context: SessionCompletionContext) -> String {
        let duration = durationDescription(seconds: Int(context.durationSeconds.rounded()))
        let events = context.eventCount == 1 ? "1 event" : "\(context.eventCount) events"
        return """
        # Day Brief — \(BriefSanitizer.dayTitle(from: context.stoppedAt))

        **Probe session — \(duration), \(events).** Nothing substantive was on screen, so no briefing was written. Raw captures were purged per Zero-Trace Mode.
        """
    }

    // MARK: - Memory updates

    /// Appends the harvested rules and folds the session into the counters.
    ///
    /// Returns the rules that were actually new, since most will already be in
    /// the profile and the caller needs to report the true count.
    @discardableResult
    private func applyMemoryUpdates(
        rules: [String],
        context: SessionCompletionContext
    ) async throws -> [String] {
        var accepted: [String] = []
        for rule in rules {
            await memoryStore.appendRuleOfThumb(rule)
            accepted.append(rule)
        }

        await memoryStore.updateSessionStats(
            durationHours: context.durationSeconds / 3600,
            breadcrumbsCount: context.breadcrumbCount
        )

        return accepted
    }

    // MARK: - Rendering

    /// The on-disk report: the brief first, then a short provenance block for
    /// auditing.
    private static func render(
        outcome: SynthesisOutcome,
        context: SessionCompletionContext
    ) -> String {
        let generated = Self.generatedFormatter.string(from: Date())
        let duration = durationDescription(seconds: Int(context.durationSeconds.rounded()))

        var lines: [String] = []
        lines.append("\(outcome.reportMarkdown)")
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("### Provenance")
        lines.append("")
        lines.append("- **Session:** `\(context.sessionId)`")
        lines.append("- **Duration:** \(duration)")
        lines.append("- **Events captured:** \(context.eventCount) (\(context.breadcrumbCount) ephemeral)")
        if context.suppressedFrameCount > 0 {
            lines.append("- **Frames suppressed by the privacy shield:** \(context.suppressedFrameCount)")
        }
        if outcome.isProbe {
            lines.append("- **Debrief:** not generated — the session was below the briefing threshold")
        } else {
            lines.append("- **Synthesised with:** \(outcome.providerLabel) · `\(outcome.model)`")
        }
        if outcome.promptCharacters > 0 {
            lines.append("- **Prompt size:** \(outcome.promptCharacters) characters")
        }
        lines.append("- **Generated:** \(generated)")

        if !outcome.rulesHarvested.isEmpty {
            lines.append("")
            lines.append("### Added to your working profile")
            lines.append("")
            for rule in outcome.rulesHarvested {
                lines.append("- \(rule)")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Paths

    /// `Reports/YYYY-MM-DD_<sessionId>.md` in Application Support.
    ///
    /// The date is the user's local calendar day, not UTC: a debrief for 1am
    /// work belongs to the day the user thinks they worked.
    private func url(for context: SessionCompletionContext) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        let day = formatter.string(from: context.stoppedAt)
        let safeSessionID = context.sessionId
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        return reportsDirectory
            .appendingPathComponent("\(day)_\(safeSessionID).md", isDirectory: false)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: reportsDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ArchiveError.reportsPathIsNotADirectory(reportsDirectory.path)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: reportsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ArchiveError.couldNotCreateDirectory(error.localizedDescription)
        }
    }

    // MARK: - Formatting

    static func durationDescription(seconds: Int) -> String {
        guard seconds > 0 else { return "under a second" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if hours == 0 && minutes == 0 { parts.append("\(remainingSeconds)s") }
        return parts.joined(separator: " ")
    }

    /// Instance-scoped: `ISO8601DateFormatter` is neither `Sendable` nor
    /// settleable as a class method without a time zone.
    private static let generatedFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

}

enum ArchiveError: LocalizedError {
    case reportsPathIsNotADirectory(String)
    case couldNotCreateDirectory(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .reportsPathIsNotADirectory(let path):
            "The reports location is not a directory: \(path)"
        case .couldNotCreateDirectory(let message):
            "DayPilot could not create the reports directory: \(message)"
        case .writeFailed(let message):
            "DayPilot could not write the report: \(message)"
        }
    }
}
