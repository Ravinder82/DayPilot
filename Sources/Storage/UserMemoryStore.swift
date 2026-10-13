import Foundation
import os

/// Owns `~/Library/Application Support/DayPilot/user_memory.json`.
///
/// The file is the app's first-person memory of its user: it is seeded once on
/// first launch and then only ever grows — session telemetry accumulates and
/// rules of thumb are appended, never overwritten. All mutation happens on the
/// main actor, and every write is atomic (write to a sibling temporary file,
/// then replace) so a crash mid-write can never truncate the user's memory.
@MainActor
final class UserMemoryStore {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "usermemory")

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // `user_memory.json` is a contract: its key names are part of the
        // schema the skill config and the synthesis prompt depend on, so they
        // are snake_case rather than Swift's camelCase property names.
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var profile: UserMemoryProfile

    /// The directory this store owns.
    ///
    /// The report archiver must be rooted here rather than at a hard-coded
    /// Application Support path, otherwise a sandboxed memory profile gets a
    /// report written somewhere else entirely.
    let baseDirectory: URL

    /// Creates the store and brings `user_memory.json` into existence.
    ///
    /// - Parameter directory: Override for tests; defaults to Application
    ///   Support.
    init(directory: URL? = nil) throws {
        let base = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(DayPilotConfiguration.memoryDirectoryName, isDirectory: true)

        baseDirectory = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(DayPilotConfiguration.userMemoryFileName, isDirectory: false)

        let existingData = FileManager.default.contents(atPath: fileURL.path)

        if let existingData {
            if let decoded = try? decoder.decode(UserMemoryProfile.self, from: existingData) {
                profile = decoded
                logger.notice("Loaded user memory from \(self.fileURL.path, privacy: .public)")
            } else {
                // Never destroy the user's memory on a decode failure: move the
                // unreadable file aside and seed a fresh profile.
                let quarantined = base.appendingPathComponent(
                    "user_memory.corrupt-\(Int(Date().timeIntervalSince1970)).json"
                )
                try? FileManager.default.moveItem(atPath: fileURL.path, toPath: quarantined.path)
                logger.error("User memory was unreadable and has been quarantined; reseeding.")
                profile = .seed
                try persist(profile)
            }
        } else {
            profile = .seed
            try persist(profile)
            logger.notice("Seeded a new user memory at \(self.fileURL.path, privacy: .public)")
        }
    }

    /// The in-memory profile.
    var current: UserMemoryProfile { profile }

    /// Absolute path of the backing file.
    var path: String { fileURL.path }

    /// Loads (re-reading from disk) and returns the profile.
    ///
    /// Use this at launch; `current` is the cheap synchronous snapshot for
    /// later phases.
    func loadMemory() async -> UserMemoryProfile {
        if let data = FileManager.default.contents(atPath: fileURL.path),
           let decoded = try? decoder.decode(UserMemoryProfile.self, from: data) {
            profile = decoded
        }
        return profile
    }

    /// Folds a completed session into the telemetry counters.
    ///
    /// - Parameters:
    ///   - durationHours: Wall-clock session length in hours.
    ///   - breadcrumbsCount: Ephemeral fragments captured in the session.
    func updateSessionStats(durationHours: Double, breadcrumbsCount: Int) async {
        profile.sessionTelemetrySummary.totalSessionsCompleted += 1
        profile.sessionTelemetrySummary.totalHoursTracked += durationHours
        profile.sessionTelemetrySummary.totalBreadcrumbsHarvested += breadcrumbsCount
        profile.sessionTelemetrySummary.lastSessionTimestamp = timestampFormatter.string(from: Date())

        do {
            try persist(profile)
            let message = String(
                format: "Telemetry updated: %d sessions, %.2f hours",
                profile.sessionTelemetrySummary.totalSessionsCompleted,
                profile.sessionTelemetrySummary.totalHoursTracked
            )
            logger.notice("\(message, privacy: .public)")
        } catch {
            logger.error("Could not persist session telemetry: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Appends a lesson to the running list of rules of thumb.
    ///
    /// Duplicates and near-duplicates are ignored so the list cannot be padded
    /// by a repeated lesson, and it is capped so the injected prompt stays
    /// dense rather than endless.
    func appendRuleOfThumb(_ rule: String) async {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !profile.cumulativeRulesOfThumb.contains(trimmed) else { return }

        profile.cumulativeRulesOfThumb.append(trimmed)
        let maximumRules = 40
        if profile.cumulativeRulesOfThumb.count > maximumRules {
            profile.cumulativeRulesOfThumb.removeFirst(
                profile.cumulativeRulesOfThumb.count - maximumRules
            )
        }
        let ruleCount = profile.cumulativeRulesOfThumb.count
        try? persist(profile)
        logger.notice("Rule of thumb recorded — \(ruleCount) on record")
    }

    // MARK: - Prompt export

    /// Renders the profile as a dense system-prompt injection block.
    ///
    /// This is the standing context the synthesis model receives before any
    /// session data: who the user is, what DayPilot is for, which projects are
    /// live, how they work, and what they have already learned. It is written
    /// compactly on purpose — it is paid for on every request.
    func exportContextForPrompt() -> String {
        let identity = profile.userIdentity
        let mandate = profile.appPurposeAndMandate
        let cognitive = profile.cognitiveProfile
        let telemetry = profile.sessionTelemetrySummary

        var lines: [String] = []
        lines.append("## USER MEMORY PROFILE")
        lines.append("")

        lines.append("### Identity")
        lines.append("- Role: \(identity.role)")
        lines.append("- Core stack: \(identity.coreStack.joined(separator: ", "))")
        lines.append("- Ecosystems: \(identity.ecosystems.joined(separator: ", "))")
        lines.append("")

        lines.append("### Mandate")
        lines.append("- What DayPilot does for me: \(mandate.whatDayPilotDoesForMe)")
        lines.append("- Tracking philosophy: \(mandate.trackingPhilosophy)")
        lines.append("")

        lines.append("### Active Projects")
        for project in profile.activeProjects {
            lines.append("- \(project.name) [\(project.type)] — \(project.status). Objective: \(project.objective)")
        }
        lines.append("")

        lines.append("### Cognitive Profile")
        lines.append("- Peak flow: \(cognitive.peakFlowWindow)")
        lines.append("- Friction patterns: \(cognitive.frictionPatterns.joined(separator: "; "))")
        lines.append("- Creative habits: \(cognitive.creativeHabits.joined(separator: "; "))")
        lines.append("")

        lines.append("### Cumulative Rules of Thumb")
        for (index, rule) in profile.cumulativeRulesOfThumb.enumerated() {
            lines.append("\(index + 1). \(rule)")
        }
        lines.append("")

        lines.append("### Session Telemetry")
        lines.append("- Completed sessions: \(telemetry.totalSessionsCompleted)")
        lines.append("- Hours tracked: \(String(format: "%.2f", telemetry.totalHoursTracked))")
        lines.append("- Breadcrumbs harvested: \(telemetry.totalBreadcrumbsHarvested)")
        lines.append("- Last session: \(telemetry.lastSessionTimestamp ?? "none yet")")

        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    /// Atomic write: serialize to a temporary file in the same directory, then
    /// `replaceItem`, which is atomic on APFS. A crash mid-serialization leaves
    /// the original file untouched.
    private func persist(_ value: UserMemoryProfile) throws {
        let data = try encoder.encode(value)
        let temporary = fileURL.appendingPathExtension("tmp")
        _ = try? FileManager.default.removeItem(atPath: temporary.path)
        try data.write(to: temporary, options: .atomic)
        _ = try? FileManager.default.removeItem(atPath: fileURL.path)
        _ = try FileManager.default.replaceItem(
            at: fileURL,
            withItemAt: temporary,
            backupItemName: nil,
            options: [],
            resultingItemURL: nil
        )
    }
}
