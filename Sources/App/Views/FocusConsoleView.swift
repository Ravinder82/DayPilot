import SwiftUI

/// The focus console: one capsule in the top bar that holds the session
/// controls and the session timer side by side.
///
/// Reading left to right: a single play/pause toggle — the button always
/// shows the action available right now and never a disabled twin beside it —
/// then Stop & Debrief, a hairline divider, and a plain stopwatch that counts
/// the session upward. The timer holds while the session is paused and resets
/// when the session ends. Stop writes the Day Brief; Pause never does.
struct FocusConsoleView: View {

    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            SessionControls(model: model)

            Divider()
                .frame(height: 18)
                .opacity(0.6)

            SessionTimer(model: model)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.07), radius: 1, y: 0.5)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
    }
}

// MARK: - Session controls

/// One play/pause toggle and Stop & Debrief.
///
/// The toggle carries both actions the way a media control does: play starts
/// or resumes, pause holds. While the Day Brief is being written a small
/// spinner takes its place. A pause never writes the brief — only Stop does.
private struct SessionControls: View {

    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            if model.sessionState == .synthesising {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .help("Writing the Day Brief…")
                    .accessibilityLabel("Writing the Day Brief")
            } else {
                ConsoleButton(
                    systemImage: model.sessionState == .capturing ? "pause.fill" : "play.fill",
                    tint: model.sessionState == .capturing ? .orange : .green,
                    isProminent: true,
                    help: toggleHelp
                ) {
                    toggle()
                }
            }

            ConsoleButton(
                systemImage: "stop.fill",
                tint: .red,
                isEnabled: model.sessionState == .capturing || model.sessionState == .paused,
                help: "Stop and write the Day Brief"
            ) {
                Task { _ = await model.stopWorkday() }
            }
        }
    }

    private var toggleHelp: String {
        switch model.sessionState {
        case .idle: return "Start a session"
        case .capturing: return "Pause the session — the Day Brief is written only when you stop"
        case .paused: return "Resume the session"
        case .synthesising: return "Writing the Day Brief…"
        }
    }

    private func toggle() {
        Task {
            switch model.sessionState {
            case .idle:
                await model.startWorkday()
            case .capturing:
                await model.pauseWorkday()
            case .paused:
                await model.resumeWorkday()
            case .synthesising:
                break
            }
        }
    }
}

// MARK: - Session timer

/// A plain stopwatch for the current session: elapsed time counted upward in
/// monospaced digits, `00:00:00` at rest. No deadlines, no phases — the
/// session runs as long as it runs.
private struct SessionTimer: View {

    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "stopwatch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text(model.elapsedClockText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.sessionState == .idle ? Color.secondary : Color.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session timer")
        .accessibilityValue(model.elapsedClockText)
        .help("Session timer — runs with the session and holds while paused")
    }
}

// MARK: - Button

/// A quiet icon button for the console. The prominent style is the single
/// filled button: the action available right now.
private struct ConsoleButton: View {

    let systemImage: String
    let tint: Color
    var isProminent = false
    var isEnabled = true
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 24, height: 24)
                .background(background, in: Circle())
                .shadow(color: isProminent ? tint.opacity(0.35) : .clear, radius: 2, y: 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .scaleEffect(isHovering && isEnabled ? 1.07 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
        .onHover { hovering in isHovering = hovering && isEnabled }
        .help(help)
        .accessibilityLabel(help)
    }

    private var foreground: Color {
        if isProminent { return .white }
        return isEnabled ? tint : Color.secondary
    }

    private var background: Color {
        if isProminent { return tint }
        guard isEnabled else { return .clear }
        return isHovering ? tint.opacity(0.16) : Color.primary.opacity(0.06)
    }
}
