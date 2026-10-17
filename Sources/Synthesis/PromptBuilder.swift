import Foundation

/// Assembles the two halves of a synthesis request.
///
/// The division matters: the system prompt carries the standing rules — who the
/// user is, how to prune, what shape the answer takes — and is identical every
/// session. The user payload carries the day's telemetry. Keeping them separate
/// means the identity and rules can be re-used/extended without re-sending, and
/// it makes the pruning step testable in isolation.
struct PromptBuilder {

    /// What the pre-flight pruning did, surfaced to the log and the report so
    /// the model never silently receives thinned data.
    struct PruningReport: Sendable, Equatable {
        let eventsRead: Int
        let eventsMerged: Int
        let eventsPrunedLowDwell: Int
        let eventsIncluded: Int
        let ephemeralEvents: Int
        let payloadCharacters: Int
        let payloadTruncated: Bool
    }

    /// Sessions shorter than this produce no meaningful debrief; the report
    /// says so instead of asking the model to invent a day.
    static let minimumSessionSeconds: TimeInterval = 5

    // MARK: - System prompt

    /// The standing instructions: who the user is, how to read the evidence,
    /// and the rules that turn a day of telemetry into a chief-of-staff memo.
    ///
    /// Structure is selected by the evidence, never forced by a template — a
    /// quiet day gets a short honest brief instead of four empty sections.
    /// The voice-script delimiters are retained as parameters for call-site
    /// stability; the spoken brief itself was retired with the audio feature.
    static func systemPrompt(
        memoryContext: String,
        voiceScriptStartTag: String = "[VOICE_SCRIPT]",
        voiceScriptEndTag: String = "[/VOICE_SCRIPT]"
    ) -> String {
        """
        You are DayPilot, the chief of staff for the person described below.
        Each evening you write the end-of-day brief a chief of staff would hand a CEO:
        what the day was, where the time went, what moved, what is open, and — only
        when the day's data supports it — the single best first move for tomorrow.
        You write ONE brief about ONE work session, addressed to the person as "you".

        # THE USER

        \(memoryContext)

        Use this profile to interpret what was on screen. Never recite it back.

        # THE EVIDENCE

        You receive one JSON document:

        - `evidence` — precomputed facts and the ground truth for every number you
          write: time per surface, deep-work blocks, context switches, passive
          browsing, artifacts actually seen on screen (files, domains, windows),
          friction lines, first and last activity, and `local_date`.
          `captured_minutes` counts screen-active time only — idle gaps between
          captures are excluded — so never reconcile it against wall-clock time.
        - `ephemeral_logs` — fragments from transient surfaces (notes, scratchpads,
          AI chats). The only place to look for loose ideas worth rescuing.
        - `ide_telemetry` — time in code per window, plus any friction line seen there.
        - `browser_history` — pages with dwell time; `status: scrolling_no_action`
          means passive.
        - `other_activity` — everything else, one entry per surface.
        - `pruning_note` — what was already dropped before you saw the data.

        Every factual sentence must trace to this document. If something that matters
        was not captured, say "not captured" once and move on. Never invent a file,
        command, URL, tool, project, person, or number. Numbers come only from
        `evidence`; never round or estimate on your own. `start_time` and `stop_time`
        are UTC — do not quote or convert clock times.

        # THE BRIEF

        Title: `# Day Brief — <evidence.local_date>`.

        Always open with `## The day in brief`: 2 to 3 sentences, under 60 words — the
        shape of the day (focused or fragmented, where most time went), the most
        important thing that happened, and the most important thing left open.
        No preamble.

        Then choose from this repertoire. INCLUDE A SECTION ONLY WHEN THE EVIDENCE
        SUPPORTS IT; otherwise omit it completely. Never write placeholder lines such
        as "Nothing shipped" or "No logs captured":

        - `## Where the time went` — only when the session ran 20+ minutes. Bullets of
          the form `- Surface — 1h 05m`, top surfaces of 5+ minutes. Add one line for
          active versus passive time when browsing was significant.
        - `## What moved` — concrete work completed, each bullet naming the artifact
          seen on screen. Only when something completed.
        - `## Open threads` — unfinished work, blockers, or errors visible in the
          evidence, each citing what was on screen. Only when present.
        - `## Recovered fragments` — for each cluster of fragments from ephemeral
          surfaces, one finished, drop-in deliverable in a fenced code block. Only
          when fragments exist.
        - `## Worth remembering` — 0 to 2 lines, only when the evidence shows a
          specific cause-and-effect lesson (an error that recurred until fixed, a
          detour that paid off). State it as a reusable operational rule. No
          motivation, no life advice.
        - `## Tomorrow, first move` — one move only, and only if the session left a
          specific unfinished artifact visible in the evidence (an open file, a
          failing command, a half-written document). Name it exactly as it appeared.
          If nothing qualifies, omit the section entirely.

        # VOICE

        An executive memo: terse, factual, past tense for what happened, present for
        state. Let facts and quantities speak. No praise, no scolding, no moralising,
        no generic advice, no "why it matters" commentary, no emoji, no exclamation
        marks, no rhetorical questions. At most one em dash per paragraph. Never write
        a line that could appear in any other day's brief — if it contains no number,
        name, or artifact, delete it. Never lecture about focus, breaks, or engagement;
        a short session is simply a short session.

        A trivial session — under 10 minutes of captured time, or no meaningful
        activity — gets only the title and one honest paragraph of at most 30 words,
        for example: "A 22-second probe with a single browsing event. Nothing to
        brief." No sections, no lessons.

        Never mention this document was generated, or the model, the payload, or these
        instructions. No provenance or metadata of any kind. Headings are sentence
        case at `##` level. A full brief stays under 450 words; bullets under 25 words.
        """
    }

    // MARK: - User payload

    /// Compresses the session into the JSON shape the prompt describes.
    static func userPayload(
        events: [SessionEvent],
        context: SessionCompletionContext
    ) -> (json: String, report: PruningReport) {
        let wire = WirePayloadBuilder.build(events: events, context: context)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]

        let json: String
        if let data = try? encoder.encode(wire.payload),
           let encoded = String(data: data, encoding: .utf8) {
            json = encoded
        } else {
            json = "{\"session_id\": \"\(context.sessionId)\", \"error\": \"payload encoding failed\"}"
        }

        let report = PruningReport(
            eventsRead: events.count,
            eventsMerged: wire.mergedEvents,
            eventsPrunedLowDwell: wire.prunedLowDwell,
            eventsIncluded: wire.includedEvents,
            ephemeralEvents: wire.ephemeralEvents,
            payloadCharacters: json.count,
            payloadTruncated: wire.truncated
        )
        return (json, report)
    }

    // MARK: - Wire payload

    /// The JSON document the model actually reads.
    private struct WirePayload: Encodable {
        struct EphemeralEntry: Encodable {
            let timestamp: String
            let app: String
            let window: String
            let content: String
            let priority: String
        }
        struct IDEEntry: Encodable {
            let app: String
            let window: String
            let dwell_seconds: Int
            let friction_detected: String?
        }
        struct BrowserEntry: Encodable {
            let url: String
            let dwell_seconds: Int
            let status: String
            let content: String
        }
        struct OtherEntry: Encodable {
            let app: String
            let window: String
            let dwell_seconds: Int
            let is_ephemeral: Bool
            let content: String
        }

        /// Deterministic, precomputed facts about the day. This is the ground
        /// truth the brief may cite: every number and artifact in the model's
        /// output should trace back to a field here, and the sanitizer checks
        /// quoted artifacts against the payload these facts came from.
        struct Evidence: Encodable {
            struct SurfaceEntry: Encodable {
                let surface: String
                let minutes: Int
            }
            struct WorkBlock: Encodable {
                let surface: String
                let minutes: Int
            }
            struct ArtifactSet: Encodable {
                let files: [String]
                let domains: [String]
                let windows: [String]
            }

            let local_date: String
            let captured_minutes: Int
            let first_activity: String
            let last_activity: String
            let surfaces: [SurfaceEntry]
            let deep_work_blocks: [WorkBlock]
            let context_switches: Int
            let switches_per_hour: Int
            let fragmentation: String
            let passive_browsing_minutes: Int
            let artifacts: ArtifactSet
            let friction: [String]
            let ephemeral_fragments: Int
        }

        let session_id: String
        let start_time: String
        let stop_time: String
        let duration_seconds: Int
        let event_count: Int
        let pruning_note: String
        let evidence: Evidence
        let ephemeral_logs: [EphemeralEntry]
        let ide_telemetry: [IDEEntry]
        let browser_history: [BrowserEntry]
        let other_activity: [OtherEntry]
    }

    /// One event after merging, carrying its measured dwell time.
    private struct AggregatedEvent {
        var bundleId: String
        var appName: String
        var windowTitle: String
        var isEphemeral: Bool
        var priority: String
        var timestamp: String
        var dwell: TimeInterval
        var lines: [String]
    }

    private enum WirePayloadBuilder {

        static func build(
            events: [SessionEvent],
            context: SessionCompletionContext
        ) -> (payload: WirePayload, mergedEvents: Int, prunedLowDwell: Int, includedEvents: Int, ephemeralEvents: Int, truncated: Bool) {
            let timestampFormatter = ISO8601DateFormatter()
            timestampFormatter.formatOptions = [.withInternetDateTime]

            let sorted = events.sorted { $0.timestamp < $1.timestamp }

            // Merge consecutive events on the same surface. A single window that
            // changes text four times as the user types is one period of work,
            // not four.
            var merged: [AggregatedEvent] = []
            for event in sorted {
                let lines = Self.deduplicatedLines(event.extractedTextDelta)
                if var last = merged.last,
                   last.bundleId == event.bundleId,
                   last.windowTitle == event.windowTitle {
                    last.dwell += Self.dwell(of: event, in: sorted)
                    for line in lines where !last.lines.contains(line) {
                        last.lines.append(line)
                    }
                    merged[merged.count - 1] = last
                } else {
                    merged.append(
                        AggregatedEvent(
                            bundleId: event.bundleId,
                            appName: event.appName,
                            windowTitle: event.windowTitle,
                            isEphemeral: event.isEphemeral,
                            priority: Self.ephemeralPriority(bundleId: event.bundleId),
                            timestamp: event.timestamp,
                            dwell: Self.dwell(of: event, in: sorted),
                            lines: lines
                        )
                    )
                }
            }
            let mergedCount = max(0, sorted.count - merged.count)

            // Pass 1. Short, non-ephemeral visits are the noise the debrief must
            // never see — but an ephemeral fragment always survives, however brief.
            let dwellFloor = TimeInterval(DayPilotConfiguration.minimumMeaningfulDwellSeconds)
            let prePruned = merged.filter { event in
                event.isEphemeral || event.dwell >= dwellFloor
                    || event.bundleId == AppInfo.identifier
            }
            let prunedLowDwell = merged.count - prePruned.count

            // Cap. Preserves the head and the tail — the shape of a day is how
            // it started and what it was doing when it stopped — and states
            // plainly how much was dropped, so the model never guesses.
            let budget = DayPilotConfiguration.maxPromptEvents
            var kept: [AggregatedEvent]
            var truncated = false
            if prePruned.count > budget {
                truncated = true
                let headCount = budget / 2
                let tailCount = budget - headCount
                kept = Array(prePruned.prefix(headCount)) + Array(prePruned.suffix(tailCount))
            } else {
                kept = prePruned
            }

            var ephemeralLogs: [WirePayload.EphemeralEntry] = []
            var ideTelemetry: [WirePayload.IDEEntry] = []
            var browserHistory: [WirePayload.BrowserEntry] = []
            var otherActivity: [WirePayload.OtherEntry] = []

            for event in kept {
                let content = Self.truncatedLines(event.lines)

                // Ephemeral first, and on purpose. The ephemeral flag comes
                // from the app's real identity — a bundle id in the config's
                // targets, or a browser host in the exploratory domains list —
                // so it is authoritative. A browser hosting an AI chat is an
                // ephemeral surface, not browsing.
                if event.isEphemeral {
                    ephemeralLogs.append(
                        WirePayload.EphemeralEntry(
                            timestamp: event.timestamp,
                            app: event.appName,
                            window: event.windowTitle,
                            content: content,
                            priority: event.priority
                        )
                    )
                } else if Self.isBrowser(bundleId: event.bundleId) {
                    browserHistory.append(
                        WirePayload.BrowserEntry(
                            url: Self.addressText(for: event),
                            dwell_seconds: Int(event.dwell.rounded()),
                            status: Self.scrollStatus(event: event),
                            content: content
                        )
                    )
                } else if Self.isDevelopment(bundleId: event.bundleId) {
                    ideTelemetry.append(
                        WirePayload.IDEEntry(
                            app: event.appName,
                            window: event.windowTitle,
                            dwell_seconds: Int(event.dwell.rounded()),
                            friction_detected: Self.frictionLine(in: event.lines)
                        )
                    )
                } else {
                    otherActivity.append(
                        WirePayload.OtherEntry(
                            app: event.appName,
                            window: event.windowTitle,
                            dwell_seconds: Int(event.dwell.rounded()),
                            is_ephemeral: event.isEphemeral,
                            content: content
                        )
                    )
                }
            }

            let pruningNote: String
            if truncated {
                pruningNote =
                    "\(prePruned.count - budget) middle events were omitted to stay inside the prompt budget; "
                    + "the first \(budget / 2) and last \(budget - budget / 2) are present."
            } else if prunedLowDwell > 0 {
                pruningNote =
                    "\(prunedLowDwell) visits under \(DayPilotConfiguration.minimumMeaningfulDwellSeconds) "
                    + "seconds were dropped as low-dwell noise."
            } else {
                pruningNote = "No events were pruned."
            }

            let evidence = Self.evidence(merged: merged, kept: kept, context: context)

            let payload = WirePayload(
                session_id: context.sessionId,
                start_time: timestampFormatter.string(from: context.startedAt),
                stop_time: timestampFormatter.string(from: context.stoppedAt),
                duration_seconds: Int(context.durationSeconds.rounded()),
                event_count: kept.count,
                pruning_note: pruningNote,
                evidence: evidence,
                ephemeral_logs: ephemeralLogs,
                ide_telemetry: ideTelemetry,
                browser_history: browserHistory,
                other_activity: otherActivity
            )

            return (
                payload,
                mergedCount,
                prunedLowDwell,
                kept.count,
                ephemeralLogs.count,
                truncated
            )
        }

        // MARK: Evidence

        /// Computes the day's ground truth. Dwell-based facts come from the
        /// full merged timeline so the numbers are honest; artifacts come from
        /// the pruned view the model actually reads, so anything citable is
        /// visible in the payload the sanitizer will check against.
        static func evidence(
            merged: [AggregatedEvent],
            kept: [AggregatedEvent],
            context: SessionCompletionContext
        ) -> WirePayload.Evidence {
            let totalDwell = merged.reduce(0) { $0 + $1.dwell }
            let capturedMinutes = Int(totalDwell / 60)

            // Time per app.
            var appSeconds: [String: TimeInterval] = [:]
            for event in merged {
                appSeconds[event.appName, default: 0] += event.dwell
            }
            let surfaces = appSeconds
                .map { WirePayload.Evidence.SurfaceEntry(surface: $0.key, minutes: Int(($0.value / 60).rounded())) }
                .filter { $0.minutes >= 1 }
                .sorted { lhs, rhs in
                    if lhs.minutes == rhs.minutes { return lhs.surface < rhs.surface }
                    return lhs.minutes > rhs.minutes
                }
                .prefix(8)
                .map { $0 }

            // Deep-work runs: uninterrupted stretches in a development surface.
            let idleGap = TimeInterval(DayPilotConfiguration.idleTimeoutSeconds)
            var blocks: [WirePayload.Evidence.WorkBlock] = []
            var runSeconds: TimeInterval = 0
            var runApps: [String: TimeInterval] = [:]
            var runOpen = false

            func closeRun() {
                if runSeconds >= 15 * 60, let app = runApps.max(by: { $0.value < $1.value })?.key {
                    blocks.append(
                        WirePayload.Evidence.WorkBlock(
                            surface: app,
                            minutes: Int((runSeconds / 60).rounded())
                        )
                    )
                }
                runSeconds = 0
                runApps = [:]
                runOpen = false
            }

            for (index, event) in merged.enumerated() {
                let isDevelopment = Self.isDevelopment(bundleId: event.bundleId)
                var gap: TimeInterval = 0
                if index > 0 {
                    let previous = merged[index - 1]
                    gap = Self.date(fromISO: event.timestamp).timeIntervalSince(Self.date(fromISO: previous.timestamp)) - previous.dwell
                }

                if !isDevelopment {
                    if runOpen { closeRun() }
                    continue
                }
                if runOpen && gap > idleGap { closeRun() }
                runOpen = true
                runSeconds += event.dwell
                runApps[event.appName, default: 0] += event.dwell
            }
            if runOpen { closeRun() }

            // Switching behaviour.
            let switches = zip(merged, merged.dropFirst())
                .filter { $0.0.bundleId != $0.1.bundleId }
                .count
            let hours = max(Double(capturedMinutes) / 60.0, 1.0 / 60.0)
            let switchesPerHour = Int((Double(switches) / hours).rounded())

            let fragmentation: String
            if capturedMinutes < 10 {
                fragmentation = "insufficient-data"
            } else if switchesPerHour < 8 {
                fragmentation = "focused"
            } else if switchesPerHour < 20 {
                fragmentation = "moderate"
            } else {
                fragmentation = "fragmented"
            }

            // Passive browsing: visits classified as scrolling.
            let passiveSeconds = kept
                .filter { Self.isBrowser(bundleId: $0.bundleId) && Self.scrollStatus(event: $0) == "scrolling_no_action" }
                .reduce(0) { $0 + $1.dwell }
            let passiveMinutes = Int((passiveSeconds / 60).rounded())

            // Artifacts actually seen on screen.
            let corpus = kept
                .map { $0.windowTitle + "\n" + $0.lines.joined(separator: "\n") }
                .joined(separator: "\n")
            let artifacts = WirePayload.Evidence.ArtifactSet(
                files: Self.matches(pattern: Self.filePattern, in: corpus, limit: 40),
                domains: Self.domains(in: kept, corpus: corpus, limit: 20),
                windows: Self.windowLabels(kept, limit: 15)
            )

            let friction = kept
                .filter { Self.isDevelopment(bundleId: $0.bundleId) }
                .compactMap { Self.frictionLine(in: $0.lines) }
                .reduce(into: [String]()) { result, line in
                    if !result.contains(line) { result.append(line) }
                }
                .prefix(6)
                .map { $0 }

            let localDate: String = {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US")
                formatter.dateFormat = "EEEE, d MMMM yyyy"
                return formatter.string(from: context.stoppedAt)
            }()

            return WirePayload.Evidence(
                local_date: localDate,
                captured_minutes: capturedMinutes,
                first_activity: merged.first?.timestamp ?? "",
                last_activity: merged.last?.timestamp ?? "",
                surfaces: surfaces,
                deep_work_blocks: Array(blocks.prefix(6)),
                context_switches: switches,
                switches_per_hour: switchesPerHour,
                fragmentation: fragmentation,
                passive_browsing_minutes: passiveMinutes,
                artifacts: artifacts,
                friction: friction,
                ephemeral_fragments: kept.filter { $0.isEphemeral }.count
            )
        }

        private static let filePattern =
            #"(?i)\b[\w./-]{2,120}\.(swift|ts|tsx|js|jsx|py|rb|go|rs|md|json|yml|yaml|toml|sh|zsh|css|html|kt|java|m|mm|cpp|h|hpp|plist|entitlements|sql|txt)\b"#

        private static let domainPattern =
            #"(?i)\b(?:[a-z0-9-]+\.)+(?:com|org|net|io|ai|dev|app|co|xyz|so|sh|me|gg|cloud|tech|site|store)\b"#

        private static func matches(
            pattern: String,
            in text: String,
            limit: Int,
            rejectedPredecessors: Set<Character> = []
        ) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            var seen = Set<String>()
            var result: [String] = []
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                // A path like /Applications/DayPilot.app is not a domain.
                if !rejectedPredecessors.isEmpty, swiftRange.lowerBound > text.startIndex {
                    let predecessor = text[text.index(before: swiftRange.lowerBound)]
                    if rejectedPredecessors.contains(predecessor) { continue }
                }
                var value = String(text[swiftRange])
                while value.hasSuffix(".") || value.hasSuffix(",") || value.hasSuffix(";") {
                    value.removeLast()
                }
                guard !value.isEmpty else { continue }
                guard seen.insert(value.lowercased()).inserted else { continue }
                result.append(value)
                if result.count == limit { break }
            }
            return result
        }

        private static func domains(in kept: [AggregatedEvent], corpus: String, limit: Int) -> [String] {
            var seen = Set<String>()
            var result: [String] = []

            for event in kept where Self.isBrowser(bundleId: event.bundleId) {
                if let host = EphemeralSurfaceClassifier.host(from: event.windowTitle),
                   seen.insert(host.lowercased()).inserted {
                    result.append(host)
                }
            }
            for domain in matches(
                pattern: domainPattern,
                in: corpus,
                limit: limit,
                rejectedPredecessors: ["/", "."]
            ) {
                guard seen.insert(domain.lowercased()).inserted else { continue }
                result.append(domain)
            }
            return Array(result.prefix(limit))
        }

        private static func windowLabels(_ kept: [AggregatedEvent], limit: Int) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for event in kept {
                let label = String(event.windowTitle.prefix(80))
                guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { continue }
                result.append(label)
                if result.count == limit { break }
            }
            return result
        }

        // MARK: Helpers

        /// Dwell time for an event: the gap to the next event, capped so a
        /// session that ended while a window was open does not attribute the
        /// whole afternoon to it.
        private static func dwell(of event: SessionEvent, in sorted: [SessionEvent]) -> TimeInterval {
            guard let index = sorted.firstIndex(where: { $0.id == event.id }) else { return 0 }
            let cap = TimeInterval(DayPilotConfiguration.idleTimeoutSeconds)
            guard index + 1 < sorted.count else { return min(cap, TimeInterval(DayPilotConfiguration.minimumMeaningfulDwellSeconds)) }
            let gap = Self.timestamp(sorted[index + 1]).timeIntervalSince(Self.timestamp(event))
            guard gap.isFinite, gap > 0 else { return 0 }
            return min(cap, gap)
        }

        private static var timestampFormatter: ISO8601DateFormatter {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }

        private static func timestamp(_ event: SessionEvent) -> Date {
            timestampFormatter.date(from: event.timestamp) ?? Date.distantPast
        }

        private static func date(fromISO value: String) -> Date {
            timestampFormatter.date(from: value) ?? Date.distantPast
        }

        private static func deduplicatedLines(_ delta: String) -> [String] {
            var seen = Set<String>()
            return delta
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        private static func truncatedLines(_ lines: [String]) -> String {
            let limit = DayPilotConfiguration.maxCharactersPerEvent
            var total = 0
            var kept: [String] = []
            for line in lines {
                if total + line.count > limit { break }
                kept.append(line)
                total += line.count
            }
            let text = kept.joined(separator: "\n")
            if kept.count < lines.count {
                return text + "\n… and \(lines.count - kept.count) more lines"
            }
            return text
        }

        private static func ephemeralPriority(bundleId: String) -> String {
            DayPilotConfiguration.ephemeralTargets
                .first { $0.bundleIdentifier == bundleId }?.priority ?? "high"
        }

        private static func isBrowser(bundleId: String) -> Bool {
            bundleId.contains(".Chrome")
                || bundleId.contains(".Safari")
                || bundleId.contains(".Firefox")
                || bundleId.contains(".Edge")
                || bundleId.contains(".Brave")
                || bundleId.contains(".Arc")
        }

        private static func isDevelopment(bundleId: String) -> Bool {
            DayPilotConfiguration.coreDevelopmentBundleIdentifiers.contains(bundleId)
        }

        /// Prefers the address bar over the window title, because a browser
        /// window's title is the page name, not the URL.
        private static func addressText(for event: AggregatedEvent) -> String {
            if let host = EphemeralSurfaceClassifier.host(from: event.windowTitle) {
                return host
            }
            return event.windowTitle
        }

        /// Marks passive browsing: a long visit that produced very little new
        /// text is a scroll, not a lookup.
        private static func scrollStatus(event: AggregatedEvent) -> String {
            let characters = event.lines.reduce(0) { $0 + $1.count }
            let perSecond = event.dwell > 0 ? Double(characters) / event.dwell : 0
            let floor = Double(DayPilotConfiguration.minimumMeaningfulDwellSeconds)
            return perSecond < floor ? "scrolling_no_action" : "browsing"
        }

        /// First line that looks like a build error, a compiler diagnostic or a
        /// failing assertion — the friction the debrief is supposed to catch.
        private static func frictionLine(in lines: [String]) -> String? {
            let markers = ["error:", "warning:", "fatal", "failed", "cannot", "expected",
                          "undefined", "mismatch", "unresolved", "exception", "not found"]
            for line in lines {
                let lowered = line.lowercased()
                if markers.contains(where: { lowered.contains($0) }) { return line }
            }
            return nil
        }
    }
}
