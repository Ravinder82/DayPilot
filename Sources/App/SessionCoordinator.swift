import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// What the user did in one captured moment, handed to the UI and the log.
struct CaptureEventSummary: Sendable {
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String
    let isEphemeral: Bool
    let category: String
    let textDelta: String
    let frameDelta: Double
    let recognitionDuration: TimeInterval
    let eventIndex: Int
}

/// The full outcome of a workday session.
///
/// A richer type than a tuple because the end of a session now does several
/// things and callers (status bar, smoke test) need to reason about each of
/// them independently — and because "the report failed" is a normal outcome
/// that must be representable rather than thrown.
struct SessionCompletion: Sendable, Equatable {
    let sessionId: String
    let eventCount: Int
    let durationSeconds: TimeInterval
    let breadcrumbCount: Int
    let reportMarkdown: String
    let reportPath: String
    let voiceScript: String
    let rulesHarvested: [String]
    let synthesisFailureReason: String?

    /// True when a debrief was actually generated.
    var hasReport: Bool { synthesisFailureReason == nil }
}

/// Screen Recording permission, handled so the system consent dialog never
/// appears unless the user asked for a permission check.
///
/// The trap this exists to prevent: `SCShareableContent` and
/// `CGRequestScreenCaptureAccess()` are the exact calls that make macOS show
/// its "would like to record this computer's screen" dialog — and macOS
/// re-shows it on every call while the grant is missing. An app that probes
/// from its Start button therefore greets the user with the same popup over
/// and over. The rule instead:
///
/// - `isGranted()` is the silent preflight the Start action uses. It never
///   prompts, so Play either starts a session or shows DayPilot's own
///   permission sheet.
/// - `confirmWithLiveProbe()` is the only live call, used when the user
///   explicitly clicks "Check Again" — the one moment a system dialog is
///   contextually correct, and silent whenever the grant already exists.
enum ScreenRecordingPermission {

    /// Silent preflight — reads the TCC grant without touching
    /// ScreenCaptureKit and without ever raising a dialog.
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Verifies the grant end-to-end with a live ScreenCaptureKit probe.
    ///
    /// Only for a user-initiated re-check: when the preflight reads stale
    /// `false` in a long-running process, this is what settles it. If the
    /// grant genuinely is missing, macOS shows its consent dialog here.
    static func confirmWithLiveProbe() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }
}

enum SessionCoordinatorError: LocalizedError, Equatable {
    case sessionAlreadyActive
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            "A workday session is already running."
        case .screenRecordingDenied:
            """
            Screen Recording permission is off. Turn DayPilot on in System \
            Settings > Privacy & Security > Screen Recording, then click \
            Check Again in DayPilot's permission sheet.
            """
        }
    }
}

/// The single state machine that turns screen changes into a debrief.
///
/// Owns every subsystem and is the only thing that mutates session state. It is
/// `@MainActor` because AppKit and the Accessibility API require the main thread,
/// while all the heavy lifting (pixel sampling, OCR, SQLite, HTTP, speech) is
/// pushed onto worker queues, actors and cooperative tasks elsewhere — so this
/// actor mostly waits.
@MainActor
final class SessionCoordinator {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "session")

    /// Lifecycle of a workday session.
    enum TrackingState: Sendable, Equatable {
        case idle
        case capturing
        case paused
        case synthesising
    }

    private struct WatchdogState: Sendable {
        var framesDelivered = 0
    }

    private let captureEngine: ScreenCaptureEngine
    private let textExtractor: VisionTextExtractor
    private let windowManager: WindowManager
    private let sessionStore: SessionStore
    private let userMemory: UserMemoryStore

    private let reportArchiver: ReportArchiver
    private let skillConfiguration: SkillConfiguration
    private let decisionEngine: DecisionEngineService

    private var watchdogTimer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?

    /// Crossed into the utility watchdog queue every frame.
    private let deliveryState = ThreadSafeBox(WatchdogState())
    private var lastObservedDeliveredFrames = 0
    private var stalledIntervals = 0

    /// Instance-scoped formatter: `ISO8601DateFormatter` is not `Sendable`.
    private let eventTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private(set) var state: TrackingState = .idle
    private(set) var currentSessionId: String?
    private(set) var recordedEventCount = 0
    private(set) var breadcrumbCount = 0
    private(set) var suppressedFrameCount = 0
    private(set) var sessionStartedAt: Date?

    /// Wall-clock seconds spent paused in the current session, excluded from
    /// `sessionElapsedSeconds` so the timer shows work time, not office time.
    private var pausedAccumulatedSeconds: TimeInterval = 0
    private var pauseStartedAt: Date?

    /// The debrief from the most recent session, so the status bar can show it
    /// or open it after the fact.
    private(set) var lastCompletion: SessionCompletion?

    /// Called on the main actor for every stored event.
    var onEvent: (@MainActor (CaptureEventSummary) -> Void)?

    /// Called on the main actor when capture has died under us.
    var onCaptureFailure: (@MainActor (String) -> Void)?

    /// Called on the main actor when the state machine changes state.
    var onStateChange: (@MainActor (TrackingState) -> Void)?

    init(
        captureEngine: ScreenCaptureEngine,
        textExtractor: VisionTextExtractor,
        windowManager: WindowManager,
        sessionStore: SessionStore,
        userMemory: UserMemoryStore,
        skillConfiguration: SkillConfiguration? = nil,
        reportArchiver: ReportArchiver? = nil,
        decisionEngine: DecisionEngineService? = nil
    ) {
        self.captureEngine = captureEngine
        self.textExtractor = textExtractor
        self.windowManager = windowManager
        self.sessionStore = sessionStore
        self.userMemory = userMemory

        let loaded = skillConfiguration ?? SkillConfigurationLoader.load().configuration
        self.skillConfiguration = loaded
        // Rooted in the memory store's directory so a report and the profile it
        // updates always live together, whoever owns them.
        self.reportArchiver = reportArchiver
            ?? ReportArchiver(
                memoryStore: userMemory,
                baseDirectory: userMemory.baseDirectory
            )
        self.decisionEngine = decisionEngine ?? DecisionEngineService()

        captureEngine.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handleFrame(frame) }
        }
        captureEngine.onFailure = { [weak self] message in
            Task { @MainActor in self?.handleCaptureFailure(message) }
        }
    }

    /// Builds a coordinator with every subsystem wired from the given stores.
    ///
    /// Convenience for the status bar and for tests; the dependencies are still
    /// injectable for anyone who wants to substitute one.
    static func makeDefault(
        sessionStore: SessionStore,
        userMemory: UserMemoryStore,
        skillConfiguration: SkillConfiguration? = nil,
        decisionEngine: DecisionEngineService? = nil
    ) -> SessionCoordinator {
        SessionCoordinator(
            captureEngine: ScreenCaptureEngine(),
            textExtractor: VisionTextExtractor(),
            windowManager: WindowManager(),
            sessionStore: sessionStore,
            userMemory: userMemory,
            skillConfiguration: skillConfiguration,
            decisionEngine: decisionEngine
        )
    }

    // MARK: - Session lifecycle

    /// Starts a workday session.
    ///
    /// Asks for Accessibility and Screen Recording permission first. Screen
    /// Recording is a hard requirement — without it there is nothing to
    /// capture — so a denial stops the session here rather than silently
    /// recording nothing for hours.
    func start() async throws {
        guard state == .idle else { throw SessionCoordinatorError.sessionAlreadyActive }

        // Silent check only: a system permission dialog must never interrupt
        // the Start action. Without Accessibility, captures still work — the
        // window title is just left empty.
        _ = windowManager.checkAccessibilityPermission()
        // Silent preflight only: the Start action must never greet the user
        // with a system consent dialog. When the grant is missing, DayPilot
        // throws and its own permission sheet explains the fix — no popups.
        guard ScreenRecordingPermission.isGranted() else {
            throw SessionCoordinatorError.screenRecordingDenied
        }

        let sessionId = await sessionStore.startSession()
        currentSessionId = sessionId
        sessionStartedAt = Date()
        pausedAccumulatedSeconds = 0
        pauseStartedAt = nil
        recordedEventCount = 0
        breadcrumbCount = 0
        suppressedFrameCount = 0
        await textExtractor.reset()
        captureEngine.resetGate()

        captureEngine.setSuppressed(Self.isFrontmostSurfaceSuppressed(windowManager: windowManager))
        installActivationObserver()
        startWatchdog()
        transition(to: .capturing)

        do {
            try await captureEngine.start()
        } catch {
            transition(to: .idle)
            currentSessionId = nil
            stopWatchdog()
            removeActivationObserver()
            throw error
        }

        logger.notice(
            "Session \(sessionId, privacy: .public) started — \(Int(DayPilotConfiguration.captureIntervalSeconds))s sampling"
        )
    }

    /// Pauses the session without generating a debrief.
    func pause() async {
        guard state == .capturing else { return }
        pauseStartedAt = Date()
        await captureEngine.stop()
        stopWatchdog()
        removeActivationObserver()
        transition(to: .paused)
        logger.notice("Session paused")
    }

    /// Resumes a paused session.
    func resume() async {
        guard state == .paused else { return }
        if let pauseStart = pauseStartedAt {
            pausedAccumulatedSeconds += Date().timeIntervalSince(pauseStart)
            pauseStartedAt = nil
        }
        transition(to: .capturing)
        captureEngine.setSuppressed(Self.isFrontmostSurfaceSuppressed(windowManager: windowManager))
        installActivationObserver()
        startWatchdog()
        do {
            try await captureEngine.start()
        } catch {
            transition(to: .idle)
            logger.error("Failed to resume capture: \(error.localizedDescription, privacy: .public)")
        }
        logger.notice("Session resumed")
    }

    /// Stops the session and runs the whole end-of-day lifecycle.
    ///
    /// The lifecycle is: halt capture, collect the session's events, assemble
    /// the prompt from the user profile plus the pruned telemetry, call the
    /// configured provider, clean and archive the brief, and fold what was
    /// learned back into `user_memory.json`.
    ///
    /// Stopping deliberately never throws. The captured data is already safe in
    /// SQLite, so a missing API key or a dead network must produce a report
    /// explaining what happened rather than losing the session.
    @discardableResult
    func stop() async -> SessionCompletion {
        guard state == .capturing || state == .paused, let sessionId = currentSessionId else {
            return lastCompletion ?? SessionCompletion(
                sessionId: currentSessionId ?? "",
                eventCount: recordedEventCount,
                durationSeconds: 0,
                breadcrumbCount: breadcrumbCount,
                reportMarkdown: "",
                reportPath: "",
                voiceScript: "",
                rulesHarvested: [],
                synthesisFailureReason: "No session was running"
            )
        }

        transition(to: .synthesising)

        await captureEngine.stop()
        stopWatchdog()
        removeActivationObserver()
        captureEngine.setSuppressed(false)
        await textExtractor.reset()

        let startedAt = sessionStartedAt ?? Date()
        let stoppedAt = Date()

        // Close the session in the store first: its breadcrumb count is derived
        // from what is actually on disk, so it is the authoritative number and
        // the in-memory counter is only ever a hint.
        let summary = await sessionStore.stopSession(sessionId: sessionId)

        let context = SessionCompletionContext(
            sessionId: sessionId,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            eventCount: summary.eventCount,
            breadcrumbCount: summary.breadcrumbCount,
            suppressedFrameCount: suppressedFrameCount
        )

        // ---- Synthesis ----------------------------------------------------
        //
        // A probe session — too short, or nothing ever on screen — never
        // reaches the model. It gets an honest two-line note instead of a
        // padded briefing.

        let isProbe = Self.isProbeSession(context: context)
        var failureReason: String?
        var outcome: SynthesisOutcome?

        if isProbe {
            logger.plain(
                "Probe session — \(context.eventCount) events over "
                + "\(Int(context.durationSeconds.rounded()))s; synthesis skipped"
            )
        } else {
            do {
                outcome = try await synthesise(context: context)
            } catch {
                failureReason = error.localizedDescription
                logger.error("Synthesis failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // ---- Archive and speak -------------------------------------------

        let archiveOutcome: ReportArchiver.ArchiveOutcome?
        if var outcome {
            // Rules of thumb only come from sessions with real substance; a
            // thin session has nothing to teach and must not pollute memory.
            let rules: [String]
            if context.durationSeconds >= RuleOfThumbHarvester.minimumSessionSeconds,
               context.eventCount >= RuleOfThumbHarvester.minimumSessionEvents {
                rules = RuleOfThumbHarvester.harvest(from: outcome.reportMarkdown)
            } else {
                rules = []
            }
            if !rules.isEmpty {
                outcome.rulesHarvested = rules
            }
            do {
                archiveOutcome = try await reportArchiver.archive(
                    outcome: outcome,
                    context: context
                )
            } catch {
                archiveOutcome = nil
                logger.error("Archiving failed: \(error.localizedDescription, privacy: .public)")
                failureReason = failureReason ?? error.localizedDescription
            }
        } else if isProbe {
            archiveOutcome = await reportArchiver.recordProbeSession(context: context)
        } else {
            let reason = failureReason ?? "Synthesis produced no report."
            archiveOutcome = await reportArchiver.recordFailedSession(
                failureReason: reason,
                context: context
            )
        }

        // ---- Done ----------------------------------------------------------

        transition(to: .idle)
        currentSessionId = nil

        let completion = SessionCompletion(
            sessionId: sessionId,
            eventCount: context.eventCount,
            durationSeconds: context.durationSeconds,
            breadcrumbCount: context.breadcrumbCount,
            reportMarkdown: outcome?.reportMarkdown
                ?? (isProbe ? ReportArchiver.probeNote(context: context) : ""),
            reportPath: archiveOutcome?.reportPath ?? "",
            voiceScript: "",
            rulesHarvested: archiveOutcome?.rulesHarvested ?? [],
            synthesisFailureReason: failureReason
        )
        lastCompletion = completion

        // ---- Zero-Trace Purge ----------------------------------------------
        // The Day Brief has been generated and archived. Now permanently erase
        // all raw OCR events and temporary capture artifacts so no screen text
        // survives beyond the final report.
        await sessionStore.purgeSession(sessionId: sessionId)
        logger.notice("Zero-trace purge complete for session \(sessionId, privacy: .public)")

        let message =
            "Session \(sessionId) closed — \(completion.eventCount) events, "
            + "\(completion.breadcrumbCount) breadcrumbs, "
            + "report \(completion.reportPath.isEmpty ? "not archived" : "archived")"
        logger.notice("\(message, privacy: .public)")

        return completion
    }

    /// True when a session is too small to deserve a model-written brief.
    ///
    /// Either it ran under the probe threshold, or it was short and almost
    /// nothing ever appeared on screen. Probe sessions produce an honest
    /// two-line note instead of a padded briefing.
    private static func isProbeSession(context: SessionCompletionContext) -> Bool {
        if context.durationSeconds < DayPilotConfiguration.probeSessionSeconds {
            return true
        }
        if context.eventCount <= DayPilotConfiguration.probeSessionMaxEvents,
           context.durationSeconds < DayPilotConfiguration.probeSessionMaxEventsWindow {
            return true
        }
        return false
    }

    /// Attaches the coordinator to a session that already exists.
    ///
    /// DayPilot can be quit mid-session, and a session whose events are already
    /// in SQLite must still be closeable — otherwise the last session before a
    /// crash could never be debriefed. Also used to run the debrief pipeline
    /// over a session recorded out of process.
    ///
    /// - Parameters:
    ///   - sessionId: The existing session identifier.
    ///   - startedAt: When the session began.
    ///   - eventCount: Events already recorded for it.
    func attachToSession(
        sessionId: String,
        startedAt: Date,
        eventCount: Int = 0,
        breadcrumbCount: Int = 0,
        suppressedFrameCount: Int = 0
    ) throws {
        guard state == .idle else { throw SessionCoordinatorError.sessionAlreadyActive }

        currentSessionId = sessionId
        sessionStartedAt = startedAt
        pausedAccumulatedSeconds = 0
        pauseStartedAt = nil
        self.recordedEventCount = eventCount
        self.breadcrumbCount = breadcrumbCount
        self.suppressedFrameCount = suppressedFrameCount
        transition(to: .capturing)

        logger.notice("Attached to existing session \(sessionId, privacy: .public)")
    }

    /// Elapsed work time of the current session, in seconds: wall clock minus
    /// every paused stretch. It holds steady while paused and never jumps
    /// forward on resume, so the console timer behaves like a stopwatch.
    var sessionElapsedSeconds: TimeInterval {
        guard let start = sessionStartedAt else { return 0 }
        var elapsed = Date().timeIntervalSince(start) - pausedAccumulatedSeconds
        if let pauseStart = pauseStartedAt {
            elapsed -= Date().timeIntervalSince(pauseStart)
        }
        return max(0, elapsed)
    }

    // MARK: - Synthesis

    /// Assembles the prompt and calls the provider.
    ///
    /// Runs off the main actor for the network call only: the memory store and
    /// the profile export are main-actor, so the client itself is built here
    /// and dispatched.
    private func synthesise(context: SessionCompletionContext) async throws -> SynthesisOutcome {

        let apiClient = try APIClient.resolve(from: skillConfiguration)

        let events = await sessionStore.fetchSessionPayload(sessionId: context.sessionId)

        // `exportContextForPrompt` is main-actor but synchronous; calling it
        // here (already on the main actor) needs no hop.
        let memoryContext = userMemory.exportContextForPrompt()
        let systemPrompt = PromptBuilder.systemPrompt(
            memoryContext: memoryContext,
            voiceScriptStartTag: skillConfiguration.audio.voiceScriptStartTag,
            voiceScriptEndTag: skillConfiguration.audio.voiceScriptEndTag
        )

        let (payload, pruning) = PromptBuilder.userPayload(events: events, context: context)
        let promptMessage =
            "Prompt assembled — \(pruning.eventsRead) events read, \(pruning.eventsMerged) merged, "
            + "\(pruning.eventsPrunedLowDwell) pruned, \(pruning.payloadCharacters) characters"
        logger.plain(promptMessage)

        guard events.contains(where: { !$0.extractedTextDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SynthesisError.noCapturedContent
        }

        let startedAt = Date()
        let result = try await apiClient.generateDebrief(
            systemPrompt: systemPrompt,
            userPayload: payload
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        // The prompt forbids slop; this pass guarantees it. Emoji, canned
        // phrases, empty sections, and any artifact not present in the payload
        // are removed before the brief is ever shown or archived.
        let reportMarkdown = BriefSanitizer.sanitize(
            reportMarkdown: result.reportMarkdown,
            payloadCorpus: payload,
            date: context.stoppedAt
        )
        let generatedMessage =
            "Debrief generated by \(apiClient.provider.provider.displayName) "
            + "in \(String(format: "%.1f", elapsed))s"
        logger.plain(generatedMessage)

        return SynthesisOutcome(
            reportMarkdown: reportMarkdown,
            voiceScript: result.voiceScript,
            providerLabel: apiClient.provider.provider.label,
            model: apiClient.effectiveModel,
            temperature: apiClient.provider.provider.temperature,
            promptCharacters: payload.count,
            rulesHarvested: []
        )
    }

    // MARK: - Frame handling

    private func handleFrame(_ frame: ScreenFrame) {
        guard state == .capturing else { return }

        deliveryState.update { $0.framesDelivered += 1 }

        // The Accessibility snapshot is the authority on what is frontmost.
        // Taking it here (rather than trusting the last activation
        // notification) means a window that changed title in place is still
        // classified correctly.
        guard let surface = windowManager.frontmostSurface() else { return }

        captureEngine.setSuppressed(surface.isSuppressed)

        guard !surface.isSuppressed else {
            suppressedFrameCount += 1
            logger.info(
                "Frame dropped — \(surface.suppressionReason ?? "sensitive surface", privacy: .public)"
            )
            return
        }

        // Hand the frame to the OCR actor. Vision is the long pole, so it runs
        // off the main actor; the actor serialises it, and results come back
        // here to be stored on the main actor.
        Task { [textExtractor] in
            let result: TextExtractionResult
            do {
                result = try await textExtractor.extractText(from: frame.image)
            } catch {
                return
            }
            await self.store(
                surface: surface,
                frame: frame,
                extraction: result
            )
        }
    }

    @MainActor
    private func store(
        surface: WindowManager.FocusedSurface,
        frame: ScreenFrame,
        extraction: TextExtractionResult
    ) async {
        guard state == .capturing, let sessionId = currentSessionId else { return }

        let delta = extraction.textDelta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !delta.isEmpty else {
            // Vision read the screen but nothing new appeared. Storing this
            // would fill the database with duplicates.
            return
        }

        // ---- Laya System 1 Decision Engine --------------------------------
        // Fast typed decisions (~33ms) before the event reaches the cloud LLM.
        let state = "Active app: \(surface.appName), Window: \(surface.windowTitle), OCR text: \(String(delta.prefix(500)))"
        let decision = await decisionEngine.decide(state: state)

        if let decision {
            // Drop idle/social/system frames
            guard decision.isMeaningfulWork else {
                logger.info("Laya dropped frame — not meaningful work (prob: \(String(format: "%.2f", decision.meaningfulProbability)))")
                return
            }

            // Purge secrets — never reach cloud LLM
            guard decision.dataSensitivity != "secrets" else {
                logger.warning("Laya PURGED frame — secrets detected (score: \(String(format: "%.2f", decision.sensitivityScore)))")
                return
            }

            // Flag discarded insights
            if decision.isDiscardedInsight {
                logger.notice("Laya flagged discarded insight (prob: \(String(format: "%.2f", decision.insightProbability)))")
            }

            // Route routine_admin to compact counters
            if decision.workCategory == "routine_admin" {
                logger.info("Laya routed to compact counter — routine_admin")
                // Still record, but mark as routine
            }
        }

        guard recordedEventCount < DayPilotConfiguration.maxStoredEventsPerSession else {
            if recordedEventCount == DayPilotConfiguration.maxStoredEventsPerSession {
                logger.notice("Session reached the \(DayPilotConfiguration.maxStoredEventsPerSession)-event cap")
            }
            return
        }

        let event = SessionEvent(
            id: UUID().uuidString,
            sessionId: sessionId,
            timestamp: eventTimestampFormatter.string(from: Date()),
            appName: surface.appName,
            bundleId: surface.bundleIdentifier,
            windowTitle: surface.windowTitle,
            isEphemeral: surface.ephemeral.isEphemeral,
            extractedTextDelta: delta
        )

        do {
            try await sessionStore.recordEvent(event)
        } catch {
            logger.error("Could not record event: \(error.localizedDescription, privacy: .public)")
            return
        }

        recordedEventCount += 1
        if surface.ephemeral.isEphemeral {
            breadcrumbCount += 1
        }

        let summary = CaptureEventSummary(
            appName: surface.appName,
            bundleIdentifier: surface.bundleIdentifier,
            windowTitle: surface.windowTitle,
            isEphemeral: surface.ephemeral.isEphemeral,
            category: surface.ephemeral.category,
            textDelta: delta,
            frameDelta: frame.frameDelta,
            recognitionDuration: extraction.recognitionDuration,
            eventIndex: recordedEventCount
        )

        let eventMessage =
            "Event \(recordedEventCount) captured — \(surface.bundleIdentifier), "
            + "\(surface.ephemeral.category), \(delta.count) characters of new text"
        logger.plain(eventMessage)
        onEvent?(summary)
    }

    // MARK: - Suppression

    /// Arms the privacy shield when the app is switched, not just when a frame
    /// arrives, so the flag is correct before the next sample even happens.
    private func installActivationObserver() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let surface = self.windowManager.frontmostSurface() {
                    self.captureEngine.setSuppressed(surface.isSuppressed)
                    if surface.isSuppressed {
                        self.suppressedFrameCount += 1
                    }
                }
            }
        }
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    private static func isFrontmostSurfaceSuppressed(windowManager: WindowManager) -> Bool {
        windowManager.frontmostSurface()?.isSuppressed ?? false
    }

    // MARK: - Watchdog

    /// A timer on a dedicated `.utility` queue.
    ///
    /// It never touches the main thread and never does capture work; it only
    /// notices when frames stop arriving, which is how a revoked permission or
    /// a sleeping display gets surfaced instead of silently producing nothing
    /// for hours.
    private func startWatchdog() {
        let intervalSeconds = max(5, Int(DayPilotConfiguration.captureIntervalSeconds))
        let deliveryState = self.deliveryState

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.daypilot.session.watchdog", qos: .utility)
        )
        timer.schedule(deadline: .now() + .seconds(intervalSeconds), repeating: .seconds(intervalSeconds))
        timer.setEventHandler {
            let snapshot = deliveryState.value
            Task { @MainActor [weak self] in
                self?.handleWatchdogTick(snapshot)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        lastObservedDeliveredFrames = 0
        stalledIntervals = 0
    }

    private func handleWatchdogTick(_ state: WatchdogState) {
        guard self.state == .capturing else { return }

        if state.framesDelivered == lastObservedDeliveredFrames {
            stalledIntervals += 1
            logger.notice(
                "No frames arrived in the last interval — display asleep, session locked, or permission revoked"
            )
            if stalledIntervals >= 4 {
                onCaptureFailure?("DayPilot has not received a frame for \(stalledIntervals) intervals.")
            }
        } else {
            stalledIntervals = 0
        }
        lastObservedDeliveredFrames = state.framesDelivered
    }

    private func handleCaptureFailure(_ message: String) {
        logger.error("\(message, privacy: .public)")
        onCaptureFailure?(message)
    }

    // MARK: - State

    private func transition(to newState: TrackingState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}

/// Failures specific to producing a debrief.
enum SynthesisError: LocalizedError {
    case sessionTooShort(Int)
    case noCapturedContent

    var errorDescription: String? {
        switch self {
        case .sessionTooShort(let seconds):
            "The session lasted only \(seconds)s, which is too short to debrief."
        case .noCapturedContent:
            "The session captured no readable on-screen text."
        }
    }
}
