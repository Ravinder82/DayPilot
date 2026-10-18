import AppKit
import SwiftUI

/// DayPilot's application entry point.
///
/// A **standard windowed macOS application**. `LSUIElement` is removed from
/// the Info.plist so the app appears in the Dock and Launchpad. `LSUIElement` was deliberately removed from the Info.plist: it
/// suppresses the Dock icon and Launchpad presence, which is what made the app
/// feel like a background utility rather than a real application. The menu bar
/// item is now a convenience on top of a proper window, which is the model Apple
/// itself uses for apps like Dropbox and Things.
///
/// Three things happen at launch, in this order: the CLI harness that the earlier
/// phases were verified with, then the model that owns every real subsystem, then
/// the scenes.
@main
struct DayPilotApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @State private var showOnboarding = !OnboardingView.isCompleted

    init() {
        // Line-buffer stdout before anything is printed, so diagnostics survive a
        // pipe or a file rather than waiting for the buffer to fill.
        let stdoutBufferMode = Int32(_IOLBF)
        setvbuf(stdout, nil, stdoutBufferMode, 0)

        // Axo's startup cost — one GLB parse plus SceneKit's first-frame shader
        // and lighting compile, ~0.7s measured — is paid here, off the main
        // thread, while the model boots and the window is still being built.
        // Starting it before the CLI harness means a diagnostic run never pays
        // for a mascot it will not draw.
        if !LaunchHarness.isCommandLineToolRun {
            MascotPipeline.shared.startWarmup()
        }

        // CLI first: these exit the process when they run. Deliberately free of
        // any reference to `model` — `init()` runs before the view graph exists,
        // and touching a `@StateObject` there creates a throwaway instance that
        // the UI never sees.
        LaunchHarness.runCommandLineModesIfNeeded()
    }

    var body: some Scene {
        // The application's home: a session library and a report editor.
        // `WindowGroup` rather than `Window`, so more than one debrief can be
        // open at once — a developer comparing two days is a normal case, not a
        // multiwindow edge case.
        WindowGroup("DayPilot", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(model: model)
                }
                .onAppear {
                    // Boot here, on a view that genuinely owns this model. This
                    // is the earliest safe moment: `@StateObject` storage only
                    // exists while a view that owns it is alive.
                    appDelegate.model = model
                    model.activateOnce()
                    Task { await model.refreshLibrary() }
                    // Check if onboarding should show
                    showOnboarding = !OnboardingView.isCompleted
                }
        }
        .defaultSize(width: 1020, height: 680)

        .commands {
            // App menu commands, which are also where the standard Edit and
            // Window menus get their polish.
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Session") {
                Button("Start Workday") {
                    Task { await model.startWorkday() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.sessionState != .idle)

                Button("Stop Day & Debrief") {
                    Task { _ = await model.stopWorkday() }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.sessionState != .capturing)

            }

            CommandMenu("View") {
                Button(model.isEditingSource ? "Show Rendered Report" : "Edit Markdown Source") {
                    model.isEditingSource.toggle()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()

                Button("Reveal Report in Finder") {
                    model.revealLatestReport()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.currentReportPath.isEmpty)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
