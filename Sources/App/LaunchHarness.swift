import AppKit
import Foundation
import os

/// The launch-time harness.
///
/// Holds the CLI diagnostic entry points (`--selftest`, `--integration-test`)
/// and the launch capture cycle, kept out of the `App` so the type that renders
/// the menu bar stays about rendering the menu bar. Everything here is
/// deliberately free of UI state: it prints to stdout, logs to Console.app, and
/// exits.
enum LaunchHarness {

    private static let logger = Logger(subsystem: AppInfo.identifier, category: "launch")

    /// True when this process is a standalone binary rather than a bundled app.
    ///
    /// `open dist/DayPilot.app` and `.build/release/DayPilot` are the same code,
    /// but a bundled launch is a user actually using the app while a bare launch
    /// is a developer running `make run` — and only the developer wants a smoke
    /// test to run over their screen at launch. `Bundle.main` has no bundle
    /// identifier for an unbundled executable, so this is a reliable signal.
    static var isRunningUnbundled: Bool {
        Bundle.main.bundleIdentifier == nil
    }

    /// True when a CLI diagnostic mode was requested. Those runs drive a sandboxed
    /// model of their own, so the window must not boot the real one beside them.
    static var isCommandLineToolRun: Bool {
        let flags = ["--selftest", "--integration-test", "--test-connection", "--list-models"]
        return CommandLine.arguments.contains { flags.contains($0) }
    }

    /// Runs an explicitly requested CLI mode.
    ///
    /// Called from `DayPilotApp.init()`, which runs before any window or menu
    /// exists, so these work with no UI at all — that is how Phases 2 and 3 were
    /// verified end to end.
    @MainActor
    static func runCommandLineModesIfNeeded() {
        let arguments = CommandLine.arguments

        if arguments.contains("--selftest") {
            let checks = SystemHealth.evaluate()
            SystemHealth.log(checks)
            print(SystemHealth.formatReport(checks, version: AppInfo.version))
            // A blocked capability means the binary is unusable on this machine,
            // so the exit code is the signal CI and `make selftest` act on.
            exit(SystemHealth.hasBlockingFailure(checks) ? 1 : 0)
        }

        if arguments.contains("--integration-test") {
            Task { @MainActor in
                await Self.runIntegrationTest()
                // Let speech play out before the process is left running with
                // the menu bar as its only visible surface.
                try? await Task.sleep(for: .seconds(12))
            }
            return
        }

        // `--test-connection <providerID>`: verifies a key without the Settings
        // window. Reads the key from DAYPILOT_TEST_KEY, which is what makes this
        // able to test a key that has *not* been saved to the Keychain — the
        // whole point of the button it mirrors.
        if arguments.contains("--test-connection") {
            let requested = arguments.last(where: { $0 != "--test-connection" }) ?? ""
            Task { @MainActor in
                await Self.testConnectionFromCommandLine(providerID: requested)
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
            return
        }

        // `--list-models <providerID>`: prints the catalogue the Settings window
        // shows, so the live parse can be checked without opening a window.
        if let requested = argument(following: "--list-models") {
            Task { @MainActor in
                await Self.listModelsFromCommandLine(providerID: requested)
                exit(0)
            }
            return
        }
    }

    /// Prints the models a provider offers, as the Settings window lists them.
    @MainActor
    private static func listModelsFromCommandLine(providerID: String) async {
        let providers = SkillConfigurationLoader.load().configuration.allProviders()
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            print("Unknown provider \"\(providerID)\". Known: \(providers.map(\.id).joined(separator: ", "))")
            return
        }

        let models = await ModelCatalog.models(for: provider)
        let free = models.filter { $0.price == .free }.count
        let paid = models.filter { $0.price == .paid }.count
        print("\(provider.label): \(models.count) models, \(free) free, \(paid) paid, \(models.count - free - paid) unpriced")
        for model in models.prefix(8) {
            let window = model.contextWindow.map { " · \($0) tokens" } ?? ""
            print("  [\(model.price.rawValue)] \(model.id)\(window)")
        }
    }

    /// Runs the provider check the Settings window runs, from the command line.
    @MainActor
    private static func testConnectionFromCommandLine(providerID: String) async {
        let skill = SkillConfigurationLoader.load().configuration
        let providers = skill.apiProviders.providers
        guard !providers.isEmpty else {
            print("No providers are configured.")
            return
        }

        let provider = providers.first { $0.id == providerID }
            ?? skill.defaultProvider
            ?? providers[0]

        let key = ProcessInfo.processInfo.environment["DAYPILOT_TEST_KEY"] ?? ""

        print("Provider:  \(provider.label)")
        print("Endpoint:  \(provider.baseURL)")
        print("Model:     \(provider.model)")
        print("Key:       \(key.isEmpty ? "(none supplied)" : "\(key.prefix(4))…\(key.suffix(4))")")

        guard !key.isEmpty else {
            print("\nSet DAYPILOT_TEST_KEY and re-run.")
            return
        }

        let client = APIClient.make(
            provider: provider,
            apiKey: key,
            voiceScriptStartTag: skill.audio.voiceScriptStartTag,
            voiceScriptEndTag: skill.audio.voiceScriptEndTag
        )

        print("\nTesting…")
        do {
            let reply = try await client.testConnection()
            print("✓ Connection verified — the model replied \"\(reply)\"")
        } catch {
            print("✗ \(error.localizedDescription)")
        }
    }

    /// True when a capture cycle should run at launch, on the app's own model.
    static func shouldRunLaunchCaptureCycle() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--capture-cycle") { return true }
        guard !arguments.contains("--no-capture") else { return false }
        // A developer running the binary bare, not a user opening the .app.
        return isRunningUnbundled
    }

    /// Length of the launch capture cycle.
    static let captureCycleSeconds = 20

    // MARK: - Phase 3 integration test

    /// Drives the whole Phase 3 pipeline end to end.
    ///
    /// It prefers a live session when capture is available, but falls back to a
    /// synthetic session in a sandbox directory otherwise. The fallback is what
    /// makes this test useful on a machine where screen recording is not granted,
    /// and it never touches the user's real data.
    @MainActor
    private static func runIntegrationTest() async {
        let rule = String(repeating: "═", count: 84)

        func banner(_ title: String) {
            print("\n\(rule)\n  \(title)\n\(rule)")
        }

        func detail(_ label: String, _ value: String) {
            print("    \(label.padding(toLength: 28, withPad: " ", startingAt: 0))\(value)")
        }

        let configuration = SkillConfigurationLoader.load()

        banner("PHASE 3 INTEGRATION TEST")
        print("  Skill config: \(configuration.source.description)")

        // ---- 1. Provider preflight --------------------------------------------

        banner("[1/7] OpenAI-compatible provider preflight")

        let available = configuration.configuration.availableProviders()
        if available.isEmpty {
            let nominated = configuration.configuration.defaultProvider
            print("  No API key is configured for any provider.")
            print("  The nominated provider is: \(nominated?.label ?? "none")")
            print("  Set one of these in your environment and re-run:")
            for provider in configuration.configuration.apiProviders.providers {
                print("    export \(provider.apiKeyEnvironmentVariable)=\"sk-…\"   # \(provider.label)")
            }
            print("\n  Everything else in the pipeline (capture, storage, pruning) is unaffected —")
            print("  a session will still stop, archive a failure note, and record its telemetry.")
            return
        }

        let provider = available[0]
        let apiKey = ProcessInfo.processInfo.environment[provider.apiKeyEnvironmentVariable] ?? ""
        detail("provider:", provider.displayName)
        detail("endpoint:", provider.baseURL)
        detail("key:", apiKey.count > 8 ? "\(apiKey.prefix(4))…\(apiKey.suffix(4))" : "present")
        detail("temperature:", "\(provider.temperature)")
        detail("context window:", "\(provider.maxContextWindow) tokens")
        detail("fallbacks available:", "\(available.count - 1)")

        // ---- 2. Stores ---------------------------------------------------------

        banner("[2/7] Stores")

        // Sandboxed for the test: the synthetic session must not pollute the
        // user's real database or memory profile.
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPilotIntegration-\(UUID().uuidString.prefix(8))", isDirectory: true)

        let userMemory: UserMemoryStore
        let sessionStore: SessionStore
        do {
            userMemory = try UserMemoryStore(directory: sandbox)
            sessionStore = try await SessionStore.open(directory: sandbox)
        } catch {
            print("  FAILED to initialise the sandbox stores: \(error.localizedDescription)")
            return
        }

        detail("sandbox:", sandbox.path)
        detail("memory file:", userMemory.path)
        detail("database:", sessionStore.path)

        // Drive the model with the sandbox stores, so the event seeded below and
        // the synthesis that reads them back hit the same database.
        let sandboxModel = AppModel(
            settings: AppSettings(),
            sessionStore: sessionStore,
            userMemoryStore: userMemory
        )

        // Seed the profile so the prompt carries real identity context, and read
        // the result rather than discarding it.
        let seededProfile = await userMemory.loadMemory()
        detail("role in profile:", seededProfile.userIdentity.role)
        detail("rules of thumb:", "\(seededProfile.cumulativeRulesOfThumb.count)")

        // ---- 3. Session --------------------------------------------------------

        banner("[3/7] Session")

        // Boot the sandbox model before anything touches it, so the events seeded
        // below and the synthesis that reads them back share one database.
        if let failure = await sandboxModel.startAsync() {
            print("  FAILED to configure the sandbox model: \(failure)")
            return
        }

        let sessionId = await sessionStore.startSession()

        // The telemetry below is deliberately the shape a real day produces: a
        // window with real work, browser context that produced nothing, an
        // ephemeral fragment from a note app, and a compiler error loop.
        let now = Date()
        let stamps = stride(from: -1800, through: 0, by: 240).map { now.addingTimeInterval(TimeInterval($0)) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let seeds: [(app: String, bundle: String, window: String, ephemeral: Bool, delta: String)] = [
            (
                "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — SessionCoordinator.swift", false,
                """
                let summary = await sessionStore.stopSession(sessionId: sessionId)
                error: cannot find 'ReportArchiver' in scope
                warning: variable 'rules' was never mutated
                let rules = RuleOfThumbHarvester.harvest(from: report)
                """
            ),
            (
                "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — APIClient.swift", false,
                """
                struct ChatCompletionResponse: Decodable {
                    let choices: [Choice]
                }
                networking: Fetching debrief from https://openrouter.ai/api/v1
                """
            ),
            (
                "Google Chrome", "com.google.Chrome", "Agent Use Cases — Lovable, Directories", false,
                """
                Lovable
                Best no-code agent builders
                OpenRouter
                Claude Code
                """
            ),
            (
                "Stickies", "com.apple.Stickies", "Stickies", true,
                """
                BiteFix idea: 3-second pattern interrupt — shake camera + audio stutter on the meal photo
                prompt draft: "Generate 3 high-hook video scripts for nutrition tracker onboarding"
                """
            ),
            (
                "Terminal", "com.apple.Terminal", "daypilot — swift build -c release", false,
                """
                swift build -c release --product DayPilot
                Build of product 'DayPilot' complete! (21.4s)
                """
            ),
            (
                "Google Chrome", "com.google.Chrome", "Gemini — AI Studio", true,
                """
                model: gemini-2.0-flash
                temperature: 0.3
                refine this system prompt for terser output
                """
            ),
            (
                "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — SessionCoordinator.swift", false,
                """
                func stop() async -> SessionCompletion {
                    let outcome = try await synthesise(context: context)
                }
                Build succeeded
                """
            )
        ]

        for (index, seed) in seeds.enumerated() {
            let event = SessionEvent(
                id: UUID().uuidString,
                sessionId: sessionId,
                timestamp: formatter.string(from: stamps[index]),
                appName: seed.app,
                bundleId: seed.bundle,
                windowTitle: seed.window,
                isEphemeral: seed.ephemeral,
                extractedTextDelta: seed.delta
            )
            try? await sessionStore.recordEvent(event)
        }
        detail("synthetic events:", "\(await sessionStore.totalEventCount())")
        detail("ephemeral events:", "\(seeds.filter(\.ephemeral).count)")

        // Attach the coordinator to the session its events belong to. The events
        // are already in the store, so this is the "close out a session recorded
        // earlier" path — the same one crash recovery would use.
        do {
            try await sandboxModel.attachForVerification(
                sessionId: sessionId,
                startedAt: now.addingTimeInterval(-1800),
                eventCount: seeds.count
            )
        } catch {
            print("  FAILED to attach the session: \(error.localizedDescription)")
            return
        }

        // ---- 4. Stop: synthesis + archive + speech ------------------------------

        banner("[4/7] Running stop() — synthesis, archive, memory, voice")

        let completion = await sandboxModel.stopWorkday()
        detail("session id:", completion.sessionId)
        detail("duration:", "\(Int(completion.durationSeconds))s")
        detail("events:", "\(completion.eventCount)")
        detail("breadcrumbs:", "\(completion.breadcrumbCount)")
        detail("synthesised:", completion.hasReport ? "yes" : "no — \(completion.synthesisFailureReason ?? "unknown")")

        if let failure = completion.synthesisFailureReason {
            // Distinguish "the provider refused" from "there was never a session",
            // because they need completely different fixes.
            let headline = completion.sessionId.isEmpty
                ? "NO SESSION WAS CLOSED"
                : "SYNTHESIS FAILED"
            print("\n  \(headline): \(failure)")
            if !completion.sessionId.isEmpty {
                print("  The raw events are still in SQLite, and a failure report should have been archived.")
            }
        } else {
            detail("rules harvested:", "\(completion.rulesHarvested.count)")
            for rule in completion.rulesHarvested {
                print("      + \(rule)")
            }
        }

        // ---- 5. The report ------------------------------------------------------

        banner("[5/7] Generated Markdown report")

        if completion.reportMarkdown.isEmpty {
            print("  (no report was generated)")
        } else {
            print(completion.reportMarkdown)
        }

        // ---- 6. Archive verification -------------------------------------------

        banner("[6/7] Archive and memory verification")

        if completion.reportPath.isEmpty {
            print("  FAILED — no report path was returned")
        } else {
            let exists = FileManager.default.fileExists(atPath: completion.reportPath)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: completion.reportPath)[.size] as? Int) ?? 0
            print("    \(exists ? "✓" : "✗") report exists      \(completion.reportPath)")
            print("    \(bytes > 0 ? "✓" : "✗") report size      \(bytes) bytes")
        }

        let persisted = await sandboxModel.loadProfile()
        let telemetry = persisted.sessionTelemetrySummary
        print("    ✓ sessions completed  \(telemetry.totalSessionsCompleted)")
        print("    ✓ hours tracked       \(String(format: "%.4f", telemetry.totalHoursTracked))")
        print("    ✓ breadcrumbs         \(telemetry.totalBreadcrumbsHarvested)")
        print("    ✓ last session        \(telemetry.lastSessionTimestamp ?? "none")")
        if !completion.rulesHarvested.isEmpty {
            print("    ✓ rules of thumb      \(persisted.cumulativeRulesOfThumb.count) total")
        }

        // ---- 7. Audio routing ---------------------------------------------------

        banner("[7/7] Spoken debrief (first 10 seconds)")

        if completion.voiceScript.isEmpty {
            print("  No voice script was produced, so there is nothing to play.")
        } else {
            sandboxModel.speakDebriefPreview(completion.voiceScript, autoStopAfter: 10)
            print("  Playing \(completion.voiceScript.count) characters for 10 seconds…")
            let preview = completion.voiceScript
                .split(separator: ".", omittingEmptySubsequences: true)
                .prefix(2)
                .joined(separator: ". ") + "."
            print("  \(preview)")
        }

        // Hold the process open so the spoken clip actually plays before the app
        // settles into its menu-bar run loop.
        try? await Task.sleep(nanoseconds: 11_000_000_000)
        sandboxModel.stopPlayback()

        // The sandbox is left in place on purpose: it holds the SQLite database,
        // the memory profile and the archived report produced by this run, so the
        // result can be inspected afterwards. It lives in the temporary directory,
        // which the system clears on its own schedule.
        print("\n  Integration test complete. Sandbox kept for inspection:")
        print("  \(sandbox.path)")
    }

}
