import SwiftUI

/// The session library: the live session first, then every archived day.
struct SessionSidebarView: View {

    @ObservedObject private var model: AppModel

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        List(selection: $model.selectedSessionID) {
            if model.sessionState != .idle {
                Section("Live") {
                    LiveSessionRow(model: model)
                }
            }

            Section("Sessions") {
                if model.storedSessions.isEmpty {
                    Text(model.storedSessionsMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.storedSessions) { session in
                        SessionRow(session: session, model: model)
                            .tag(session.id as String?)
                            .contextMenu {
                                sessionContextMenu(for: session)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Blank Report") { Task { await model.createNewReport(template: .blank) } }
                    Button("New Daily Debrief") { Task { await model.createNewReport(template: .dailyDebrief) } }
                    Button("New Project Log") { Task { await model.createNewReport(template: .projectLog) } }
                    Button("New Meeting Notes") { Task { await model.createNewReport(template: .meetingNotes) } }
                    Divider()
                    Button("Duplicate Report") { Task { await model.duplicateSelectedReport() } }
                        .disabled(model.selectedSession == nil)
                    Button("Delete Report…", role: .destructive) { Task { await model.deleteSelectedReport() } }
                        .disabled(model.selectedSession == nil)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create new report")
            }
        }
    }

    @ViewBuilder
    private func sessionContextMenu(for session: StoredSession) -> some View {
        Button("Duplicate") { Task { await model.duplicateSelectedReport() } }
        Divider()
        Button("Reveal in Finder") { model.revealLatestReport() }
        Divider()
        Button("Delete…", role: .destructive) { Task { await model.deleteSelectedReport() } }
    }
}

private struct LiveSessionRow: View {

    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(model.sessionState == .paused ? .orange : .green)
                .symbolEffect(.pulse, isActive: model.sessionState == .capturing)

            VStack(alignment: .leading, spacing: 1) {
                Text(liveStatusText)
                    .font(.headline)
                Text(model.elapsedClockText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var liveStatusText: String {
        switch model.sessionState {
        case .paused: return "Paused"
        case .synthesising: return "Writing debrief"
        default: return "Capturing"
        }
    }
}

private struct SessionRow: View {

    let session: StoredSession
    @ObservedObject private var model: AppModel

    init(session: StoredSession, model: AppModel) {
        self.session = session
        self._model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Label("\(session.eventCount)", systemImage: "rectangle.stack")
                    if session.breadcrumbCount > 0 {
                        Label("\(session.breadcrumbCount)", systemImage: "sparkles")
                    }
                    if let duration = session.durationText {
                        Text(duration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Cute delete button
            Button {
                Task { await model.deleteSelectedReport() }
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Delete this report")
            .opacity(0.6)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
