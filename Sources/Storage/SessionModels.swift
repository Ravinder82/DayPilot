import Foundation

/// One meaningful change recorded during a workday session.
///
/// `extractedTextDelta` holds only the text that appeared or changed since the
/// previous capture, never the full screen contents, so the store stays a
/// chronological diff rather than a scrollback.
struct SessionEvent: Sendable, Hashable, Identifiable {
    let id: String
    let sessionId: String
    let timestamp: String
    let appName: String
    let bundleId: String
    let windowTitle: String
    let isEphemeral: Bool
    let extractedTextDelta: String
}

/// Outcome of closing a session, used for the stop() return value and for the
/// session telemetry written back into the user memory profile.
struct SessionSummary: Sendable, Equatable {
    let sessionId: String
    let eventCount: Int
    let breadcrumbCount: Int
}

/// One archived session, summarised for the library.
///
/// The id is the SQLite `session_id`, which is also what the report filename is
/// derived from, so selecting a session always finds its debrief.
struct StoredSession: Sendable, Identifiable, Equatable {
    let id: String
    let startedAt: String
    let stoppedAt: String
    let eventCount: Int
    let breadcrumbCount: Int

    /// Wall-clock length, or nil when the timestamps cannot be read.
    var durationSeconds: TimeInterval? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let start = formatter.date(from: startedAt),
              let end = formatter.date(from: stoppedAt) else {
            return nil
        }
        return end.timeIntervalSince(start)
    }

    /// `2h 5m`, `12m` or `40s`.
    var durationText: String? {
        guard let seconds = durationSeconds else { return nil }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    /// The day the session belongs to, as the library shows it.
    var displayTitle: String {
        let prefix = "session_"
        let stripped = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        let day = stripped.split(separator: "T").first.map(String.init) ?? stripped
        return day.isEmpty ? id : day
    }
}
