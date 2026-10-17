import AppKit
import os

/// The AppKit side of DayPilot's lifecycle.
///
/// DayPilot is a regular, windowed application that also has a menu bar item. It
/// keeps the default activation policy, which gives it a Dock icon, presence in
/// Launchpad and Applications, and a main window. This delegate handles what
/// SwiftUI's `App` protocol does not expose: quitting, and the snapshot harness.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: AppInfo.identifier, category: "appkit")

    /// The model, handed over once the main window has created it, so quitting can
    /// finish a live session first. Weak, because the App owns the model.
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.notice("DayPilot launched as a windowed application")
        LaunchHarness.scheduleWindowSnapshotIfRequested()
    }

    /// Quitting must not lose a debrief. A session that is still capturing is
    /// closed and written up first, and a debrief already being written is waited
    /// for. Speech is simply stopped, because nothing is lost by cutting it short.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.flushPendingReportWrite()

        guard model.sessionState == .capturing || model.sessionState == .synthesising else {
            return .terminateNow
        }

        Task { @MainActor in
            if model.sessionState == .capturing {
                Self.logger.notice("Quitting mid-session: closing the session first")
                _ = await model.stopWorkday()
            }

            // Bounded, so a debrief that never finishes cannot hold the app open.
            let deadline = Date().addingTimeInterval(180)
            while model.sessionState == .synthesising, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Closing the main window must not end the app. The menu bar item and any
    /// running session still need it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
