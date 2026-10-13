import SwiftUI

/// The Memory tab: a file browser for AI memory folders.
struct FileManagerView: View {

    @ObservedObject var store: FileManagerStore
    @State private var searchText = ""
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var selectedFileTypes: Set<String> = []
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
            // Toolbar
            HStack {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Add Folder", systemImage: "plus")
                }
                .help("Add a folder to AI memory")

                Divider()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search files...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 250)

                Spacer()

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
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                // Filter by type
                Menu {
                    ForEach(fileTypeCategories, id: \.id) { category in
                        let ext = category.fileExtension
                        Toggle(category.label, isOn: Binding(
                            get: { selectedFileTypes.contains(ext) },
                            set: { isOn in
                                if isOn { selectedFileTypes.insert(ext) }
                                else { selectedFileTypes.remove(ext) }
                            }
                        ))
                    }
                    if !selectedFileTypes.isEmpty {
                        Divider()
                        Button("Clear Type Filter") { selectedFileTypes.removeAll() }
                    }
                } label: {
                    Label(selectedFileTypes.isEmpty ? "All Types" : "\(selectedFileTypes.count) Types", systemImage: "doc.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Sort
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .frame(width: 130)

                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                }
                .help("Toggle sort direction")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)

            Divider()

            // File list
            if filteredFiles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: searchText.isEmpty && selectedFolderIDs.isEmpty && selectedFileTypes.isEmpty ? "folder.badge.plus" : "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty && selectedFolderIDs.isEmpty && selectedFileTypes.isEmpty
                         ? "No folders added to memory"
                         : "No files match your search")
                        .font(.title3)
                    if searchText.isEmpty && selectedFolderIDs.isEmpty && selectedFileTypes.isEmpty {
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
                    FileRowView(file: file)
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerView(store: store)
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

        if !selectedFileTypes.isEmpty {
            files = files.filter { selectedFileTypes.contains($0.fileExtension.lowercased()) }
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

    // File type filter category
    private struct FileTypeCategory: Identifiable, Hashable {
        let id = UUID()
        let label: String
        let fileExtension: String
    }

    private let fileTypeCategories: [FileTypeCategory] = [
        FileTypeCategory(label: "Text/Markdown", fileExtension: "md"),
        FileTypeCategory(label: "Text/Markdown", fileExtension: "txt"),
        FileTypeCategory(label: "Swift", fileExtension: "swift"),
        FileTypeCategory(label: "Python", fileExtension: "py"),
        FileTypeCategory(label: "JavaScript", fileExtension: "js"),
        FileTypeCategory(label: "TypeScript", fileExtension: "ts"),
        FileTypeCategory(label: "JSON", fileExtension: "json"),
        FileTypeCategory(label: "YAML", fileExtension: "yaml"),
        FileTypeCategory(label: "HTML", fileExtension: "html"),
        FileTypeCategory(label: "CSS", fileExtension: "css"),
        FileTypeCategory(label: "SQL", fileExtension: "sql"),
        FileTypeCategory(label: "Shell", fileExtension: "sh"),
        FileTypeCategory(label: "Rust", fileExtension: "rs"),
        FileTypeCategory(label: "Go", fileExtension: "go"),
        FileTypeCategory(label: "Images", fileExtension: "jpg"),
        FileTypeCategory(label: "Images", fileExtension: "png"),
        FileTypeCategory(label: "Images", fileExtension: "webp"),
        FileTypeCategory(label: "PDF", fileExtension: "pdf"),
        FileTypeCategory(label: "Video", fileExtension: "mp4"),
        FileTypeCategory(label: "Video", fileExtension: "mov")
    ]
}

/// A row in the file list.
struct FileRowView: View {
    let file: FileManagerStore.FileRecord

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
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text(file.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

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
                revealInFinder()
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.relativePath, forType: .string)
            }
            if file.isText {
                Button("Open in Editor") {
                    openInEditor()
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

    private func revealInFinder() {
        // Would need folder URL - simplified for now
    }

    private func openInEditor() {
        // Would open the file in the report editor - simplified for now
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