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
            topBar

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
        .sheet(isPresented: $model.needsScreenRecordingPermission) {
            ScreenRecordingPermissionSheet(model: model)
        }
    }

    // MARK: - Top bar

    /// One row: tabs on the left, the focus console on the right. The console
    /// holds session controls and the Pomodoro instrument side by side.
    private var topBar: some View {
        HStack(spacing: 12) {
            ForEach(MainTab.allCases) { tab in
                tabButton(for: tab)
            }

            Spacer(minLength: 12)

            FocusConsoleView(model: model, showsPomodoro: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabButton(for tab: MainTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(tab.rawValue, systemImage: tab.icon)
                .font(.system(.body, weight: selectedTab == tab ? .semibold : .regular))
                .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            selectedTab == tab ?
            Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    // MARK: - Toolbar

    /// Ordered by frequency: the session toggle is the action taken all day, so
    /// it leads. Reading and exporting the debrief follow it.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Zero-Trace")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.green.opacity(0.1), in: Capsule())
            .help("Zero-Trace Mode Active: All screenshots & raw logs wiped after Day Brief generation.")
        }

        ToolbarItem(placement: .status) {
            if model.sessionState != .idle {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(model.isSessionPaused ? .orange : .green)
                        .symbolEffect(.pulse, isActive: model.sessionState == .capturing)
                    Text("\(model.isSessionPaused ? "Paused" : "Recording") · \(model.eventCount) events")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(model.isSessionPaused ? "Session paused" : "Recording"), \(model.eventCount) events captured")
            }
        }

        ToolbarItem(placement: .status) {
            LayaTokensSavedView(model: model)
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

/// Laya decision engine tokens-saved counter.
private struct LayaTokensSavedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.tokensSavedByLaya > 0 {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text("\(model.tokensSavedByLaya) tokens saved")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.purple)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.purple.opacity(0.1), in: Capsule())
            .help("Tokens Saved by Laya Decision 1 Engine — fast local decisions that prevent unnecessary cloud LLM calls")
        }
    }
}

