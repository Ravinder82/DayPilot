import AppKit

/// Captures DayPilot's own windows as they are drawn in the running application.
///
/// `--snapshot-windows <directory>` launches the real app, waits for its windows to
/// draw, writes a PNG of each titled window, walks the main window's tabs, opens
/// Settings the way ⌘, does, and captures that window too, then quits. Only the
/// app's own drawing is captured, so no screen-recording permission is involved.
/// `--snapshot-appearance light|dark` picks the appearance, and `--preview-fixtures`
/// fills the main window with sample content — a mid-session console included — so
/// the layout can be judged without depending on any real session data.
extension LaunchHarness {

    static var snapshotDirectory: String? {
        argument(following: "--snapshot-windows")
    }

    static var snapshotAppearance: String {
        argument(following: "--snapshot-appearance") ?? "light"
    }

    static var usesPreviewFixtures: Bool {
        CommandLine.arguments.contains("--preview-fixtures")
    }

    /// The argument that follows a flag, when both are present.
    static func argument(following flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Schedules the capture once the application has launched, when requested.
    @MainActor
    static func scheduleWindowSnapshotIfRequested() {
        guard let directory = snapshotDirectory else { return }
        let appearance = snapshotAppearance

        Task { @MainActor in
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)

            // SwiftUI builds the scenes, and the windows need a moment to draw.
            try? await Task.sleep(for: .seconds(4))
            NSApp.activate(ignoringOtherApps: true)
            print("Activation policy: \(NSApp.activationPolicy().rawValue) (0 = regular, Dock visible)")

            // Capture the main window — Library tab.
            captureTitledWindows(to: directory, label: "\(appearance)-library")

            // Switch to the Memory tab and capture.
            switchToMemoryTab()
            try? await Task.sleep(for: .seconds(1))
            captureTitledWindows(to: directory, label: "\(appearance)-memory")

            // Open Settings and capture.
            openSettingsWindow()
            try? await Task.sleep(for: .seconds(2))
            captureTitledWindows(to: directory, label: "\(appearance)-settings")

            // The snapshot process is a tool, not a user session: nothing to
            // close, nothing to flush, so exit directly. An unbundled process
            // does not reliably reach the application delegate through
            // `NSApp.terminate`, and this run must always end by itself.
            print("Snapshot capture complete — exiting")
            exit(EXIT_SUCCESS)
        }
    }

    /// Switches to Memory tab by clicking the tab button in the toolbar.
    @MainActor
    private static func switchToMemoryTab() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            // Find the tab bar buttons in the window's content view
            if let contentView = window.contentView {
                clickTabButton(in: contentView, tabName: "Memory")
            }
        }
    }

    /// Clicks the tab button with the given name in the tab bar.
    @MainActor
    private static func clickTabButton(in view: NSView, tabName: String) {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.title.contains(tabName) {
                button.performClick(nil)
                return
            }
            clickTabButton(in: subview, tabName: tabName)
        }
    }

    /// Opens Settings by performing the Settings item of the application menu,
    /// which is exactly what ⌘, does.
    @MainActor
    private static func openSettingsWindow() {
        func settingsItem(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.keyEquivalent == ",", item.keyEquivalentModifierMask.contains(.command) {
                    return item
                }
                if let nested = settingsItem(in: item.submenu) {
                    return nested
                }
            }
            return nil
        }

        guard let item = settingsItem(in: NSApp.mainMenu), let action = item.action else {
            print("The Settings menu item was not found")
            return
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// Captures every visible titled window, including its title bar and toolbar.
    @MainActor
    private static func captureTitledWindows(to directory: String, label: String) {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            guard let content = window.contentView else { continue }

            // The frame view wraps the content view and also draws the title bar and
            // toolbar, so capturing it shows the window as the user sees it.
            let view = content.superview ?? content

            // Layout first, then draw: a window that has just appeared (Settings)
            // needs its subtrees positioned before `cacheDisplay` can render the
            // list- and form-backed content SwiftUI builds on AppKit containers.
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            view.displayIfNeeded()

            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }

            let title = window.title.isEmpty ? "untitled" : window.title.replacingOccurrences(of: " ", with: "-")
            let file = output.appendingPathComponent("\(label)-\(title).png")
            do {
                try png.write(to: file)
                print("Captured \(file.lastPathComponent): \(Int(view.bounds.width))×\(Int(view.bounds.height)) pt")
            } catch {
                print("Could not write \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
