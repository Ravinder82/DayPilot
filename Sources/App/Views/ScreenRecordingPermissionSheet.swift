import AppKit
import SwiftUI

/// DayPilot's own explanation for a missing Screen Recording grant.
///
/// macOS shows its consent dialog on **every** ScreenCaptureKit call while the
/// grant is missing, so an app that probes from the Play button turns into a
/// popup loop. DayPilot never probes from Play — it shows this sheet instead,
/// and only touches the live APIs when the user clicks Check Again. While the
/// sheet is up, a silent preflight is polled so the moment the toggle lands in
/// System Settings, the sheet closes and the session the user wanted starts.
struct ScreenRecordingPermissionSheet: View {

    @ObservedObject var model: AppModel

    @State private var isChecking = false
    @State private var lastCheckFailed = false

    private let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            steps

            if lastCheckFailed {
                Label(
                    "Still not granted — make sure DayPilot is switched on in the list, then check again.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(26)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // While this sheet is open the user is in System Settings right
            // now. Preflight is silent, so watching for the grant is safe;
            // the moment it lands, close the sheet and start the session.
            for _ in 0..<400 {
                try? await Task.sleep(for: .seconds(1.5))
                if Task.isCancelled { return }
                if ScreenRecordingPermission.isGranted() {
                    _ = await model.recheckScreenRecordingPermission()
                    return
                }
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.orange.opacity(0.24), .orange.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "record.circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.orange)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text("Let DayPilot see the screen")
                    .font(.title3.weight(.semibold))

                Text("macOS reserves screen reading for apps you approve. DayPilot reads on-screen text only while a session records — Zero-Trace erases every capture the moment the debrief is written.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(1, "Open System Settings → Privacy & Security → Screen Recording")
            stepRow(2, "Turn the switch on for DayPilot")
            stepRow(3, "Come back here — the session starts on its own, or click Check Again")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.07), in: Circle())

            Text(text)
                .font(.callout)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Already granted and DayPilot still can't see it? Click Check Again — if it still balks, quit and reopen DayPilot.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Not Now") {
                    model.dismissScreenRecordingSheet()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await recheck() }
                } label: {
                    if isChecking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Check Again")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isChecking)

                Button("Open System Settings") {
                    if let settingsURL {
                        NSWorkspace.shared.open(settingsURL)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func recheck() async {
        isChecking = true
        lastCheckFailed = false
        let started = await model.recheckScreenRecordingPermission()
        isChecking = false
        // On success the model closed this sheet and the session is already
        // starting; only the failure needs to be surfaced here.
        if !started { lastCheckFailed = true }
    }
}
