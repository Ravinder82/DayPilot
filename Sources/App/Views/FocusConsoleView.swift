import SwiftUI

/// The focus console: one capsule in the top bar that holds the session
/// controls and the Pomodoro instrument side by side.
///
/// Reading left to right: Start / Pause / Stop — the action available right
/// now is the only filled button — a hairline divider, then the timer readout:
/// progress ring, remaining time, phase, and cycle pips. The one panel of
/// buttons drives both the session and the timer; right-click the readout to
/// reset the timer or skip a phase.
struct FocusConsoleView: View {

    @ObservedObject var model: AppModel
    var showsPomodoro: Bool

    var body: some View {
        HStack(spacing: 8) {
            SessionControls(model: model)

            if showsPomodoro {
                Divider()
                    .frame(height: 18)
                    .opacity(0.6)

                PomodoroInstrument(model: model)
            }
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

/// Start, Pause/Resume, and Stop & Debrief. A pause never writes the Day
/// Brief; only Stop does. The filled button always marks the action available
/// at this moment, so there is exactly one.
private struct SessionControls: View {

    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ConsoleButton(
                systemImage: "play.fill",
                tint: .green,
                isProminent: model.sessionState == .idle,
                isEnabled: model.sessionState == .idle,
                help: "Start a session and the focus timer"
            ) {
                Task { await model.startWorkday() }
            }

            ConsoleButton(
                systemImage: model.isSessionPaused ? "play.fill" : "pause.fill",
                tint: model.isSessionPaused ? .green : .orange,
                isProminent: model.sessionState == .capturing || model.sessionState == .paused,
                isEnabled: model.sessionState == .capturing || model.sessionState == .paused,
                help: model.isSessionPaused
                    ? "Resume the session and timer"
                    : "Pause the session — the debrief is written only when you stop"
            ) {
                Task {
                    if model.isSessionPaused {
                        await model.resumeWorkday()
                    } else {
                        await model.pauseWorkday()
                    }
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
}

// MARK: - Pomodoro readout

/// The Pomodoro readout: ring, time, phase, and cycle pips. Display only —
/// the session panel beside it drives the timer. Right-click offers the
/// occasional actions: reset and skip.
private struct PomodoroInstrument: View {

    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            progressRing
            timeText
            phaseLabel
            cyclePips
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Skip to Next Phase") {
                model.skipPomodoroPhase()
            }
            .disabled(model.pomodoroPhase == .idle)

            Button("Reset Timer", role: .destructive) {
                model.resetPomodoro()
            }
            .disabled(model.pomodoroPhase == .idle && model.pomodoroCycleCount == 0)
        }
        .help(model.pomodoroPhase == .idle
            ? "Focus timer — starts with the session"
            : "Focus timer — right-click to skip a phase or reset")
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: 3)

            Circle()
                .trim(from: 0, to: model.pomodoroProgress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: model.pomodoroProgress)

            if model.pomodoroPhase == .idle {
                Image(systemName: "timer")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private var timeText: some View {
        Text(clockText)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(model.pomodoroPhase == .idle ? Color.secondary : Color.primary)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.3), value: clockText)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 46, alignment: .leading)
            .accessibilityLabel("Focus timer")
            .accessibilityValue(clockText)
    }

    private var phaseLabel: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .opacity(model.pomodoroPhase == .idle ? 0.4 : 1)

            Text(model.pomodoroPhase == .idle ? "Ready" : model.pomodoroPhaseText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var cyclePips: some View {
        HStack(spacing: 3) {
            ForEach(0..<model.settings.pomodoroCyclesBeforeLongBreak, id: \.self) { index in
                Circle()
                    .fill(index < completedInSet ? tint : Color.primary.opacity(0.12))
                    .frame(width: 4, height: 4)
            }
        }
        .animation(.snappy(duration: 0.25), value: model.pomodoroCycleCount)
        .accessibilityHidden(true)
    }

    // MARK: Readouts

    /// `MM:SS`, or `H:MM:SS` past an hour. Idle shows the configured work
    /// length, so the instrument reads "25:00 · Ready" before it starts.
    private var clockText: String {
        let seconds: Int
        if model.pomodoroPhase == .idle {
            seconds = Int(model.settings.pomodoroWorkDuration)
        } else {
            seconds = Int(max(0, model.pomodoroPhaseDuration - model.pomodoroElapsedSeconds).rounded(.down))
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// Cycles finished inside the current set of four.
    private var completedInSet: Int {
        let cycles = model.settings.pomodoroCyclesBeforeLongBreak
        guard cycles > 0, model.pomodoroCycleCount > 0 else { return 0 }
        if model.pomodoroCycleCount % cycles == 0, model.pomodoroPhase == .longBreak {
            return cycles
        }
        return model.pomodoroCycleCount % cycles
    }

    private var tint: Color {
        switch model.pomodoroPhase {
        case .idle: return .secondary
        case .work: return .orange
        case .shortBreak: return .green
        case .longBreak: return .blue
        }
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
