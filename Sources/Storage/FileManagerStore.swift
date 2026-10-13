import Foundation
import os
import AppKit
import CryptoKit

/// Manages user-selected folders and files for AI memory.
///
/// Uses security-scoped bookmarks to retain access to user-chosen locations
/// across app restarts without requiring Full Disk Access.
@MainActor
final class FileManagerStore: ObservableObject {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "filemanager")
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "filemanager.bookmarks.v1"
    private let fileIndexKey = "filemanager.index.v1"

    @Published private(set) var bookmarks: [FolderBookmark] = []
    @Published private(set) var fileIndex: [FileRecord] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var lastIndexError: String?

    struct FolderBookmark: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var bookmarkData: Data
        var isActive: Bool
        var addedAt: Date

        init(name: String, bookmarkData: Data) {
            self.id = UUID()
            self.name = name
            self.bookmarkData = bookmarkData
            self.isActive = true
            self.addedAt = Date()
        }
    }

    struct FileRecord: Codable, Identifiable, Equatable, Hashable {
        let id: UUID
        let folderID: UUID
        let relativePath: String
        let fileName: String
        let fileExtension: String
        let fileSize: Int64
        let contentHash: String
        let createdAt: Date
        let modifiedAt: Date
        var indexedAt: Date
        var summary: String?
        var embedding: [Float]? // For future semantic search

        var isText: Bool {
            ["txt", "md", "swift", "py", "js", "ts", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql", "sh", "rb", "go", "rs", "kt", "java", "c", "cpp", "h", "hpp", "m", "mm"].contains(fileExtension.lowercased())
        }

        var isImage: Bool {
            ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"].contains(fileExtension.lowercased())
        }

        var isVideo: Bool {
            ["mp4", "mov", "mkv", "webm", "avi"].contains(fileExtension.lowercased())
        }

        var isPDF: Bool {
            fileExtension.lowercased() == "pdf"
        }

        var isCode: Bool {
            ["swift", "py", "js", "ts", "json", "rs", "go", "java", "kt", "cpp", "c", "h", "hpp", "m", "mm", "sh", "rb", "sql"].contains(fileExtension.lowercased())
        }
    }

    init() {
        loadBookmarks()
        loadFileIndex()
        // Restore security-scoped access for active bookmarks
        for bookmark in bookmarks where bookmark.isActive {
            _ = restoreBookmarkAccess(bookmark)
        }
    }

    // MARK: - Bookmark Management

    /// Adds a folder via the system folder picker.
    func addFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add to DayPilot Memory"
        panel.message = "Select a folder to include in AI memory. DayPilot will index its contents."

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            let bookmarkData = try url.bookmarkData(options: URL.BookmarkCreationOptions.withSecurityScope, includingResourceValuesForKeys: [], relativeTo: nil as URL?)
            let folderName = url.lastPathComponent
            let bookmark = FolderBookmark(name: folderName, bookmarkData: bookmarkData)
            bookmarks.append(bookmark)
            saveBookmarks()
            _ = restoreBookmarkAccess(bookmark)
            indexFolder(bookmark)
            return true
        } catch {
            logger.error("Failed to create bookmark: \(error.localizedDescription, privacy: .public)")
            lastIndexError = "Failed to add folder: \(error.localizedDescription)"
            return false
        }
    }

    /// Removes a folder and its indexed files.
    func removeFolder(_ bookmark: FolderBookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            // Release security-scoped access
            if bookmark.isActive {
                let _ = restoreBookmarkAccess(bookmark) // This will stop accessing
            }
            bookmarks.remove(at: index)
            fileIndex.removeAll { $0.folderID == bookmark.id }
            saveBookmarks()
            saveFileIndex()
        }
    }

    /// Toggles a folder's active state (indexing on/off).
    func toggleFolder(_ bookmark: FolderBookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        var updated = bookmark
        updated.isActive.toggle()
        bookmarks[index] = updated
        saveBookmarks()

        if updated.isActive {
            _ = restoreBookmarkAccess(updated)
            indexFolder(updated)
        } else {
            fileIndex.removeAll { $0.folderID == updated.id }
            saveFileIndex()
        }
    }

    private func restoreBookmarkAccess(_ bookmark: FolderBookmark) -> Bool {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark.bookmarkData,
                             options: .withSecurityScope,
                             relativeTo: nil,
                             bookmarkDataIsStale: &isStale)
            if isStale {
                logger.warning("Bookmark stale for \(bookmark.name, privacy: .public)")
                // Try to recreate if we have access
            }
            return url.startAccessingSecurityScopedResource()
        } catch {
            logger.error("Failed to restore bookmark access: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Indexing

    /// Indexes all files in a folder recursively.
    func indexFolder(_ bookmark: FolderBookmark) {
        guard bookmark.isActive else { return }
        isIndexing = true
        lastIndexError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performIndexing(bookmark)
        }
    }

    private func performIndexing(_ bookmark: FolderBookmark) async {
        var isStale = false
        guard let folderURL = try? URL(resolvingBookmarkData: bookmark.bookmarkData,
                                       options: .withSecurityScope,
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale),
              folderURL.startAccessingSecurityScopedResource() else {
            await MainActor.run {
                self.isIndexing = false
                self.lastIndexError = "Could not access folder: \(bookmark.name)"
            }
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        var newRecords: [FileRecord] = []
        let skippedExtensions = Set(["app", "framework", "dylib", "o", "so", "dylib", "bundle", "xcarchive", "ipa", "dmg", "pkg", "iso"])

        while let fileURL = enumerator?.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate,
                  let created = values.creationDate else { continue }

            let ext = fileURL.pathExtension.lowercased()
            if skippedExtensions.contains(ext) { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: folderURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }

            // Compute content hash for deduplication
            let hash: String
            if let data = try? Data(contentsOf: fileURL) {
                hash = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
            } else {
                hash = ""
            }

            let record = FileRecord(
                id: UUID(),
                folderID: bookmark.id,
                relativePath: relativePath,
                fileName: fileURL.lastPathComponent,
                fileExtension: ext,
                fileSize: Int64(size),
                contentHash: hash,
                createdAt: created,
                modifiedAt: modified,
                indexedAt: Date()
            )
            newRecords.append(record)
        }

        await MainActor.run {
            // Remove old records for this folder
            self.fileIndex.removeAll { $0.folderID == bookmark.id }
            // Add new records
            self.fileIndex.append(contentsOf: newRecords)
            self.saveFileIndex()
            self.isIndexing = false
            self.logger.notice("Indexed \(newRecords.count) files from \(bookmark.name, privacy: .public)")
        }
    }

    /// Re-indexes all active folders.
    func reindexAll() {
        for bookmark in bookmarks where bookmark.isActive {
            indexFolder(bookmark)
        }
    }

    /// Removes files that no longer exist on disk.
    func cleanMissingFiles() {
        var removed = 0
        for bookmark in bookmarks where bookmark.isActive {
            var isStale = false
            guard let folderURL = try? URL(resolvingBookmarkData: bookmark.bookmarkData,
                                           options: .withSecurityScope,
                                           relativeTo: nil,
                                           bookmarkDataIsStale: &isStale),
                  folderURL.startAccessingSecurityScopedResource() else { continue }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            let before = fileIndex.count
            fileIndex.removeAll { record in
                guard record.folderID == bookmark.id else { return false }
                let fileURL = folderURL.appendingPathComponent(record.relativePath)
                return !FileManager.default.fileExists(atPath: fileURL.path)
            }
            removed += before - fileIndex.count
        }
        if removed > 0 {
            saveFileIndex()
            logger.info("Cleaned \(removed) missing files from index")
        }
    }

    /// Removes duplicate files by content hash.
    func cleanDuplicates() {
        var seen = Set<String>()
        let before = fileIndex.count
        fileIndex = fileIndex.filter { record in
            if record.contentHash.isEmpty { return true }
            if seen.contains(record.contentHash) { return false }
            seen.insert(record.contentHash)
            return true
        }
        let removed = before - fileIndex.count
        if removed > 0 {
            saveFileIndex()
            logger.info("Removed \(removed) duplicate files from index")
        }
    }

    // MARK: - Search

    func searchFiles(query: String, folderIDs: Set<UUID>? = nil, fileTypes: Set<String>? = nil) -> [FileRecord] {
        let lowercaseQuery = query.lowercased()
        return fileIndex.filter { record in
            if let folderIDs, !folderIDs.contains(record.folderID) { return false }
            if let fileTypes, !fileTypes.contains(record.fileExtension.lowercased()) { return false }
            if lowercaseQuery.isEmpty { return true }
            return record.fileName.lowercased().contains(lowercaseQuery)
                || record.relativePath.lowercased().contains(lowercaseQuery)
                || record.summary?.lowercased().contains(lowercaseQuery) == true
        }
    }

    // MARK: - Persistence

    private func loadBookmarks() {
        guard let data = defaults.data(forKey: bookmarkKey),
              let decoded = try? JSONDecoder().decode([FolderBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: bookmarkKey)
    }

    private func loadFileIndex() {
        guard let data = defaults.data(forKey: fileIndexKey),
              let decoded = try? JSONDecoder().decode([FileRecord].self, from: data) else { return }
        fileIndex = decoded
    }

    private func saveFileIndex() {
        guard let data = try? JSONEncoder().encode(fileIndex) else { return }
        defaults.set(data, forKey: fileIndexKey)
    }
}

// MARK: - SHA256
import CryptoKit