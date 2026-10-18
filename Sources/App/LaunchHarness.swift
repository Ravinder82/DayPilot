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
        let flags = ["--selftest", "--integration-test", "--test-connection", "--list-models", "--stress-test", "--brief-preview", "--mock-debrief", "--mascot-bench"]
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

        // The mascot's measured warm-up breakdown: parse, stage build, the
        // offscreen first frame that compiles every shader, and what a stage
        // asked for afterwards costs. No window is created.
        if arguments.contains("--mascot-bench") {
            MascotPipeline.shared.startWarmup()
            MascotPipeline.shared.whenWarmupFinished {
                print(MascotPipeline.shared.report())
                exit(0)
            }
            return
        }

        if arguments.contains("--selftest") {
            Task { @MainActor in
                let checks = await SystemHealth.evaluate()
                SystemHealth.log(checks)
                print(SystemHealth.formatReport(checks, version: AppInfo.version))
                // A blocked capability means the binary is unusable on this machine,
                // so the exit code is the signal CI and `make selftest` act on.
                exit(SystemHealth.hasBlockingFailure(checks) ? 1 : 0)
            }
            return
        }

        if arguments.contains("--integration-test") {
            Task { @MainActor in
                await Self.runIntegrationTest()
                try? await Task.sleep(for: .seconds(12))
            }
            return
        }

        // `--mock-debrief`: writes a debrief from a mock ~12-minute
        // indie-developer/freelancer session inside a sandbox — the base
        // fixture for refining the briefing backend without a live capture.
        // Needs a provider key in the environment, like --integration-test.
        if arguments.contains("--mock-debrief") {
            Task { @MainActor in
                await Self.runMockDebrief()
                exit(0)
            }
            return
        }

        // `--stress-test`: runs the Laya + synthesis stress simulation.
        if arguments.contains("--stress-test") {
            Task { @MainActor in
                await Self.runStressTest()
            }
            return
        }

        // `--brief-preview`: offline inspection of the briefing pipeline —
        // synthetic events in, evidence pack and sanitized brief out. No
        // network, no Keychain, no capture.
        if arguments.contains("--brief-preview") {
            Task { @MainActor in
                await Self.runBriefPreview()
                exit(0)
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
                model: gemini-2.5-flash
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

        // ---- 7. Report summary --------------------------------------------------

        banner("[7/7] Report summary")

        if completion.reportMarkdown.isEmpty {
            print("  No brief was produced.")
            if let reason = completion.synthesisFailureReason {
                print("  Reason: \(reason)")
            }
        } else {
            let lines = completion.reportMarkdown
                .split(separator: "\n", omittingEmptySubsequences: false)
                .count
            let title = completion.reportMarkdown
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? "(untitled)"
            print("  \(title)")
            print("  \(lines) lines · \(completion.reportMarkdown.count) characters")
        }

        // The sandbox is left in place on purpose: it holds the SQLite database,
        // the memory profile and the archived report produced by this run, so the
        // result can be inspected afterwards. It lives in the temporary directory,
        // which the system clears on its own schedule.
        print("\n  Integration test complete. Sandbox kept for inspection:")
        print("  \(sandbox.path)")
    }


    // MARK: - Mock debrief (backend refinement fixture)

    /// Generates one debrief from a mock ~12-minute session in a sandbox.
    ///
    /// The fixture is a realistic indie-developer + freelancer morning: client
    /// iOS work, a PR review, an invoice clearing, then a build block on the
    /// user's own product — with the memory profile swapped to a two-hats
    /// persona first, so the prompt that gets tested is the prompt a freelancer
    /// would actually receive. Everything runs in a temporary directory: the
    /// real database, memory profile and reports are never touched. The
    /// sandbox is left in place so the run can be inspected and diffed against
    /// the next refinement iteration.
    ///
    ///     export GEMINI_API_KEY=…   # or any other provider's key
    ///     make mock-debrief
    @MainActor
    private static func runMockDebrief() async {
        let rule = String(repeating: "═", count: 84)

        func banner(_ title: String) {
            print("\n\(rule)\n  \(title)\n\(rule)")
        }

        func detail(_ label: String, _ value: String) {
            print("    \(label.padding(toLength: 28, withPad: " ", startingAt: 0))\(value)")
        }

        let configuration = SkillConfigurationLoader.load()

        banner("MOCK DEBRIEF — INDIE DEVELOPER + FREELANCER, ~12 MINUTES")

        // ---- 1. Provider preflight --------------------------------------------

        let available = configuration.configuration.availableProviders()
        if available.isEmpty {
            print("  No API key is configured for any provider.")
            print("  Set one of these in your environment and re-run:")
            for provider in configuration.configuration.apiProviders.providers {
                print("    export \(provider.apiKeyEnvironmentVariable)=\"sk-…\"   # \(provider.label)")
            }
            return
        }

        let provider = available[0]
        let apiKey = ProcessInfo.processInfo.environment[provider.apiKeyEnvironmentVariable] ?? ""
        detail("provider:", provider.displayName)
        detail("key:", apiKey.count > 8 ? "\(apiKey.prefix(4))…\(apiKey.suffix(4))" : "present")

        // ---- 2. Sandbox stores -------------------------------------------------

        banner("[1/5] Sandbox stores")

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPilotMockDebrief-\(UUID().uuidString.prefix(8))", isDirectory: true)

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

        let sandboxModel = AppModel(
            settings: AppSettings(),
            sessionStore: sessionStore,
            userMemoryStore: userMemory
        )

        // ---- 3. Persona: indie developer + freelancer --------------------------

        banner("[2/5] Memory profile — two hats")

        let profile = UserMemoryProfile(
            userIdentity: .init(
                role: "Indie Developer & Freelancer",
                coreStack: ["Swift", "SwiftUI", "React Native", "Expo", "TypeScript", "Python"],
                ecosystems: ["iOS / App Store Connect", "RevenueCat", "Client retainers (Northwind)", "AI APIs & MCP"]
            ),
            appPurposeAndMandate: .init(
                whatDayPilotDoesForMe: """
                Acts as my chief of staff across two hats — billable client freelance work and my \
                own indie products. It watches my work between Start and Stop, keeps client delivery \
                time distinct from build time on my own apps, and turns loose thoughts into \
                shippable next steps.
                """,
                trackingPhilosophy: """
                Passive capture via Neural Engine OCR. Zero video storage. High-density synthesis \
                only — brief me like an executive, not a diary.
                """
            ),
            activeProjects: [
                .init(
                    name: "DayPilot",
                    type: "macOS indie product",
                    status: "In active development",
                    objective: "Ship the menu bar productivity agent and publish FlyMascots on npm"
                ),
                .init(
                    name: "Northwind ClientApp",
                    type: "Freelance client iOS app",
                    status: "Retainer — weekly delivery",
                    objective: "Invoice list fixes and TestFlight builds on request"
                )
            ],
            cognitiveProfile: .init(
                peakFlowWindow: "Morning / Early Afternoon",
                frictionPatterns: [
                    "Context-switching between client tickets and my own product",
                    "Browsing X/Twitter instead of shipping"
                ],
                creativeHabits: [
                    "Drafting ideas in Stickies",
                    "Testing prompts in AI Studio and closing tabs"
                ]
            ),
            cumulativeRulesOfThumb: [
                "Always resolve actor isolation warnings at class boundaries rather than async callback wraps.",
                "Never let transient ideas die in closed browser tabs; harvest them immediately."
            ],
            sessionTelemetrySummary: .init(
                totalSessionsCompleted: 0,
                totalHoursTracked: 0.0,
                totalBreadcrumbsHarvested: 0,
                lastSessionTimestamp: nil
            )
        )
        try? await userMemory.saveMemory(profile)
        detail("role:", profile.userIdentity.role)
        detail("projects:", profile.activeProjects.map(\.name).joined(separator: " · "))

        // ---- 4. The mock session: 13 events over 12 minutes --------------------

        banner("[3/5] Mock session — 13 events over 12 minutes")

        if let failure = await sandboxModel.startAsync() {
            print("  FAILED to configure the sandbox model: \(failure)")
            return
        }

        let sessionId = await sessionStore.startSession()
        let now = Date()
        let windowSeconds = 720
        let stamps = stride(from: -windowSeconds, through: 0, by: 60).map { now.addingTimeInterval(TimeInterval($0)) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // A fragmented but honest freelancer morning: client fix first, PR and
        // invoice around it, then a build block on the user's own product.
        // Every non-ephemeral event sits 60s apart (above the 30s dwell floor),
        // the error line leads event 1 (friction), and the domain-prefixed
        // browser titles are what the evidence step parses into artifacts.
        let seeds: [(app: String, bundle: String, window: String, ephemeral: Bool, delta: String)] = [
            (
                "Xcode", "com.apple.dt.Xcode", "ClientApp.xcodeproj — InvoiceListViewModel.swift", false,
                """
                error: cannot find 'InvoiceState' in scope
                func invoiceState(for id: String) -> InvoiceState {
                struct InvoiceState { case draft, sent, paid }
                Build succeeded
                """
            ),
            (
                "Xcode", "com.apple.dt.Xcode", "ClientApp.xcodeproj — InvoiceListViewModel.swift", false,
                """
                private func refreshInvoices() async {
                let rows = try await client.fetchInvoices()
                @MainActor func apply(_ rows: [Invoice])
                """
            ),
            (
                "Google Chrome", "com.google.Chrome", "github.com/northwind/clientapp — Pull Request #42", false,
                """
                github.com
                Invoice rows recycle correctly on iOS 17
                approved · reviewed 3 files
                """
            ),
            (
                "Terminal", "com.apple.Terminal", "clientapp — git commit", false,
                """
                git commit -m "fix: invoice row recycling on iOS 17"
                [main 8f3c1d2] fix: invoice row recycling on iOS 17
                3 files changed, 41 insertions(+)
                """
            ),
            (
                "Slack", "com.tinyspeck.slackmacgap", "#northwind — Slack", false,
                """
                invoice fix is merged — TestFlight build goes out this afternoon
                """
            ),
            (
                "Google Chrome", "com.google.Chrome", "dashboard.stripe.com — Invoices", false,
                """
                dashboard.stripe.com
                Invoice inv_42X9 paid $1,240.00
                """
            ),
            (
                "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — PromptBuilder.swift", false,
                """
                let systemPrompt = PromptBuilder.systemPrompt(memoryContext: memoryContext)
                evidence.deep_work_blocks
                Build succeeded
                """
            ),
            (
                "Terminal", "com.apple.Terminal", "daypilot — swift build -c release", false,
                """
                swift build -c release --product DayPilot
                Build of product 'DayPilot' complete! (19.8s)
                """
            ),
            (
                "Stickies", "com.apple.Stickies", "Stickies", true,
                """
                FlyMascots idea: npm publish checklist — login, publish, verify registry
                remind Northwind: retainer invoice lands Friday
                """
            ),
            (
                "Google Chrome", "com.google.Chrome", "news.ycombinator.com — Show HN: A tool that writes your day brief", false,
                """
                news.ycombinator.com
                Show HN: A tool that writes your day brief
                312 points · 96 comments
                """
            ),
            (
                "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — FileManagerView.swift", false,
                """
                List(filteredFiles, selection: .constant(nil)) { file in
                FileRowView(file: file, store: store)
                """
            ),
            (
                "Google Chrome", "com.google.Chrome", "app.revenuecat.com — DayPilot", false,
                """
                app.revenuecat.com
                DayPilot · 42 trials · 9 conversions
                """
            ),
            (
                "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — SessionSidebarView.swift", false,
                """
                Section("Sessions") {
                .padding(.top, 8)
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
        detail("events:", "\(await sessionStore.totalEventCount())")
        detail("ephemeral:", "\(seeds.filter(\.ephemeral).count)")

        do {
            try await sandboxModel.attachForVerification(
                sessionId: sessionId,
                startedAt: now.addingTimeInterval(-TimeInterval(windowSeconds)),
                eventCount: seeds.count
            )
        } catch {
            print("  FAILED to attach the session: \(error.localizedDescription)")
            return
        }

        // ---- 5. Stop: synthesis + archive --------------------------------------

        banner("[4/5] Running stop() — synthesis + archive")

        let completion = await sandboxModel.stopWorkday()
        detail("session id:", completion.sessionId)
        detail("duration:", "\(Int(completion.durationSeconds))s")
        detail("synthesised:", completion.hasReport ? "yes" : "no — \(completion.synthesisFailureReason ?? "unknown")")
        detail("rules harvested:", "\(completion.rulesHarvested.count)")
        for rule in completion.rulesHarvested {
            print("      + \(rule)")
        }

        banner("[5/5] The debrief")

        if completion.reportMarkdown.isEmpty {
            print("  (no report was generated)")
            if let reason = completion.synthesisFailureReason {
                print("  Reason: \(reason)")
            }
        } else {
            print(completion.reportMarkdown)
        }

        if !completion.reportPath.isEmpty {
            let exists = FileManager.default.fileExists(atPath: completion.reportPath)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: completion.reportPath)[.size] as? Int) ?? 0
            print("\n    \(exists ? "✓" : "✗") report exists   \(completion.reportPath)")
            print("    \(bytes > 0 ? "✓" : "✗") report size     \(bytes) bytes")
        }

        print("\n  Mock debrief complete. Sandbox kept for inspection:")
        print("  \(sandbox.path)")
    }

    // MARK: - Brief Preview

    /// Offline inspection of the briefing pipeline: synthetic events in,
    /// evidence pack and sanitized brief out.
    ///
    /// Deliberately touches nothing: no network call, no Keychain read, no
    /// screen capture. It exists so the compression step (what the model sees)
    /// and the hygiene step (what the model may not ship) can be inspected
    /// without burning a provider call or a permission.
    @MainActor
    public static func runBriefPreview() async {
        let rule = String(repeating: "─", count: 84)
        func banner(_ title: String) { print("\n\(rule)\n  \(title)\n\(rule)") }

        banner("BRIEF PREVIEW — synthetic day, no network, no Keychain")

        // A ninety-minute working morning: deep work, a build, a browser
        // lookup, two ephemeral fragments, and a GitHub check.
        let seeds: [(minute: Double, app: String, bundle: String, window: String, ephemeral: Bool, delta: String)] = [
            (0, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — BriefSanitizer.swift", false,
             "let cleaned = BriefSanitizer.sanitize(reportMarkdown: reportMarkdown, payloadCorpus: payload, date: date)"),
            (7, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — BriefSanitizer.swift", false,
             "private static func dropEmptySections(_ sections: [Section], removed: inout [String]) -> [Section]"),
            (14, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — BriefSanitizer.swift", false,
             "guard contentWords >= 3 else { removed.append(\"empty section\") ; return false }"),
            (19, "Terminal", "com.apple.Terminal", "daypilot — swift build", false,
             "swift build 2>&1 | grep -E \"error|warning\"\nBuild complete! 0 errors, 0 warnings"),
            (24, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — PromptBuilder.swift", false,
             "static func systemPrompt(memoryContext: String) -> String { section repertoire, evidence-only }"),
            (31, "Google Chrome", "com.google.Chrome", "ChatGPT — prompt review", true,
             "The brief should read like a memo, not a dashboard. Remove the emoji section headings."),
            (35, "Google Chrome", "com.google.Chrome", "ChatGPT — prompt review", true,
             "Add a rule: omit sections with no evidence instead of writing placeholder lines."),
            (40, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — SessionCoordinator.swift", false,
             "let isProbe = Self.isProbeSession(context: context)"),
            (48, "Terminal", "com.apple.Terminal", "daypilot — make package", false,
             "make package\ncodesign --verify — passed\nInstalled to /Applications/DayPilot.app"),
            (54, "Safari", "com.apple.Safari", "developer.apple.com — SCShareableContent", false,
             "SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:) — Apple Developer"),
            (60, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — ReportArchiver.swift", false,
             "func recordProbeSession(context: SessionCompletionContext) async -> ArchiveOutcome?"),
            (66, "Notes", "com.apple.Notes", "Draft — launch notes", true,
             "Landing headline ideas: Know where your day went. Privacy-first work tracker."),
            (72, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — BriefSanitizer.swift", false,
             "while value.hasSuffix(\" \") { value.removeLast() }"),
            (80, "Google Chrome", "com.google.Chrome", "GitHub — Ravinder82/DayPilot", false,
             "Commits on main: popup-free permission flow, unified console, chief-of-staff brief"),
            (88, "Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — SystemHealth.swift", false,
             "briefHygieneCheck() — sanitizer regression probe")
        ]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let start = Date().addingTimeInterval(-90 * 60)

        var events: [SessionEvent] = []
        for seed in seeds {
            events.append(
                SessionEvent(
                    id: UUID().uuidString,
                    sessionId: "preview",
                    timestamp: formatter.string(from: start.addingTimeInterval(seed.minute * 60)),
                    appName: seed.app,
                    bundleId: seed.bundle,
                    windowTitle: seed.window,
                    isEphemeral: seed.ephemeral,
                    extractedTextDelta: seed.delta
                )
            )
        }

        let context = SessionCompletionContext(
            sessionId: "preview",
            startedAt: start,
            stoppedAt: start.addingTimeInterval(90 * 60),
            eventCount: events.count,
            breadcrumbCount: seeds.filter(\.ephemeral).count,
            suppressedFrameCount: 2
        )

        // ---- 1. What the model sees -----------------------------------------
        banner("[1/3] Payload compression")
        let (payload, pruning) = PromptBuilder.userPayload(events: events, context: context)
        print("  events read:     \(pruning.eventsRead)")
        print("  merged:          \(pruning.eventsMerged)")
        print("  pruned low-dwell:\(pruning.eventsPrunedLowDwell)")
        print("  included:        \(pruning.eventsIncluded)")
        print("  payload size:    \(pruning.payloadCharacters) characters")

        if let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            print("\n  --- payload actually sent to the model ---")
            print(text)
        } else {
            print(payload)
        }

        // ---- 2. What the model is told --------------------------------------
        banner("[2/3] System prompt (first 60 lines)")
        let systemPrompt = PromptBuilder.systemPrompt(memoryContext: "- Founder of a macOS productivity app.\n- Ships small, frequent releases.")
        print(systemPrompt.components(separatedBy: .newlines).prefix(60).joined(separator: "\n"))

        // ---- 3. What survives the sanitizer ---------------------------------
        banner("[3/3] Sanitizer — a deliberately awful model reply")

        let dirty = """
        # ⚡ Indie Velocity Debrief — 2026-10-17

        ### 1. 🚀 Shipped Velocity (The Needle Movers)
        - Nothing shipped in this session.

        ### 2. ⏱️ The Reality Mirror
        - You delved into the brief pipeline for a seamless, truly robust morning of deep work.
        - No ephemeral logs were captured in this session.

        ### 3. 🎯 Tomorrow's Zero-Friction Launchpad
        - **Target File:** `FancyNew.swift`
        - **Terminal Command:** `open DayPilot.xcodeproj`

        ### 4. 📊 Where the time went
        - Xcode — 62m
        - Google Chrome — 21m
        """

        print("  --- model reply (raw) ---")
        print(dirty)

        let cleaned = BriefSanitizer.sanitize(
            reportMarkdown: dirty,
            payloadCorpus: payload,
            date: context.stoppedAt
        )

        print("  --- after sanitizer ---")
        print(cleaned)

        let lowered = cleaned.lowercased()
        let checks: [(String, Bool)] = [
            ("title canonicalised", cleaned.hasPrefix("# Day Brief — ")),
            ("emoji stripped", !cleaned.contains("⚡") && !cleaned.contains("🚀")
                && !cleaned.contains("🎯") && !cleaned.contains("🧲")
                && !cleaned.contains("⏱") && !cleaned.contains("📊")),
            ("filler sections dropped", !lowered.contains("nothing shipped") && !lowered.contains("no ephemeral logs")),
            ("banned phrases dropped", !lowered.contains("delve") && !lowered.contains("seamless")),
            ("fabricated file dropped", !lowered.contains("fancynew.swift")),
            ("fabricated command dropped", !lowered.contains("xcodeproj")),
            ("real content kept", lowered.contains("xcode — 62m")),
        ]

        print("  --- verdicts ---")
        var allPassed = true
        for (label, passed) in checks {
            if !passed { allPassed = false }
            print("  \(passed ? "✓" : "✗") \(label)")
        }

        print("\n  \(allPassed ? "PASS — the pipeline is behaving." : "FAIL — see the ✗ checks above.")")
    }

    // MARK: - Stress Test Simulation

    /// Runs a stress test with 200 realistic mixed workday OCR events.
    ///
    /// Tests: Laya Decision Engine filtering, synthesis quality, zero-trace purge.
    @MainActor
    public static func runStressTest() async {
        let rule = String(repeating: "═", count: 84)
        func banner(_ title: String) { print("\n\(rule)\n  \(title)\n\(rule)") }
        func detail(_ label: String, _ value: String) {
            print("    \(label.padding(toLength: 28, withPad: " ", startingAt: 0))\(value)")
        }

        banner("STRESS TEST SIMULATION")

        // ---- 1. Sandbox stores ----
        banner("[1/6] Sandbox stores")
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPilotStress-\(UUID().uuidString.prefix(8))", isDirectory: true)

        let userMemory: UserMemoryStore
        let sessionStore: SessionStore
        do {
            userMemory = try UserMemoryStore(directory: sandbox)
            sessionStore = try await SessionStore.open(directory: sandbox)
        } catch {
            print("  FAILED to initialise sandbox: \(error.localizedDescription)")
            return
        }
        detail("sandbox:", sandbox.path)

        let sandboxModel = AppModel(settings: AppSettings(), sessionStore: sessionStore, userMemoryStore: userMemory)
        if let failure = await sandboxModel.startAsync() {
            print("  FAILED to boot: \(failure)")
            return
        }

        // ---- 2. Generate 200 events ----
        banner("[2/6] Generating 200 stress-test events")

        let sessionId = await sessionStore.startSession()
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Coding sessions (real work)
        let codingEvents = [
            ("Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — SessionCoordinator.swift", false,
             "func stop() async -> SessionCompletion { let outcome = try await synthesise(context: context) }"),
            ("Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — APIClient.swift", false,
             "struct ChatCompletionResponse: Decodable { let choices: [Choice] } networking: Fetching from openrouter.ai"),
            ("Terminal", "com.apple.Terminal", "daypilot — swift build", false,
             "swift build -c release --product DayPilot\nBuild of product 'DayPilot' complete! (21.4s)"),
            ("Xcode", "com.apple.dt.Xcode", "DayPilot.xcodeproj — PromptBuilder.swift", false,
             "func systemPrompt(memoryContext: String) -> String { four passes: noise, harvest, mirror, launchpad }"),
        ]

        // Transient AI chats (discarded insights)
        let aiChatEvents = [
            ("Google Chrome", "com.google.Chrome", "ChatGPT — brainstorm", true,
             "How to implement a circular progress ring in SwiftUI with animated trim"),
            ("Google Chrome", "com.google.Chrome", "Claude — code review", true,
             "Review this Swift code for memory leaks: class Foo { var bar: Bar? }"),
            ("Google Chrome", "com.google.Chrome", "Gemini — research", true,
             "Best practices for security-scoped bookmarks in macOS sandboxed apps"),
            ("Safari", "com.apple.Safari", "Perplexity — architecture", true,
             "How to implement vector search with Core ML embeddings on macOS"),
            ("Google Chrome", "com.google.Chrome", "ChatGPT — prompt", true,
             "Write a system prompt for an AI that summarizes workday telemetry into a debrief"),
        ]

        // Secret leaks
        let secretEvents = [
            ("TextEdit", "com.apple.TextEdit", "secrets.txt", false,
             "OPENAI_API_KEY=sk-proj-abc123def456\nDATABASE_PASSWORD=supersecret123\nAWS_SECRET=AKIAIOSFODNN7EXAMPLE"),
            ("Terminal", "com.apple.Terminal", ".env", false,
             "GEMINI_API_KEY=AIzaSyAbc123\nSTRIPE_SECRET=sk_live_abc123\nJWT_SECRET=myjwtsecret"),
            ("Notes", "com.apple.Notes", "Passwords", false,
             "admin password: hunter2\nroot: toor\napi_token: ghp_abc123def456"),
        ]

        // Noise/idle screens
        let noiseEvents = [
            ("Safari", "com.apple.Safari", "Twitter / X", false, "scrolling through feed..."),
            ("Safari", "com.apple.Safari", "Reddit", false, "browsing r/programming"),
            ("Mail", "com.apple.mail", "Inbox", false, "checking email"),
            ("Finder", "com.apple.finder", "Desktop", false, ""),
            ("System Settings", "com.apple.systempreferences", "General", false, "adjusting settings"),
        ]

        var allEvents: [(app: String, bundle: String, window: String, ephemeral: Bool, delta: String)] = []

        // Add coding events (repeat to reach ~112 real events)
        for _ in 0..<28 {
            for seed in codingEvents {
                allEvents.append(seed)
            }
        }

        // Add AI chat events
        for seed in aiChatEvents {
            allEvents.append(seed)
        }

        // Add secret events
        for seed in secretEvents {
            allEvents.append(seed)
        }

        // Add noise events (80 total)
        for _ in 0..<16 {
            for seed in noiseEvents {
                allEvents.append(seed)
            }
        }

        // Total should be ~200 (28*4=112 + 5 + 3 + 80 = 200)
        detail("total events:", "\(allEvents.count)")
        detail("coding events:", "\(codingEvents.count * 28)")
        detail("AI chat events:", "\(aiChatEvents.count)")
        detail("secret events:", "\(secretEvents.count)")
        detail("noise events:", "\(noiseEvents.count * 16)")

        // ---- 3. Run Laya on each event ----
        banner("[3/6] Running Laya Decision Engine on \(allEvents.count) events")

        var meaningfulCount = 0
        var droppedCount = 0
        var purgedCount = 0
        var insightCount = 0
        var categoryCounts: [String: Int] = [:]

        let engine = DecisionEngineService()

        for (index, seed) in allEvents.enumerated() {
            let state = "Active app: \(seed.app), Window: \(seed.window), OCR text: \(seed.delta)"
            if let decision = await engine.decide(state: state) {

                if !decision.isMeaningfulWork {
                    droppedCount += 1
                } else {
                    meaningfulCount += 1
                }
                if decision.dataSensitivity == "secrets" {
                    purgedCount += 1
                }
                if decision.isDiscardedInsight {
                    insightCount += 1
                }
                categoryCounts[decision.workCategory, default: 0] += 1
            }

            // Record event in SQLite (simulating real capture)
            let event = SessionEvent(
                id: UUID().uuidString,
                sessionId: sessionId,
                timestamp: formatter.string(from: now.addingTimeInterval(TimeInterval(index * 15))),
                appName: seed.app,
                bundleId: seed.bundle,
                windowTitle: seed.window,
                isEphemeral: seed.ephemeral,
                extractedTextDelta: seed.delta
            )
            try? await sessionStore.recordEvent(event)
        }

        detail("meaningful:", "\(meaningfulCount)")
        detail("dropped (noise):", "\(droppedCount)")
        detail("purged (secrets):", "\(purgedCount)")
        detail("discarded insights:", "\(insightCount)")
        for (cat, count) in categoryCounts.sorted(by: { $0.value > $1.value }) {
            detail("  \(cat):", "\(count)")
        }
        detail("tokens saved:", "\(engine.totalTokensSaved)")
        detail("avg latency:", "\(String(format: "%.1f", engine.lastLatencyMs))ms")

        // ---- 4. Attach and stop ----
        banner("[4/6] Running stop() — synthesis + archive + zero-trace purge")

        do {
            try await sandboxModel.attachForVerification(
                sessionId: sessionId,
                startedAt: now.addingTimeInterval(-3000),
                eventCount: allEvents.count
            )
        } catch {
            print("  FAILED to attach: \(error.localizedDescription)")
            return
        }

        let completion = await sandboxModel.stopWorkday()
        detail("session id:", completion.sessionId)
        detail("events:", "\(completion.eventCount)")
        detail("synthesised:", completion.hasReport ? "yes" : "no — \(completion.synthesisFailureReason ?? "unknown")")
        detail("report path:", completion.reportPath)

        // ---- 5. Verify Day Brief ----
        banner("[5/6] Day Brief verification")

        // Check archived report file
        let reportExists = !completion.reportPath.isEmpty && FileManager.default.fileExists(atPath: completion.reportPath)
        print("  \(reportExists ? "✓" : "✗") Report archived: \(completion.reportPath)")

        if reportExists {
            let reportText = (try? String(contentsOfFile: completion.reportPath, encoding: .utf8)) ?? ""
            print("  ✓ Report size: \(reportText.count) chars")

            // Check for Rescued Discarded Insights section
            let hasRescuedSection = reportText.lowercased().contains("rescued")
                || reportText.lowercased().contains("recovered")
                || reportText.lowercased().contains("discarded insight")
                || reportText.lowercased().contains("harvest")
            print("  \(hasRescuedSection ? "✓" : "⚠") Rescued Discarded Insights section: \(hasRescuedSection)")

            // Print report preview
            print("\n  --- Report Preview (first 500 chars) ---")
            print("  \(String(reportText.prefix(500)))")
            print("  ---")
        }

        // Check for zero-trace purge
        let remainingEvents = await sessionStore.totalEventCount()
        print("  \(remainingEvents == 0 ? "✓" : "✗") Zero-trace purge: \(remainingEvents) events remaining (should be 0)")

        // ---- 6. Summary ----
        banner("[6/6] Stress Test Summary")

        print("  Events generated:     \(allEvents.count)")
        print("  Meaningful (kept):    \(meaningfulCount)")
        print("  Dropped (noise):      \(droppedCount)")
        print("  Purged (secrets):     \(purgedCount)")
        print("  Discarded insights:   \(insightCount)")
        print("  Tokens saved (Laya):  \(engine.totalTokensSaved)")
        print("  Report archived:      \(completion.reportPath.isEmpty ? "NO" : "YES")")
        print("  Zero-trace purge:     \(await sessionStore.totalEventCount() == 0 ? "YES" : "NO")")
        print("\n  Stress test complete. Sandbox: \(sandbox.path)")
    }

}
