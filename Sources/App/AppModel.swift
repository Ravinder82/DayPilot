import AppKit
import Foundation
import os
import SwiftUI

/// The single observable state the whole UI renders from.
///
/// It owns the real subsystems (capture, OCR, SQLite, memory, voice, the model
/// catalogue) rather than mirroring them, because a mirrored copy is a second
/// source of truth that goes stale. It is `@MainActor`, and every heavy operation
/// is handed to an actor, a private queue or a cooperative task, so the UI never
/// waits on capture, recognition, storage or the network.
@MainActor
final class AppModel: ObservableObject {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "appmodel")

    // MARK: - Lifecycle

    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .starting

    /// True once `activateOnce()` has run, so a re-appearing window cannot boot
    /// DayPilot a second time.
    private(set) var hasActivated = false

    // MARK: - Session

    enum SessionState: Equatable {
        case idle
        case capturing
        case paused
        case synthesising
    }

    @Published private(set) var sessionState: SessionState = .idle
    /// True when DayPilot's own screen-recording sheet should be visible.
    /// Set when a Start attempt finds the grant missing; showing it never
    /// raises a system dialog.
    @Published var needsScreenRecordingPermission = false
    @Published private(set) var sessionElapsedSeconds: TimeInterval = 0
    @Published private(set) var eventCount = 0
    @Published private(set) var breadcrumbCount = 0
    @Published private(set) var lastCompletion: SessionCompletion?

    /// Why the most recent start did not begin. A synthesis failure belongs to one
    /// session, so it is carried by `lastCompletion` instead.
    @Published private(set) var lastFailureReason: String?

    // MARK: - Latest debrief

    @Published private(set) var latestReportPath = ""
    @Published private(set) var latestReportMarkdown = ""

    // MARK: - Library and editor

    @Published private(set) var storedSessions: [StoredSession] = []
    @Published private(set) var storedSessionsMessage = ""

    /// Sessions the user starred as best working days, keyed by session id.
    @Published private(set) var starredSessionIDs: Set<String> = []

    /// The session selected in the sidebar. `nil` shows the newest debrief.
    @Published var selectedSessionID: String?

    /// The Markdown on screen. Edits write through to the archived file a moment
    /// after typing stops, so nothing lives only in memory.
    @Published var reportBody = "" {
        didSet {
            guard reportBody != oldValue, !isLoadingReport else { return }
            scheduleReportWrite()
        }
    }

    /// Rendered by default. The source view is the same text as Markdown.
    @Published var isEditingSource = false

    /// Set when an edit could not be written, so the editor can say so.
    @Published private(set) var reportWriteError: String?

    /// Path of the report on screen. Empty for previews, which are read-only.
    private(set) var currentReportPath = ""

    private var isLoadingReport = false
    private var pendingReportWrite: (markdown: String, path: String)?
    private var reportWriteTask: Task<Void, Never>?

    // MARK: - Model catalogue

    @Published private(set) var modelsByProvider: [String: [AIModel]] = [:]
    @Published private(set) var loadingProviderIDs: Set<String> = []

    // MARK: - Custom providers

    @Published private(set) var customProfiles: [CustomProviderProfile] = CustomProviderStore.profiles()

    // MARK: - Configuration and subsystems

    let settings: AppSettings
    let skillConfiguration: SkillConfiguration
    private let skillSource: SkillConfigurationLoader.Source
    private let injectedSessionStore: SessionStore?
    private let injectedUserMemory: UserMemoryStore?

    /// One SQLite connection for the process, shared by the coordinator and the
    /// library. A second connection to the same file would only add contention.
    private var sessionStore: SessionStore?
    private var coordinator: SessionCoordinator?
    private var fileManagerStore: FileManagerStore?
    let decisionEngine: DecisionEngineService

    init(
        settings: AppSettings = AppSettings(),
        sessionStore: SessionStore? = nil,
        userMemoryStore: UserMemoryStore? = nil
    ) {
        self.settings = settings
        self.decisionEngine = DecisionEngineService()
        let loaded = SkillConfigurationLoader.load()
        skillConfiguration = loaded.configuration
        skillSource = loaded.source

        // Injected stores exist so the integration test can seed a sandbox that
        // the debrief pipeline then reads from. Otherwise the test would write to
        // one database and synthesise from another.
        injectedSessionStore = sessionStore
        injectedUserMemory = userMemoryStore

        // Fixture content is set before any view observes the model, so no later
        // selection change can replace it with a disk lookup.
        if LaunchHarness.usesPreviewFixtures {
            showPreview(markdown: PreviewFixtures.debrief, sessions: PreviewFixtures.sessions)
        }

        // Window snapshots depict the app mid-session. Starting a real session
        // there would need permissions and hardware, so the display state is set
        // directly; nothing is captured and nothing touches the Keychain.
        if LaunchHarness.snapshotDirectory != nil {
            sessionState = .capturing
            sessionElapsedSeconds = 3_862
            eventCount = 47
            breadcrumbCount = 9
        }
    }

    // MARK: - Derived state

    var configurationSourceDescription: String { skillSource.description }

    /// Every provider the user can choose: the configured ones, then custom ones.
    var allProviders: [SkillConfiguration.AIProvider] {
        skillConfiguration.allProviders(customProfiles: customProfiles)
    }

    /// Editing writes to disk only when there is a real file behind the report.
    var reportBodyIsEditable: Bool { !currentReportPath.isEmpty }

    var canToggleWorkday: Bool {
        switch sessionState {
        case .idle, .capturing, .paused: return true
        case .synthesising: return false
        }
    }

    var elapsedClockText: String {
        elapsedText(seconds: Int(sessionElapsedSeconds.rounded(.down)))
    }

    var selectedSession: StoredSession? {
        guard let id = selectedSessionID else { return nil }
        return storedSessions.first { $0.id == id }
    }

    var detailTitle: String {
        if let session = selectedSession { return session.displayTitle }
        return sessionState == .idle ? "Debrief" : "Live session"
    }

    var detailSubtitle: String {
        if let session = selectedSession {
            var parts: [String] = []
            if let duration = session.durationText { parts.append(duration) }
            parts.append("\(session.eventCount) events")
            if session.breadcrumbCount > 0 { parts.append("\(session.breadcrumbCount) rescued") }
            return parts.joined(separator: " · ")
        }
        return lastFailureReason ?? "Stop a session to write its debrief."
    }

    var emptyStateTitle: String {
        selectedSessionID == nil ? "No debrief yet" : "No debrief for this session"
    }

    var emptyStateMessage: String {
        if let reason = lastCompletion?.synthesisFailureReason, selectedSessionID == lastCompletion?.sessionId {
            return reason
        }
        if selectedSession != nil {
            return "This session ended without a saved debrief."
        }
        if let reason = lastFailureReason { return reason }
        if storedSessions.isEmpty {
            return "Start a workday, then stop it. DayPilot writes the debrief here and keeps a copy on disk."
        }
        return "Choose a session in the sidebar to read its debrief."
    }

    /// True when at least one provider has a key, in the Keychain or the
    /// environment. Drives the call to connect a provider from an empty editor.
    var hasAnyProviderKey: Bool {
        if !KeychainManager.storedProviders().isEmpty { return true }
        let environment = ProcessInfo.processInfo.environment
        return allProviders.contains { provider in
            !provider.apiKeyEnvironmentVariable.isEmpty
                && !(environment[provider.apiKeyEnvironmentVariable] ?? "").isEmpty
        }
    }

    // MARK: - File Manager

    var fileManager: FileManagerStore? { fileManagerStore }

    // MARK: - Starred days

    private let starsDefaultsKey = "session.stars.v1"

    func isStarred(_ sessionID: String) -> Bool {
        starredSessionIDs.contains(sessionID)
    }

    /// Stars/unstars a session as a best working day. Persisted in user
    /// defaults keyed by session id, so marks survive report edits.
    func toggleStar(_ sessionID: String) {
        if starredSessionIDs.contains(sessionID) {
            starredSessionIDs.remove(sessionID)
        } else {
            starredSessionIDs.insert(sessionID)
        }
        UserDefaults.standard.set(Array(starredSessionIDs), forKey: starsDefaultsKey)
    }

    // MARK: - Laya Decision Engine

    var tokensSavedByLaya: Int { decisionEngine.totalTokensSaved }
    var framesProcessedByLaya: Int { decisionEngine.totalFramesProcessed }
    var framesDroppedByLaya: Int { decisionEngine.totalFramesDropped }
    var framesPurgedByLaya: Int { decisionEngine.totalFramesPurged }
    var layaLastLatencyMs: Double { decisionEngine.lastLatencyMs }
    var layaAvailable: Bool { decisionEngine.isAvailable }

    // MARK: - Lifecycle and boot

    /// Boots DayPilot once, from the window's first appearance.
    ///
    /// The window is the earliest point at which the `@StateObject` backing this
    /// model is installed. Activating from `App.init()` would create a second,
    /// unreferenced instance and boot subsystems the UI never rendered.
    func activateOnce() {
        guard !hasActivated else { return }
        hasActivated = true

        // Fixture runs only show the window, and command-line runs drive a sandboxed
        // model of their own. Booting the real one beside either would start a live
        // capture of the user's screen. Window snapshots are the same case: they
        // depict the app's UI against a throwaway HOME, where the real subsystems
        // have nothing to capture and would only ask for permissions.
        guard !LaunchHarness.usesPreviewFixtures,
              !LaunchHarness.isCommandLineToolRun,
              LaunchHarness.snapshotDirectory == nil else { return }

        Task { @MainActor in
            if let failure = await startAsync() {
                logger.error("Startup failed: \(failure, privacy: .public)")
                return
            }

            // The window asks for the library as soon as it appears, which is before
            // boot has finished, so that first request is ignored. Ask again now.
            await refreshLibrary()

            guard LaunchHarness.shouldRunLaunchCaptureCycle() else { return }
            logger.notice("Unbundled launch — running the launch capture smoke test")
            await runLaunchCaptureCycle(seconds: LaunchHarness.captureCycleSeconds)
        }
    }

    /// Boots the subsystems and reports whether that succeeded.
    ///
    /// The bootable variant is named `startAsync` because the `ObservableObject`
    /// contract and the harness both need to await it and inspect the outcome.
    func startAsync() async -> String? {
        guard phase == .starting else {
            if phase.isReady { return nil }
            if case .failed(let message) = phase { return message }
            return "DayPilot is not ready."
        }
        return await boot()
    }

    private func boot() async -> String? {
        do {
            let memoryStore: UserMemoryStore
            if let injectedUserMemory {
                memoryStore = injectedUserMemory
            } else {
                memoryStore = try UserMemoryStore()
            }
            _ = await memoryStore.loadMemory()

            let store: SessionStore
            if let injectedSessionStore {
                store = injectedSessionStore
            } else {
                store = try await SessionStore.open()
            }
            sessionStore = store

            let coordinator = SessionCoordinator.makeDefault(
                sessionStore: store,
                userMemory: memoryStore,
                skillConfiguration: skillConfiguration,
                decisionEngine: decisionEngine
            )
            coordinator.onEvent = { [weak self] summary in
                self?.eventCount = summary.eventIndex
                self?.breadcrumbCount += summary.isEphemeral ? 1 : 0
            }
            coordinator.onStateChange = { [weak self] state in
                self?.applySessionState(state)
            }

            self.coordinator = coordinator

            // Initialize file manager store
            fileManagerStore = FileManagerStore()

            // Restore starred best-working-day marks.
            starredSessionIDs = Set(UserDefaults.standard.stringArray(forKey: starsDefaultsKey) ?? [])

            // Load API key into memory once
            AppConfiguration.shared.load()

            phase = .ready
            logger.notice("DayPilot ready — \(self.skillSource.description, privacy: .public)")
            return nil
        } catch {
            let message = error.localizedDescription
            phase = .failed(message)
            logger.error("Startup failed: \(message, privacy: .public)")
            return message
        }
    }

    // MARK: - Session control

    /// Starts a workday session. Returns `nil` on success, or why it could not start.
    @discardableResult
    func startWorkday() async -> String? {
        guard phase.isReady, let coordinator else {
            let reason = "DayPilot is not ready yet."
            lastFailureReason = reason
            return reason
        }
        eventCount = 0
        breadcrumbCount = 0
        lastFailureReason = nil

        do {
            try await coordinator.start()
            MascotSession.shared.setMood(.working)
            return nil
        } catch {
            // Missing Screen Recording is the one failure with a guided fix:
            // surface DayPilot's own sheet instead of macOS's consent popup.
            if (error as? SessionCoordinatorError) == .screenRecordingDenied {
                needsScreenRecordingPermission = true
            }
            lastFailureReason = error.localizedDescription
            logger.error("Could not start the session: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    /// "Check Again" in DayPilot's screen-recording sheet. The user explicitly
    /// asked for a verification, so a stale preflight may be settled with the
    /// live probe; on success the sheet closes and the session starts.
    @discardableResult
    func recheckScreenRecordingPermission() async -> Bool {
        var granted = ScreenRecordingPermission.isGranted()
        if !granted {
            granted = await ScreenRecordingPermission.confirmWithLiveProbe()
        }
        guard granted else { return false }
        needsScreenRecordingPermission = false
        _ = await startWorkday()
        return true
    }

    /// Dismisses the screen-recording sheet without starting a session.
    func dismissScreenRecordingSheet() {
        needsScreenRecordingPermission = false
    }

    /// Stops the session and returns what it produced.
    ///
    /// Never throws and never returns nil: a stopped session always yields a
    /// completion, even when the debrief failed, so the caller can show something
    /// true. The new debrief is selected and opened as soon as it is archived.
    func stopWorkday() async -> SessionCompletion {
        guard phase.isReady, let coordinator else {
            let failure = SessionCompletion(
                sessionId: "",
                eventCount: eventCount,
                durationSeconds: 0,
                breadcrumbCount: breadcrumbCount,
                reportMarkdown: "",
                reportPath: "",
                voiceScript: "",
                rulesHarvested: [],
                synthesisFailureReason: lastFailureReason ?? "DayPilot is not ready yet."
            )
            lastCompletion = failure
            return failure
        }

        let completion = await coordinator.stop()
        MascotSession.shared.setMood(.think)

        lastCompletion = completion
        latestReportPath = completion.reportPath
        latestReportMarkdown = completion.reportMarkdown
        lastFailureReason = nil

        if !completion.sessionId.isEmpty {
            selectedSessionID = completion.sessionId
        }
        await refreshLibrary()

        return completion
    }

    /// Runs the launch capture cycle on this model.
    func runLaunchCaptureCycle(seconds: Int) async {
        guard phase.isReady else { return }

        if let failure = await startWorkday() {
            logger.notice("Launch capture cycle skipped: \(failure, privacy: .public)")
            return
        }

        let interval = max(1, Int(settings.captureIntervalSeconds))
        var remaining = seconds
        while remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            remaining -= interval
        }
        _ = await stopWorkday()
    }

    func toggleWorkday() async {
        switch sessionState {
        case .idle:
            await startWorkday()
        case .capturing:
            _ = await stopWorkday()
        case .paused:
            _ = await stopWorkday()
        case .synthesising:
            break
        }
    }

    func pauseWorkday() async {
        guard sessionState == .capturing, let coordinator else { return }
        MascotSession.shared.setMood(.idle)
        await coordinator.pause()
    }

    func resumeWorkday() async {
        guard sessionState == .paused, let coordinator else { return }
        MascotSession.shared.setMood(.working)
        await coordinator.resume()
    }

    private func applySessionState(_ state: SessionCoordinator.TrackingState) {
        switch state {
        case .idle:
            sessionState = .idle
            sessionElapsedSeconds = 0
        case .capturing:
            sessionState = .capturing
        case .paused:
            sessionState = .paused
        case .synthesising:
            sessionState = .synthesising
        }
    }

    /// Refreshes the elapsed counter. Driven by a one-second timer in whichever
    /// window is showing the time, so the value is a stored property that
    /// `@Published` can announce. During synthesis the last value stays frozen;
    /// when the session ends, the counter resets.
    func refreshElapsed() {
        guard sessionState == .capturing || sessionState == .paused,
              let coordinator else { return }
        sessionElapsedSeconds = coordinator.sessionElapsedSeconds
    }

    /// `HH:MM:SS`.
    func elapsedText(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remaining)
    }

    // MARK: - Library and report editing

    /// Reloads the session list from SQLite. Selects the newest session when
    /// nothing is selected, so the editor always opens on a real debrief.
    func refreshLibrary() async {
        guard phase.isReady, let store = sessionStore else { return }
        let stored = await store.allSessions()

        // A session that captured nothing has no events to list, yet it still leaves
        // a debrief on disk. That debrief has to be reachable from the library.
        let storedIDs = Set(stored.map(\.id))
        let archivedOnly = ReportLibrary.archivedSessions().filter { !storedIDs.contains($0.id) }
        let sessions = (stored + archivedOnly).sorted { $0.id > $1.id }
        storedSessions = sessions
        storedSessionsMessage = sessions.isEmpty
            ? "Sessions appear here once you stop one."
            : ""

        if let selected = selectedSessionID, !sessions.contains(where: { $0.id == selected }) {
            selectedSessionID = nil
        }
        if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        }
        await loadSelectedReport()
    }

    /// Loads the report for the current selection into the editor.
    ///
    /// Any edit still waiting for its pause is written first, so switching
    /// sessions can never drop text the user just typed.
    func loadSelectedReport() async {
        flushPendingReportWrite()

        guard let session = selectedSession else {
            setReportBody(latestReportMarkdown, path: latestReportPath)
            return
        }

        if let loaded = ReportLibrary.load(sessionId: session.id) {
            setReportBody(loaded.text, path: loaded.path)
        } else {
            setReportBody("", path: "")
        }
    }

    /// Shows fixture content in the editor, for offline rendering. Previews have
    /// no file path, so nothing typed into them can be written anywhere.
    func showPreview(markdown: String, sessions: [StoredSession]) {
        storedSessions = sessions
        selectedSessionID = sessions.first?.id
        setReportBody(markdown, path: "")
        fileManagerStore = FileManagerStore()
    }

    private func setReportBody(_ text: String, path: String) {
        isLoadingReport = true
        reportBody = text
        isLoadingReport = false
        currentReportPath = path
    }

    /// Writes an edit a moment after typing pauses. Each keystroke cancels the
    /// previous wait, so a burst of typing produces one write, not dozens.
    private func scheduleReportWrite() {
        guard reportBodyIsEditable else { return }
        pendingReportWrite = (reportBody, currentReportPath)
        reportWriteTask?.cancel()
        reportWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushPendingReportWrite()
        }
    }

    /// Writes the pending edit now, if there is one.
    func flushPendingReportWrite() {
        reportWriteTask?.cancel()
        reportWriteTask = nil
        guard let pending = pendingReportWrite else { return }
        pendingReportWrite = nil
        do {
            try ReportLibrary.save(markdown: pending.markdown, path: pending.path)
        } catch {
            reportWriteError = error.localizedDescription
        }
    }

    func clearReportWriteError() {
        reportWriteError = nil
    }

    func revealLatestReport() {
        let path = currentReportPath.isEmpty ? latestReportPath : currentReportPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Report CRUD

    /// Creates a new empty report and selects it.
    ///
    /// One report, one file. The brief a session writes fills it in; there is
    /// no template to pick from first.
    func createNewReport() async {
        flushPendingReportWrite()
        let (sessionId, path, markdown) = ReportLibrary.createNew()
        selectedSessionID = sessionId
        setReportBody(markdown, path: path)
        await refreshLibrary()
    }

    /// Deletes the currently selected report.
    func deleteSelectedReport() async {
        guard let session = selectedSession else { return }
        flushPendingReportWrite()
        try? ReportLibrary.delete(sessionId: session.id)
        selectedSessionID = nil
        await refreshLibrary()
    }

    /// Exports the currently selected report.
    func exportSelectedReport(to url: URL, as format: ExportFormat) {
        guard let session = selectedSession else { return }
        try? ReportLibrary.export(sessionId: session.id, to: url, as: format)
    }

    // MARK: - Providers and models

    /// Models for a provider, loaded on demand and cached in memory.
    func availableModels(for provider: SkillConfiguration.AIProvider) -> [AIModel] {
        modelsByProvider[provider.id] ?? []
    }

    func areModelsLoading(for providerID: String) -> Bool {
        loadingProviderIDs.contains(providerID)
    }

    /// Loads a provider's models, unless they are already loaded and `force` is off.
    func loadModels(for provider: SkillConfiguration.AIProvider, force: Bool = false) async {
        guard force || modelsByProvider[provider.id] == nil else { return }
        guard !loadingProviderIDs.contains(provider.id) else { return }

        loadingProviderIDs.insert(provider.id)
        defer { loadingProviderIDs.remove(provider.id) }

        modelsByProvider[provider.id] = await ModelCatalog.models(for: provider)
    }

    func selectProvider(_ id: String) {
        settings.preferredProviderID = id
        if let key = KeychainManager.getKey(for: id), !key.isEmpty {
            AppConfiguration.shared.update(providerID: id, key: key)
        }
    }

    func addCustomProvider(label: String, baseURL: String) throws -> CustomProviderProfile {
        let profile = try CustomProviderStore.add(label: label, baseURL: baseURL)
        customProfiles = CustomProviderStore.profiles()
        return profile
    }

    func updateCustomProvider(
        _ existing: CustomProviderProfile,
        label: String,
        baseURL: String
    ) throws -> CustomProviderProfile {
        let updated = try CustomProviderStore.update(existing, label: label, baseURL: baseURL)
        customProfiles = CustomProviderStore.profiles()
        // A new endpoint has a different catalogue, so the cached list is stale.
        modelsByProvider[updated.id] = nil
        return updated
    }

    /// Removes a custom provider together with everything stored for it: its key,
    /// its chosen model, and its cached catalogue.
    func removeCustomProvider(_ profile: CustomProviderProfile) {
        CustomProviderStore.remove(id: profile.id)
        KeychainManager.deleteKey(for: profile.id)
        settings.clearModel(forProvider: profile.id)
        if settings.preferredProviderID == profile.id {
            settings.preferredProviderID = ""
        }
        customProfiles = CustomProviderStore.profiles()
        modelsByProvider[profile.id] = nil
    }

    // MARK: - Verification support

    /// Re-reads the profile from disk, so the integration test proves what was
    /// written rather than what in-memory state claims.
    func loadProfile() async -> UserMemoryProfile {
        _ = await injectedUserMemory?.loadMemory()
        return injectedUserMemory?.current ?? UserMemoryProfile.seed
    }

    /// Attaches the coordinator to a session whose events are already stored, so
    /// the integration test runs the real end-of-day lifecycle over seeded data.
    func attachForVerification(
        sessionId: String,
        startedAt: Date,
        eventCount: Int
    ) async throws {
        guard phase.isReady else { throw LaunchHarnessError.notReady }

        let coordinator = try await makeCoordinatorIfNeeded()
        try coordinator.attachToSession(
            sessionId: sessionId,
            startedAt: startedAt,
            eventCount: eventCount
        )
        self.coordinator = coordinator
    }

    /// Creates the coordinator on demand for the harness. The window path always
    /// boots through `startAsync`, so this only runs in the CLI modes.
    private func makeCoordinatorIfNeeded() async throws -> SessionCoordinator {
        if let coordinator { return coordinator }

        let memoryStore = try UserMemoryStore()
        _ = await memoryStore.loadMemory()
        let store = try await SessionStore.open()
        sessionStore = store
        let coordinator = SessionCoordinator.makeDefault(
            sessionStore: store,
            userMemory: memoryStore,
            skillConfiguration: skillConfiguration
        )
        phase = .ready
        return coordinator
    }
}
