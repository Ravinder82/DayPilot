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
                        SessionRow(session: session)
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
                .foregroundStyle(.green)
                .symbolEffect(.pulse, isActive: model.sessionState == .capturing)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.sessionState == .capturing ? "Capturing" : "Writing debrief")
                    .font(.headline)
                Text(model.elapsedClockText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRow: View {

    let session: StoredSession

    var body: some View {
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
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
