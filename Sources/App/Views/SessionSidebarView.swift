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
        // The section header otherwise hugs the bar above it — give the whole
        // list a breath so "Sessions" sits clearly below the tab switcher.
        .padding(.top, 8)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.createNewReport() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New report")
            }
        }
    }

    @ViewBuilder
    private func sessionContextMenu(for session: StoredSession) -> some View {
        Button(model.isStarred(session.id) ? "Remove Star" : "Star as Best Working Day") {
            model.toggleStar(session.id)
        }
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
                // Wraps instead of ellipsizing — project condition: no text
                // element may ever be cut off.
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

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
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            // Star: marks this day as a best working day. Persisted by session
            // id, so the mark survives edits and re-listing.
            Button {
                model.toggleStar(session.id)
            } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(starred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(starred ? "Remove best-working-day star" : "Star as a best working day")
            .opacity(starred ? 1 : 0.55)

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

    private var starred: Bool { model.isStarred(session.id) }
}
