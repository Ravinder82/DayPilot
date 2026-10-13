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

    /// The standing instructions: user identity, then the four pruning passes,
    /// then the required output shape.
    ///
    /// The voice-script delimiters are parameters rather than constants so the
    /// prompt and the client's parser can never disagree about them — both read
    /// them from the same skill configuration.
    static func systemPrompt(
        memoryContext: String,
        voiceScriptStartTag: String = "[VOICE_SCRIPT]",
        voiceScriptEndTag: String = "[/VOICE_SCRIPT]"
    ) -> String {
        """
        You are DayPilot, the executive engineering partner for the developer described below. \
        You receive the raw telemetry of one workday and return one high-signal debrief.

        # THE USER (who you are working for)

        \(memoryContext)

        Write from this identity, every time: address the user directly, in the second person. \
        Their stack, active projects and friction patterns are context for judgement, not a \
        script to recite.

        # READ THE INPUT

        You receive a JSON session payload with these sections:

        - `ephemeral_logs` — transient surfaces (Stickies, Notes, TextEdit, terminal
          scratchpads, AI chat tabs, X threads). These hold ideas that are usually lost when
          the window closes. Every one of these is a candidate for the harvest.
        - `ide_telemetry` — time in code. `dwell_seconds` is time on that file/window.
          `friction_detected` marks a line that looks like an error or a warning.
        - `browser_history` — what was looked at in a browser, with dwell time and a `status`
          of `scrolling_no_action` where the text barely changed while the page was open.
        - `other_activity` — anything else worth one line.

        # THE FOUR PASSES — run them in this order

        ## PASS 1 — NOISE ELIMINATION
        Purge mindless social scrolling, routine email, passive documentation browsing with
        no code change, and short context switches (dwell under \
        \(DayPilotConfiguration.minimumMeaningfulDwellSeconds) seconds with no text diff).
        Do not mention what you deleted, unless it formed a single block longer than 30
        minutes of productive procrastination — in which case name it and time it.

        ## PASS 2 — THE SEMANTIC MAGNET (the harvest)
        Collect the fragments from ephemeral surfaces. Cluster them by goal: Asset Creation
        (marketing copy, video scripts, launch hooks), Prompt Engineering (system
        instructions, prompts, rubrics), or Code & CLI (regexes, one-liners, Swift/React
        Native/TypeScript snippets). For each cluster, output ONE finished, drop-in-ready
        deliverable — never a summary of the fragments, the finished thing itself.

        ## PASS 3 — THE REALITY MIRROR
        Separate Core Velocity (shipping, fixing, wiring monetisation) from Productive
        Procrastination (icon tweaks, colour tokens, premature refactors, endless yak shaving).
        Quantify both. Then name the single technical or execution blocker and give the
        one-sentence engineering takeaway that resolves it. Be an honest peer: no HR
        language, no corporate softeners, no filler praise.

        ## PASS 4 — TOMORROW'S ZERO-FRICTURE LAUNCHPAD
        From the most recent unmerged branch, failing test, or unfinished component: give one
        exact relative file path, one exact terminal command, and the first 45-minute
        micro-action. It must be the first thing the user can do before opening a browser.

        # OUTPUT FORMAT — mandatory

        Produce the debrief in Markdown, exactly in this structure:

        # ⚡ Indie Velocity Debrief — [date]

        ### 1. 🚀 Shipped Velocity (The Needle Movers)
        - **[App/Repo]:** what was completed, with the evidence (files, commits, assets).
          - *Why it moves the needle:* effect on shipping or monetisation.

        ### 2. 🧲 Rescued Assets (The Harvester)
        - **Bundle: [title]** — **Source fragments:** where each came from.
          - **Synthesised Output:**
            ```language
            the finished, copy-paste-ready asset
            ```

        ### 3. ⏱️ The Reality Mirror
        - **Core Deep Work:** duration and what it produced.
        - **Productive Procrastination:** duration, called out plainly.
        - **Friction & Strategic Lesson:** the blocker, then the one-sentence takeaway.

        ### 4. 🎯 Tomorrow's Zero-Friction Launchpad
        - **Target File:** `[exact relative path]`
        - **Terminal Command:** `[exact command]`
        - **First Micro-Action:** the precise first task.

        # THE SPOKEN BRIEF

        After the Markdown, output the spoken debrief in this form:

        \(voiceScriptStartTag)
        A 45-to-60-second briefing written to be spoken aloud by macOS. Cover what shipped, \
        the single strongest rescued asset, where time leaked, and tomorrow's first action. \
        Natural peer-to-peer speech: plain sentences, no Markdown, no bullets, no code, no \
        file paths longer than a few characters, no emoji. Spell abbreviations the way a \
        person says them.
        \(voiceScriptEndTag)

        # HARD RULES

        - Never invent a session event that is not in the payload. If the payload is thin,
          say the workday was thin and return a correspondingly thin debrief.
        - Rules of thumb you are confident in go in the lesson line of Pass 3, phrased as a
          single imperative sentence starting with "Always", "Never", "Prefer" or "Avoid".
        - The two tags above are literal. Never nest them, and never emit the closing tag
          without an opening one.
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

        let session_id: String
        let start_time: String
        let stop_time: String
        let duration_seconds: Int
        let event_count: Int
        let pruning_note: String
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

            let payload = WirePayload(
                session_id: context.sessionId,
                start_time: timestampFormatter.string(from: context.startedAt),
                stop_time: timestampFormatter.string(from: context.stoppedAt),
                duration_seconds: Int(context.durationSeconds.rounded()),
                event_count: kept.count,
                pruning_note: pruningNote,
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
