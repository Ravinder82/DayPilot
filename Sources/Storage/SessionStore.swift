import CSQLite
import Foundation
import os

actor SessionStore {

    private enum SQL {
        case insert
        case fetchBySession
        case countBySession
        case breadcrumbCountBySession
        case totalCount
        case sessionIndex

        var text: String {
            switch self {
            case .insert:
                """
                INSERT OR REPLACE INTO session_events
                    (id, session_id, timestamp, app_name, bundle_id, window_title, is_ephemeral, extracted_text_delta)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            case .fetchBySession:
                """
                SELECT id, session_id, timestamp, app_name, bundle_id, window_title, is_ephemeral, extracted_text_delta
                FROM session_events WHERE session_id = ? ORDER BY timestamp ASC, rowid ASC;
                """
            case .countBySession:
                "SELECT COUNT(*) FROM session_events WHERE session_id = ?;"
            case .breadcrumbCountBySession:
                "SELECT COUNT(*) FROM session_events WHERE session_id = ? AND is_ephemeral = 1;"
            case .totalCount:
                "SELECT COUNT(*) FROM session_events;"
            case .sessionIndex:
                """
                SELECT session_id,
                       MIN(timestamp),
                       MAX(timestamp),
                       COUNT(*),
                       SUM(is_ephemeral)
                FROM session_events
                GROUP BY session_id
                ORDER BY MIN(timestamp) DESC;
                """
            }
        }
    }

    private let logger = Logger(subsystem: AppInfo.identifier, category: "sessionstore")

    /// The SQLite connection.
    ///
    /// `nonisolated(unsafe)` because `deinit` runs on the generic executor and
    /// must release it. That is safe: the pointer is immutable once the store
    /// is built, every use goes through this actor (so they are serialised),
    /// and by the time `deinit` runs the actor can have no outstanding
    /// execution.
    nonisolated(unsafe) private let handle: OpaquePointer
    private let databaseURL: URL

    /// Instance-scoped: `ISO8601DateFormatter` is not `Sendable`, so it must
    /// stay actor-isolated rather than share a static.
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private init(databaseURL: URL, handle: OpaquePointer) {
        self.databaseURL = databaseURL
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Opens (creating if needed) `DayPilot.sqlite` under Application Support
    /// and brings the schema up to date.
    static func open(directory: URL? = nil) async throws -> SessionStore {
        let base = try Self.applicationSupportDirectory(explicit: directory)
        try Self.createDirectoryIfNeeded(base)
        let url = base.appendingPathComponent(DayPilotConfiguration.databaseFileName, isDirectory: false)

        var opened: OpaquePointer?
        guard sqlite3_open(url.path, &opened) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let opened { sqlite3_close(opened) }
            throw SessionStoreError.cannotOpen(message)
        }

        // A short busy timeout so a Console.app inspection can never deadlock
        // the writer.
        sqlite3_busy_timeout(opened, 250)

        let store = SessionStore(databaseURL: url, handle: opened)
        try await store.createSchema()
        store.logger.notice("Session store ready at \(url.path, privacy: .public)")
        return store
    }

    /// Absolute path of the backing database.
    ///
    /// `nonisolated` so the coordinator and the smoke test can read it without
    /// an actor hop; `databaseURL` is immutable and `Sendable`.
    nonisolated var path: String { databaseURL.path }

    // MARK: - Public API

    /// Generates a session identifier.
    ///
    /// The ID is embedded in each event row rather than in a parent row, so
    /// starting a session is one allocation and cannot fail.
    func startSession() -> String {
        let stamp = timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "session_\(stamp)_\(UUID().uuidString.prefix(8))"
    }

    func recordEvent(_ event: SessionEvent) async throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, SQL.insert.text, -1, &statement, nil) == SQLITE_OK else {
            throw SessionStoreError.prepareFailed(Self.lastError(handle))
        }
        defer { sqlite3_finalize(statement) }

        Self.bindText(statement, 1, event.id)
        Self.bindText(statement, 2, event.sessionId)
        Self.bindText(statement, 3, event.timestamp)
        Self.bindText(statement, 4, event.appName)
        Self.bindText(statement, 5, event.bundleId)
        Self.bindText(statement, 6, event.windowTitle)
        sqlite3_bind_int64(statement, 7, event.isEphemeral ? 1 : 0)
        Self.bindText(statement, 8, event.extractedTextDelta)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionStoreError.insertFailed(Self.lastError(handle))
        }
    }

    /// Every event recorded for a session, oldest first.
    func fetchSessionPayload(sessionId: String) async -> [SessionEvent] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, SQL.fetchBySession.text, -1, &statement, nil) == SQLITE_OK else {
            let message = Self.lastError(handle)
            logger.error("fetch prepare failed: \(message, privacy: .public)")
            return []
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, 1, sessionId)

        var events: [SessionEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(Self.row(statement))
        }
        return events
    }

    /// Closes a session and reports durable counts.
    func stopSession(sessionId: String) async -> SessionSummary {
        let summary = SessionSummary(
            sessionId: sessionId,
            eventCount: count(sessionId: sessionId),
            breadcrumbCount: breadcrumbCount(sessionId: sessionId)
        )
        logger.notice(
            "Session \(sessionId, privacy: .public) stopped — \(summary.eventCount) events, \(summary.breadcrumbCount) breadcrumbs"
        )
        return summary
    }

    /// Hard-purges all raw OCR events for a session from SQLite.
    ///
    /// Called after the Day Brief has been generated and archived. Deletes every
    /// raw event row and vacuums the database so no screen text survives.
    func purgeSession(sessionId: String) async {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.handle, "DELETE FROM session_events WHERE session_id = ?;", -1, &statement, nil) == SQLITE_OK else {
            logger.error("purge prepare failed: \(Self.lastError(self.handle), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, 1, sessionId)

        if sqlite3_step(statement) == SQLITE_DONE {
            let deleted = sqlite3_changes(self.handle)
            logger.notice("Purged \(deleted) raw events for session \(sessionId, privacy: .public)")
        } else {
            logger.error("purge step failed: \(Self.lastError(self.handle), privacy: .public)")
        }

        // VACUUM to reclaim space and ensure no deleted data lingers
        if sqlite3_exec(self.handle, "VACUUM;", nil, nil, nil) != SQLITE_OK {
            logger.error("VACUUM failed: \(Self.lastError(self.handle), privacy: .public)")
        } else {
            logger.notice("Database vacuumed — zero-trace purge complete")
        }
    }

    /// Every recorded session, newest first, summarised for the sidebar.
    ///
    /// `SUM(is_ephemeral)` is null for a session in which no event was
    /// ephemeral, so it is read as an optional and defaulted rather than forced.
    func allSessions() async -> [StoredSession] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, SQL.sessionIndex.text, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [StoredSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                guard let pointer = sqlite3_column_text(statement, column) else { return "" }
                return String(cString: pointer)
            }
            sessions.append(
                StoredSession(
                    id: text(0),
                    startedAt: text(1),
                    stoppedAt: text(2),
                    eventCount: Int(sqlite3_column_int64(statement, 3)),
                    breadcrumbCount: sqlite3_column_type(statement, 4) == SQLITE_NULL
                        ? 0
                        : Int(sqlite3_column_int64(statement, 4))
                )
            )
        }
        return sessions
    }

    /// Total rows across every session; used by the smoke test to prove the
    /// store is live and persisting.
    func totalEventCount() async -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, SQL.totalCount.text, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    // MARK: - Privates

    private func createSchema() throws {
        let ddl = """
        CREATE TABLE IF NOT EXISTS session_events (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            app_name TEXT,
            bundle_id TEXT,
            window_title TEXT,
            is_ephemeral INTEGER NOT NULL DEFAULT 0,
            extracted_text_delta TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_session_events_session_id
            ON session_events(session_id);
        CREATE INDEX IF NOT EXISTS idx_session_events_timestamp
            ON session_events(timestamp);
        PRAGMA journal_mode=WAL;
        """

        guard sqlite3_exec(handle, ddl, nil, nil, nil) == SQLITE_OK else {
            throw SessionStoreError.prepareFailed(Self.lastError(handle))
        }
    }

    private func count(sessionId: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, SQL.countBySession.text, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, 1, sessionId)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func breadcrumbCount(sessionId: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, SQL.breadcrumbCountBySession.text, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(statement, 1, sessionId)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Binds a Swift `String` as SQL text.
    ///
    /// `SQLITE_TRANSIENT` is a C macro, so it is not visible to Swift. Passing
    /// `nil` (which means `SQLITE_STATIC`) would be a latent bug: Swift's
    /// implicit String-to-pointer bridge is only guaranteed valid for the
    /// duration of the call, so SQLite would be left holding a pointer that may
    /// not survive until the statement steps. `strdup` hands SQLite a buffer it
    /// owns and the destructor releases it — the exact ownership semantics
    /// `SQLITE_TRANSIENT` provides in C.
    private static func bindText(
        _ statement: OpaquePointer?,
        _ index: Int32,
        _ value: String
    ) {
        let copy = strdup(value)
        sqlite3_bind_text(statement, index, copy, -1, releaseBuffer)
    }

    private static func row(_ statement: OpaquePointer?) -> SessionEvent {
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: pointer)
        }

        return SessionEvent(
            id: text(0),
            sessionId: text(1),
            timestamp: text(2),
            appName: text(3),
            bundleId: text(4),
            windowTitle: text(5),
            isEphemeral: sqlite3_column_int64(statement, 6) == 1,
            extractedTextDelta: text(7)
        )
    }

    private static func lastError(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    private static func applicationSupportDirectory(explicit: URL?) throws -> URL {
        if let explicit { return explicit }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(DayPilotConfiguration.memoryDirectoryName, isDirectory: true)
    }

    private static func createDirectoryIfNeeded(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SessionStoreError.invalidStorageLocation(url.path)
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Destructor handed to SQLite for every text binding.
///
/// SQLite copies the text immediately and calls this when it is done with the
/// buffer, so `strdup`'d memory is always reclaimed at statement finalization.
private let releaseBuffer: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
    free(pointer)
}

enum SessionStoreError: LocalizedError {
    case cannotOpen(String)
    case prepareFailed(String)
    case insertFailed(String)
    case invalidStorageLocation(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let message):
            "DayPilot could not open its session database: \(message)"
        case .prepareFailed(let message):
            "DayPilot could not prepare a database statement: \(message)"
        case .insertFailed(let message):
            "DayPilot could not record a session event: \(message)"
        case .invalidStorageLocation(let path):
            "DayPilot's storage location is not a directory: \(path)"
        }
    }
}
