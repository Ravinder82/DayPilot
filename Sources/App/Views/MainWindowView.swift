import SwiftUI
import UniformTypeIdentifiers

/// The main window with tabs: Library/Editor (split view) and Memory (file manager).
struct MainWindowView: View {

    @ObservedObject private var model: AppModel
    @State private var selectedTab: MainTab = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    enum MainTab: String, CaseIterable, Identifiable {
        case library = "Library"
        case memory = "Memory"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .library: return "sidebar.left"
            case .memory: return "folder.fill.badge.gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar
            HStack {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.system(.body, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedTab == tab ?
                        Color.accentColor.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }

            // Content
            Group {
                if selectedTab == .library {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        SessionSidebarView(model: model)
                            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                    } detail: {
                        ReportEditorView(model: model)
                    }
                } else if let fileManager = model.fileManager {
                    FileManagerView(store: fileManager)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Memory not available")
                            .font(.title3)
                        Text("File manager is initializing...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar { toolbarContent }
        .onChange(of: model.selectedSessionID) { _, _ in
            Task { await model.loadSelectedReport() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if model.sessionState != .idle {
                model.refreshElapsed()
            }
        }
    }

    // MARK: - Toolbar

    /// Ordered by frequency: the session toggle is the action taken all day, so
    /// it leads. Reading and exporting the debrief follow it.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.toggleWorkday() }
            } label: {
                if model.sessionState == .idle {
                    Label("Start Workday", systemImage: "play.circle")
                } else {
                    Label("Stop Day & Debrief", systemImage: "stop.circle")
                }
            }
            .disabled(!model.canToggleWorkday)
            .help(model.sessionState == .idle
                ? "Start capturing this workday"
                : "Stop capturing and write the debrief")
        }

        ToolbarItem(placement: .status) {
            if model.sessionState != .idle {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, isActive: model.sessionState == .capturing)
                    Text(model.elapsedClockText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Session running for \(model.elapsedClockText)")
            }
        }

        ToolbarItem(placement: .status) {
            PomodoroToolbarView(model: model)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isEditingSource.toggle()
            } label: {
                if model.isEditingSource {
                    Label("Rendered", systemImage: "doc.richtext")
                } else {
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .disabled(model.reportBody.isEmpty)
            .help(model.isEditingSource ? "Show the rendered debrief" : "Edit the Markdown source")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.speakDebrief()
            } label: {
                Label("Listen", systemImage: "speaker.wave.2")
            }
            .disabled(!model.canSpeakCurrentDebrief)
            .help("Speak this debrief aloud")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.revealLatestReport()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(model.currentReportPath.isEmpty)
            .help("Show the report file in Finder")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Export as Markdown") { export(.markdown) }
                Button("Export as HTML") { export(.html) }
                Button("Export as PDF") { export(.pdf) }
                Button("Export as Plain Text") { export(.plainText) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.currentReportPath.isEmpty)
            .help("Export the current report")
        }
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(format.fileExtension).map { $0 }].compactMap { $0 }
        panel.nameFieldStringValue = "DayPilot-Report.\(format.fileExtension)"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                model.exportSelectedReport(to: url, as: format)
            }
        }
    }
}

/// Pomodoro timer display in the toolbar status area.
private struct PomodoroToolbarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.pomodoroPhase != .idle {
            HStack(spacing: 8) {
                // Phase indicator with color
                Circle()
                    .fill(phaseColor)
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse, isActive: model.pomodoroPhase == .work)

                // Phase name
                Text(model.pomodoroPhaseText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Progress ring
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                        .frame(width: 16, height: 16)
                    Circle()
                        .trim(from: 0, to: model.pomodoroProgress)
                        .stroke(phaseColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: model.pomodoroProgress)
                }

                // Remaining time
                Text(model.pomodoroRemainingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 45, alignment: .trailing)

                // Cycle count
                if model.pomodoroCycleCount > 0 {
                    Text("✓ \(model.pomodoroCycleCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .onTapGesture {
                if model.pomodoroPhase == .work {
                    model.pausePomodoro()
                } else {
                    model.resumePomodoro()
                }
            }
            .help("Click to pause/resume Pomodoro")
        } else {
            Button {
                model.startPomodoro()
            } label: {
                Label("Start Pomodoro", systemImage: "timer")
            }
            .help("Start a Pomodoro session")
        }
    }

    private var phaseColor: Color {
        switch model.pomodoroPhase {
        case .idle: return .secondary
        case .work: return .red
        case .shortBreak: return .green
        case .longBreak: return .blue
        }
    }
}
