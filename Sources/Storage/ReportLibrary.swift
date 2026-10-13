import Foundation
import os
import AppKit

/// Reads and writes the archived Markdown reports.
///
/// The directory naming is `<YYYY-MM-DD>_<sessionId>.md` — the day first because
/// that is how a person scans a folder of reports, and the session id second
/// because that is what the SQLite rows key on. `ReportLibrary.load(sessionId:)`
/// finds by id, so the date prefix never has to be reconstructed.
enum ReportLibrary {

    private static let logger = Logger(subsystem: AppInfo.identifier, category: "reports")

    /// A report's contents, plus where it came from.
    struct Loaded: Equatable {
        let path: String
        let text: String
    }

    static func baseDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(DayPilotConfiguration.memoryDirectoryName, isDirectory: true)
            .appendingPathComponent(DayPilotConfiguration.reportsDirectoryName, isDirectory: true)
    }

    static func path(for sessionId: String) -> URL? {
        let contents: [String]
        do {
            contents = try FileManager.default
                .contentsOfDirectory(atPath: baseDirectory().path)
        } catch {
            return nil
        }
        // Match the exact id, not a substring, so a session id that starts with
        // another's digits cannot pick up the wrong report.
        return contents
            .filter { $0.hasSuffix("_\(sessionId).md") }
            .sorted()
            .last
            .map { baseDirectory().appendingPathComponent($0) }
    }

    static func load(sessionId: String) -> Loaded? {
        guard let url = path(for: sessionId),
              let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Loaded(path: url.path, text: text)
    }

    /// Every archived report as a library entry, newest first.
    ///
    /// Listed from the folder itself, because the database only knows sessions that
    /// captured something. The start time is read from the id, which encodes it.
    static func archivedSessions() -> [StoredSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baseDirectory().path)) ?? []
        return names
            .filter { $0.hasSuffix(".md") }
            .compactMap { name -> StoredSession? in
                guard let range = name.range(of: "session_") else { return nil }
                let id = String(name[range.lowerBound...].dropLast(3))
                return StoredSession(
                    id: id,
                    startedAt: startedAt(encodedIn: id),
                    stoppedAt: "",
                    eventCount: 0,
                    breadcrumbCount: 0
                )
            }
            .sorted { $0.id > $1.id }
    }

    /// `session_2026-10-12T00-28-32Z_585B21C5` → `2026-10-12T00:28:32Z`, or empty
    /// when the id does not carry a time.
    private static func startedAt(encodedIn id: String) -> String {
        let stamp = id.dropFirst("session_".count).prefix(while: { $0 != "_" })
        guard let separator = stamp.firstIndex(of: "T") else { return "" }
        let date = stamp[..<separator]
        let time = stamp[stamp.index(after: separator)...].replacingOccurrences(of: "-", with: ":")
        return "\(date)T\(time)"
    }

    /// Writes a report back to disk.
    static func save(markdown: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw ReportLibraryError.reportsDirectoryMissing
        }
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            logger.info("Report saved in place at \(path, privacy: .public)")
        } catch {
            throw ReportLibraryError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - CRUD

    /// Creates a new report from a template, returns the new session ID and path.
    static func createNew(template: ReportTemplate = .blank) -> (sessionId: String, path: String, markdown: String) {
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uuid = UUID().uuidString.prefix(8).uppercased()
        let sessionId = "session_\(date)_\(uuid)"
        let fileName = "\(date)_\(sessionId).md"
        let url = baseDirectory().appendingPathComponent(fileName)
        let markdown = template.markdown
        try? Data(markdown.utf8).write(to: url, options: .atomic)
        return (sessionId, url.path, markdown)
    }

    /// Deletes a report by session ID. Moves to Trash subfolder for recovery.
    static func delete(sessionId: String) throws {
        guard let url = path(for: sessionId) else { return }
        let trashDir = baseDirectory().appendingPathComponent("Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let trashURL = trashDir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: trashURL)
        logger.info("Report moved to Trash: \(sessionId, privacy: .public)")
    }

    /// Duplicates a report as a new entry.
    static func duplicate(sessionId: String) throws -> (sessionId: String, path: String, markdown: String) {
        guard let loaded = load(sessionId: sessionId) else {
            throw ReportLibraryError.writeFailed("Report not found")
        }
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uuid = UUID().uuidString.prefix(8).uppercased()
        let newSessionId = "session_\(date)_\(uuid)"
        let fileName = "\(date)_\(newSessionId).md"
        let url = baseDirectory().appendingPathComponent(fileName)
        try Data(loaded.text.utf8).write(to: url, options: .atomic)
        return (newSessionId, url.path, loaded.text)
    }

    /// Exports a report to a user-chosen location in the given format.
    @MainActor
    static func export(sessionId: String, to url: URL, as format: ExportFormat) throws {
        guard let loaded = load(sessionId: sessionId) else {
            throw ReportLibraryError.writeFailed("Report not found")
        }
        let data: Data
        switch format {
        case .markdown:
            data = Data(loaded.text.utf8)
        case .html:
            data = Data(markdownToHTML(loaded.text).utf8)
        case .pdf:
            data = try markdownToPDF(loaded.text)
        case .plainText:
            data = Data(stripMarkdown(loaded.text).utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Restores a report from Trash.
    static func restoreFromTrash(fileName: String) throws {
        let trashDir = baseDirectory().appendingPathComponent("Trash", isDirectory: true)
        let src = trashDir.appendingPathComponent(fileName)
        let dst = baseDirectory().appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    /// Lists files in Trash.
    static func trashContents() -> [String] {
        let trashDir = baseDirectory().appendingPathComponent("Trash", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? []
    }

    /// Permanently deletes a trashed report.
    static func emptyTrash() throws {
        let trashDir = baseDirectory().appendingPathComponent("Trash", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: trashDir.path)
        for file in contents {
            try FileManager.default.removeItem(at: trashDir.appendingPathComponent(file))
        }
    }
}

/// Template for new reports.
public enum ReportTemplate {
    case blank
    case dailyDebrief
    case projectLog
    case meetingNotes

    var markdown: String {
        let date = Date().formatted(date: .complete, time: .omitted)
        switch self {
        case .blank:
            return ""
        case .dailyDebrief:
            return "# Daily Debrief — \(date)\n\n## What Shipped\n\n## What Leaked\n\n## Friction & Lessons\n\n## Tomorrow's Launchpad\n"
        case .projectLog:
            return "# Project Log — \(date)\n\n## Progress\n\n## Blockers\n\n## Decisions\n\n## Next Steps\n"
        case .meetingNotes:
            return "# Meeting Notes — \(date)\n\n## Attendees\n\n## Agenda\n\n## Discussion\n\n## Action Items\n"
        }
    }
}

/// Export format for reports.
public enum ExportFormat {
    case markdown
    case html
    case pdf
    case plainText

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        case .pdf: return "pdf"
        case .plainText: return "txt"
        }
    }

    var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .pdf: return "PDF"
        case .plainText: return "Plain Text"
        }
    }
}

// MARK: - Helpers

@MainActor
private func markdownToHTML(_ markdown: String) -> String {
    // Simple markdown → HTML conversion for export
    var html = markdown
        .replacingOccurrences(of: "# ", with: "<h1>")
        .replacingOccurrences(of: "## ", with: "<h2>")
        .replacingOccurrences(of: "### ", with: "<h3>")
        .replacingOccurrences(of: "\n\n", with: "</p><p>")
    html = "<html><body><p>" + html + "</p></body></html>"
    return html
}

@MainActor
private func markdownToPDF(_ markdown: String) throws -> Data {
    let html = markdownToHTML(markdown)
    let printInfo = NSPrintInfo.shared
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .fit
    let view = NSTextView()
    view.textStorage?.setAttributedString(try NSAttributedString(
        data: Data(html.utf8),
        options: [.documentType: NSAttributedString.DocumentType.html],
        documentAttributes: nil
    ))
    let pdfData = view.dataWithPDF(inside: view.bounds)
    return pdfData
}

private func stripMarkdown(_ markdown: String) -> String {
    return markdown
        .replacingOccurrences(of: "#+ ", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
}

enum ReportLibraryError: LocalizedError {
    case reportsDirectoryMissing
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .reportsDirectoryMissing:
            "The reports directory does not exist yet."
        case .writeFailed(let message):
            "Could not write the report: \(message)"
        }
    }
}
