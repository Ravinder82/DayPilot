import SwiftUI

/// The status-bar dropdown.
///
/// Contents are ordered by frequency: the two things a user does all day come
/// first, followed by what they do after the fact. A timer that counts live
/// seconds sits at the top, because the assurance that a session is running is
/// worth more than any of the actions.
struct MenuBarView: View {

    @ObservedObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var timerTick = Date()

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    /// Idle is a dashed circle; any active work is a filled record dot.
    /// `circle.dashed` reads as "armed but not rolling"; `record.circle.fill` is
    /// the system's own metaphor for recording, so it is recognisable at a glance.
    private var menuBarSymbol: String {
        switch model.sessionState {
        case .idle: return "circle.dashed"
        case .capturing: return "record.circle.fill"
        case .synthesising: return "waveform.circle.fill"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    private var accentColor: Color {
        switch model.sessionState {
        case .idle: return Color.primary
        case .capturing: return Color.green
        case .synthesising: return Color.accentColor
        case .speaking: return Color.accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            actionButton
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Button {
                // Brings the main window forward rather than opening a separate
                // one: the report lives in the detail pane now.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Label("View Today's Report", systemImage: "doc.richtext")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.latestReportMarkdown.isEmpty)
            .padding(.horizontal, 12)

            Button {
                model.speakDebrief()
            } label: {
                Label("Listen to Debrief", systemImage: "speaker.wave.2")
            }
            .disabled(model.latestVoiceScript.isEmpty)
            .padding(.horizontal, 12)

            Divider()

            SettingsLink {
                Label("Settings…", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 12)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit DayPilot", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: menuBarSymbol)
                    .foregroundStyle(accentColor)
                    .imageScale(.large)

                Text(titleText)
                    .font(.headline)

                Spacer()

                if model.sessionState == .capturing {
                    Text(elapsedText)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundStyle(accentColor)
                        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                            model.refreshElapsed()
                        }
                }
            }

            if isActive {
                HStack(spacing: 10) {
                    Label("\(model.eventCount) events", systemImage: "rectangle.stack")
                    Label("\(model.breadcrumbCount) rescued", systemImage: "sparkles")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var titleText: String {
        switch model.sessionState {
        case .idle:
            return "DayPilot — idle"
        case .capturing:
            return "DayPilot — capturing"
        case .synthesising:
            return "DayPilot — writing debrief"
        case .speaking:
            return "DayPilot — briefing you"
        }
    }

    private var elapsedText: String {
        // Re-read on every tick so the live counter advances.
        _ = timerTick
        return model.elapsedText(
            seconds: Int(model.sessionElapsedSeconds.rounded(.down))
        )
    }

    private var isActive: Bool {
        model.sessionState == .capturing
    }

    // MARK: - Primary action

    private var actionButton: some View {
        Button {
            Task { await performPrimaryAction() }
        } label: {
            HStack {
                Spacer()
                Label(primaryActionTitle, systemImage: primaryActionSymbol)
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .keyboardShortcut(model.sessionState == .idle ? "s" : "e", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .tint(model.sessionState == .idle ? Color.accentColor : Color.orange)
        .disabled(!canPerformPrimaryAction)
    }

    private var primaryActionTitle: String {
        switch model.sessionState {
        case .idle: return "Start Workday"
        case .capturing: return "Stop Day & Debrief"
        case .synthesising: return "Writing debrief…"
        case .speaking: return "Stop Playback"
        }
    }

    private var primaryActionSymbol: String {
        model.sessionState == .idle ? "play.circle.fill" : "stop.circle.fill"
    }

    private var canPerformPrimaryAction: Bool {
        switch model.sessionState {
        case .idle, .capturing: return true
        case .synthesising, .speaking: return false
        }
    }

    // MARK: - Helpers

    @MainActor
    private func performPrimaryAction() async {
        switch model.sessionState {
        case .idle:
            await model.startWorkday()
        case .capturing:
            _ = await model.stopWorkday()
            if !model.latestReportMarkdown.isEmpty {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
        case .synthesising, .speaking:
            model.stopPlayback()
        }
    }

}
