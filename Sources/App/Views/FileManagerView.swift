import AppKit
import SwiftUI

/// The Memory tab: a file browser for AI memory folders.
///
/// Every indexed file is shown — like a normal file manager, the gallery is
/// free for all file types; search and the folder filter narrow it further.
struct FileManagerView: View {

    @ObservedObject var store: FileManagerStore
    @State private var searchText = ""
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var showingFolderPicker = false
    @State private var sortOrder: SortOrder = .name
    @State private var sortAscending = true

    enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Name"
        case date = "Date Modified"
        case size = "Size"
        case type = "Type"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar. Stays one row while it fits; when the window narrows
            // it wraps to two — controls on line 1, the folder/sort menus
            // right-aligned on line 2 — instead of compressing controls.
            // fixedSize(vertical) replaces the old fixed 44pt height: the
            // header takes its intrinsic height (44 single-row, taller when
            // wrapped) but never reports vertical flexibility, so the empty
            // state below never splits the window height with it.
            toolbarContent
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
                .background(.bar)

            Divider()

            // Surface indexing failures instead of silently keeping them.
            if let error = store.lastIndexError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Retry") { store.reindexAll() }
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.08))
                Divider()
            }

            // File list
            if filteredFiles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: searchText.isEmpty && selectedFolderIDs.isEmpty ? "folder.badge.plus" : "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty && selectedFolderIDs.isEmpty
                         ? "No folders added to memory"
                         : "No files match your search")
                        .font(.title3)
                    if searchText.isEmpty && selectedFolderIDs.isEmpty {
                        Text("Click \"Add Folder\" to include directories in AI memory. DayPilot will index their contents for search and context.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(width: 300)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredFiles, selection: .constant(Optional<FileManagerStore.FileRecord>.none)) { file in
                    FileRowView(file: file, store: store)
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerView(store: store)
        }
    }

    /// The toolbar's two layouts: preferred single row, then the wrapped
    /// two-row fallback for narrow windows.
    private var toolbarContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                toolbarLeftControls
                Spacer(minLength: 12)
                toolbarMenus
            }
            VStack(alignment: .leading, spacing: 8) {
                toolbarLeftControls
                HStack(spacing: 10) {
                    Spacer(minLength: 12)
                    toolbarMenus
                }
            }
        }
    }

    /// Add Folder, divider, search field, indexing spinner. The search
    /// field's minWidth lets it compress before anything clips.
    private var toolbarLeftControls: some View {
        HStack(spacing: 10) {
            Button {
                showingFolderPicker = true
            } label: {
                Label("Add Folder", systemImage: "plus")
            }
            .help("Add a folder to AI memory")

            Divider()
                .frame(height: 18)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 100, idealWidth: 240, maxWidth: 240)

            if store.isIndexing {
                ProgressView()
                    .controlSize(.small)
                Text("Indexing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Folder filter and sort menus, right side of the toolbar.
    private var toolbarMenus: some View {
        HStack(spacing: 10) {
            // Filter by folder
            if !store.bookmarks.isEmpty {
                Menu {
                    ForEach(store.bookmarks) { bookmark in
                        Toggle(bookmark.name, isOn: Binding(
                            get: { selectedFolderIDs.contains(bookmark.id) },
                            set: { isOn in
                                if isOn { selectedFolderIDs.insert(bookmark.id) }
                                else { selectedFolderIDs.remove(bookmark.id) }
                            }
                        ))
                    }
                    if !selectedFolderIDs.isEmpty {
                        Divider()
                        Button("Clear Folder Filter") { selectedFolderIDs.removeAll() }
                    }
                } label: {
                    Label(selectedFolderIDs.isEmpty ? "All Folders" : "\(selectedFolderIDs.count) Folders", systemImage: "folder")
                }
                .fixedSize()
            }

            // Sort order and direction in one menu, so the labels can
            // never collide the way the old Picker + arrow pair did.
            Menu {
                ForEach(SortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        if sortOrder == order {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
                Divider()
                Button {
                    sortAscending.toggle()
                } label: {
                    Label(sortAscending ? "Ascending" : "Descending",
                          systemImage: sortAscending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label("\(sortOrder.rawValue) \(sortAscending ? "↑" : "↓")", systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
        }
    }

    private var filteredFiles: [FileManagerStore.FileRecord] {
        var files = store.fileIndex

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            files = files.filter { file in
                file.fileName.lowercased().contains(query)
                || file.relativePath.lowercased().contains(query)
                || file.summary?.lowercased().contains(query) == true
            }
        }

        if !selectedFolderIDs.isEmpty {
            files = files.filter { selectedFolderIDs.contains($0.folderID) }
        }

        // Sort
        files.sort { lhs, rhs in
            let result: Bool
            switch sortOrder {
            case .name:
                result = lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
            case .date:
                result = lhs.modifiedAt < rhs.modifiedAt
            case .size:
                result = lhs.fileSize < rhs.fileSize
            case .type:
                result = lhs.fileExtension < rhs.fileExtension
            }
            return sortAscending ? result : !result
        }

        return files
    }
}

/// A row in the file list.
struct FileRowView: View {
    let file: FileManagerStore.FileRecord
    let store: FileManagerStore

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: fileIcon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.system(.body, design: file.isCode ? .monospaced : .default))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Text(file.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Type badge
            Text(file.fileExtension.uppercased())
                .font(.caption2.monospaced().weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") {
                if let url = store.resolveFileURL(for: file) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    store.resolveFileURL(for: file)?.path ?? file.relativePath,
                    forType: .string
                )
            }
            if file.isText {
                Button("Open") {
                    if let url = store.resolveFileURL(for: file) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var fileIcon: String {
        if file.isImage { return "photo" }
        if file.isVideo { return "film" }
        if file.isPDF { return "doc.fill" }
        if file.isCode { return "chevron.left.forwardslash.chevron.right" }
        if file.isText { return "doc.text" }
        return "doc"
    }

    private var iconColor: Color {
        if file.isImage { return .purple }
        if file.isVideo { return .orange }
        if file.isPDF { return .red }
        if file.isCode { return .blue }
        if file.isText { return .green }
        return .secondary
    }
}

/// Folder picker sheet.
struct FolderPickerView: View {
    @ObservedObject var store: FileManagerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Folder to Memory")
                    .font(.title3.weight(.semibold))
                Text("Select a folder to include in DayPilot's AI memory. The folder's contents will be indexed for search and context.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Folder…") {
                    if store.addFolder() {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 500)
    }
}
