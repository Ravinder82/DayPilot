import AppKit
import CoreGraphics
import Foundation
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

/// Screen Recording permission, requested through TCC.
///
/// Kept out of `ScreenCaptureEngine` so the engine never has to reason about
/// permission state — it simply starts, and the coordinator has already made
/// sure the user has been asked.
enum ScreenRecordingPermission {

    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt if permission has not been granted.
    @discardableResult
    static func request() -> Bool {
        guard !isGranted() else { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Prompts if needed, then waits a bounded time for the user to answer.
    ///
    /// The TCC dialog does not resolve synchronously, and a user who has just
    /// clicked "Allow" needs a moment before the kernel records the grant, so
    /// this polls rather than trusting an immediate return value.
    static func awaitGrant(timeout: TimeInterval) async -> Bool {
        if isGranted() { return true }
        _ = request()

        let clock = ContinuousClock.now
        let deadline = clock + .seconds(timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(0.4))
            if isGranted() { return true }
        }
        return isGranted()
    }
}

enum SessionCoordinatorError: LocalizedError {
    case sessionAlreadyActive
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            "A workday session is already running."
        case .screenRecordingDenied:
            """
            Screen Recording permission was not granted. DayPilot cannot sample the screen \
            without it — grant it in System Settings > Privacy & Security > Screen Recording.
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
        case synthesising
        case speaking
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
    private let voiceEngine: VoicePlaybackEngine
    private let skillConfiguration: SkillConfiguration

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

    /// The debrief from the most recent session, so the status bar can show it
    /// or open it after the fact.
    private(set) var lastCompletion: SessionCompletion?

    /// Called on the main actor for every stored event.
    var onEvent: (@MainActor (CaptureEventSummary) -> Void)?

    /// Called on the main actor when capture has died under us.
    var onCaptureFailure: (@MainActor (String) -> Void)?

    /// Called on the main actor when the state machine changes state.
    var onStateChange: (@MainActor (TrackingState) -> Void)?

    /// Speaks a standalone line (used by the status bar's playback controls).
    func speak(_ text: String, autoStopAfter: TimeInterval? = nil) {
        voiceEngine.speak(text: text, autoStopAfter: autoStopAfter)
    }

    /// Stops any spoken brief in progress.
    func stopSpeaking() {
        voiceEngine.stop()
    }

    init(
        captureEngine: ScreenCaptureEngine,
        textExtractor: VisionTextExtractor,
        windowManager: WindowManager,
        sessionStore: SessionStore,
        userMemory: UserMemoryStore,
        skillConfiguration: SkillConfiguration? = nil,
        reportArchiver: ReportArchiver? = nil,
        voiceEngine: VoicePlaybackEngine? = nil
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
        self.voiceEngine = voiceEngine ?? VoicePlaybackEngine(configuration: loaded.audio)

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
        skillConfiguration: SkillConfiguration? = nil
    ) -> SessionCoordinator {
        SessionCoordinator(
            captureEngine: ScreenCaptureEngine(),
            textExtractor: VisionTextExtractor(),
            windowManager: WindowManager(),
            sessionStore: sessionStore,
            userMemory: userMemory,
            skillConfiguration: skillConfiguration
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

        _ = windowManager.requestAccessibilityPermissionIfNeeded()
        let granted = await ScreenRecordingPermission.awaitGrant(timeout: 12)
        guard granted else { throw SessionCoordinatorError.screenRecordingDenied }

        let sessionId = await sessionStore.startSession()
        currentSessionId = sessionId
        sessionStartedAt = Date()
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

    /// Stops the session and runs the whole end-of-day lifecycle.
    ///
    /// The lifecycle is: halt capture, collect the session's events, assemble
    /// the prompt from the user profile plus the pruned telemetry, call the
    /// configured provider, archive the report, fold the lessons back into
    /// `user_memory.json`, and speak the script.
    ///
    /// Stopping deliberately never throws. The captured data is already safe in
    /// SQLite, so a missing API key or a dead network must produce a report
    /// explaining what happened rather than losing the session.
    @discardableResult
    func stop() async -> SessionCompletion {
        guard state == .capturing, let sessionId = currentSessionId else {
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

        var failureReason: String?
        var outcome: SynthesisOutcome?

        do {
            outcome = try await synthesise(context: context)
        } catch {
            failureReason = error.localizedDescription
            logger.error("Synthesis failed: \(error.localizedDescription, privacy: .public)")
        }

        // ---- Archive and speak -------------------------------------------

        let archiveOutcome: ReportArchiver.ArchiveOutcome?
        if var outcome {
            let rules = RuleOfThumbHarvester.harvest(from: outcome.reportMarkdown)
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
        } else {
            let reason = failureReason ?? "Synthesis produced no report."
            archiveOutcome = await reportArchiver.recordFailedSession(
                failureReason: reason,
                context: context
            )
        }

        // ---- Speak ---------------------------------------------------------

        var spokenScript = ""
        if let outcome, !outcome.voiceScript.isEmpty {
            spokenScript = outcome.voiceScript
            transition(to: .speaking)
            voiceEngine.speak(text: outcome.voiceScript)
            logger.notice("Speaking the debrief")
        } else if failureReason != nil {
            logger.notice("No voice script available — skipping speech")
        } else {
            logger.notice("The model returned no script — nothing to speak")
        }

        transition(to: .idle)
        currentSessionId = nil

        let completion = SessionCompletion(
            sessionId: sessionId,
            eventCount: context.eventCount,
            durationSeconds: context.durationSeconds,
            breadcrumbCount: context.breadcrumbCount,
            reportMarkdown: outcome?.reportMarkdown ?? "",
            reportPath: archiveOutcome?.reportPath ?? "",
            voiceScript: spokenScript,
            rulesHarvested: archiveOutcome?.rulesHarvested ?? [],
            synthesisFailureReason: failureReason
        )
        lastCompletion = completion

        let message =
            "Session \(sessionId) closed — \(completion.eventCount) events, "
            + "\(completion.breadcrumbCount) breadcrumbs, "
            + "report \(completion.reportPath.isEmpty ? "not archived" : "archived")"
        logger.notice("\(message, privacy: .public)")

        return completion
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
        self.recordedEventCount = eventCount
        self.breadcrumbCount = breadcrumbCount
        self.suppressedFrameCount = suppressedFrameCount
        transition(to: .capturing)

        logger.notice("Attached to existing session \(sessionId, privacy: .public)")
    }

    /// Elapsed wall-clock time of the current session, in seconds.
    var sessionElapsedSeconds: TimeInterval {
        guard let start = sessionStartedAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    /// The voice engine, exposed so the status bar can stop playback.
    var speech: VoicePlaybackEngine { voiceEngine }

    // MARK: - Synthesis

    /// Assembles the prompt and calls the provider.
    ///
    /// Runs off the main actor for the network call only: the memory store and
    /// the profile export are main-actor, so the client itself is built here
    /// and dispatched.
    private func synthesise(context: SessionCompletionContext) async throws -> SynthesisOutcome {
        guard context.durationSeconds >= TimeInterval(DayPilotConfiguration.minimumSessionSecondsForSynthesis) else {
            throw SynthesisError.sessionTooShort(Int(context.durationSeconds))
        }

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
        let generatedMessage =
            "Debrief generated by \(apiClient.provider.provider.displayName) "
            + "in \(String(format: "%.1f", elapsed))s"
        logger.plain(generatedMessage)

        return SynthesisOutcome(
            reportMarkdown: result.reportMarkdown,
            voiceScript: result.voiceScript,
            providerLabel: apiClient.provider.provider.label,
            model: apiClient.provider.provider.model,
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
