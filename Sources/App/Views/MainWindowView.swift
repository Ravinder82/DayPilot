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

    /// One row: the tab switcher on the left, the focus console on the right.
    /// The switcher gives way first as the window narrows — labelled buttons
    /// drop to icon-only before anything is clipped — while the console keeps
    /// its intrinsic size so the session controls never squeeze or move.
    private var topBar: some View {
        HStack(spacing: 12) {
            tabSwitcher

            Spacer(minLength: 8)

            FocusConsoleView(model: model)
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// The Library/Memory switcher. `ViewThatFits` shows the labelled buttons
    /// while there is room for them and falls back to icon-only buttons when
    /// the window is too narrow — the standard SwiftUI way to keep a bar
    /// adaptive without hardcoded widths.
    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { tab in
                ViewThatFits(in: .horizontal) {
                    tabButton(for: tab, showsTitle: true)
                    tabButton(for: tab, showsTitle: false)
                }
            }
        }
    }

    private func tabButton(for tab: MainTab, showsTitle: Bool) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                if showsTitle {
                    Text(tab.rawValue)
                }
            }
            .font(.system(.body, weight: selectedTab == tab ? .semibold : .regular))
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, showsTitle ? 16 : 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            selectedTab == tab ?
            Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .help(tab.rawValue)
        .accessibilityLabel(tab.rawValue)
    }

    // MARK: - Toolbar

    /// Ordered by frequency: the session toggle is the action taken all day, so
    /// it leads. Reading and exporting the debrief follow it.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if model.sessionState != .idle {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(model.sessionState == .paused ? .orange : .green)
                        .symbolEffect(.pulse, isActive: model.sessionState == .capturing)
                    Text("\(model.sessionState == .paused ? "Paused" : "Recording") · \(model.eventCount) events")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(model.sessionState == .paused ? "Session paused" : "Recording"), \(model.eventCount) events captured")
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

