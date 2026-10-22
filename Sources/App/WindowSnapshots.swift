import AppKit
import ScreenCaptureKit

/// Captures DayPilot's own windows as they are drawn in the running application.
///
/// `--snapshot-windows <directory>` launches the real app, waits for its windows to
/// draw, writes a PNG of each titled window, walks the main window's tabs, opens
/// Settings the way ⌘, does, and captures that window too, then quits. The image is
/// the window server's composite of the window — what the user sees — with the app's
/// own layer rendering as a fallback when no Screen Recording permission has been
/// granted yet. `--snapshot-appearance light|dark` picks the appearance, and
/// `--preview-fixtures` fills the main window with sample content — a mid-session
/// console included — so the layout can be judged without depending on any real
/// session data.
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
            // Wait for the window rather than for a fixed interval: how long
            // SwiftUI takes to place one varies run to run, and a capture taken
            // before it exists silently records only the Settings window.
            try? await Task.sleep(for: .seconds(4))
            NSApp.activate(ignoringOtherApps: true)
            let start = CFAbsoluteTimeGetCurrent()
            let deadline = start + 30
            var placed = false
            while CFAbsoluteTimeGetCurrent() < deadline {
                if NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                    placed = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            print("Activation policy: \(NSApp.activationPolicy().rawValue) (0 = regular, Dock visible)")
            print(String(format: "Main window after %.1f s: %@ (%d window(s) known to AppKit)",
                         CFAbsoluteTimeGetCurrent() - start,
                         placed ? "placed" : "NOT placed",
                         NSApp.windows.count))

            // Present is not the same as drawn: give the window one pass to
            // render before the first capture.
            try? await Task.sleep(for: .seconds(1))

            // Capture the main window — Library tab.
            await captureTitledWindows(to: directory, label: "\(appearance)-library")

            // Switch to the Memory tab and capture.
            switchToMemoryTab()
            try? await Task.sleep(for: .seconds(1))
            await captureTitledWindows(to: directory, label: "\(appearance)-memory")

            // Open Settings and capture.
            openSettingsWindow()
            try? await Task.sleep(for: .seconds(2))
            await captureTitledWindows(to: directory, label: "\(appearance)-settings")

            // The snapshot process is a tool, not a user session: nothing to
            // close, nothing to flush, so exit directly. An unbundled process
            // does not reliably reach the application delegate through
            // `NSApp.terminate`, and this run must always end by itself.
            print("Snapshot capture complete — exiting")
            exit(EXIT_SUCCESS)
        }
    }

    /// Applies the requested appearance before any window exists.
    ///
    /// SwiftUI resolves its `colorScheme` — and every dynamic `Color(nsColor:)`
    /// with it — from the window's effective appearance *when the window is
    /// built*. Setting `NSApp.appearance` after that point updates only AppKit
    /// chrome (the title bar and toolbar): the SwiftUI content keeps the colors
    /// it resolved at build time, which is how a dark snapshot ends up with dark
    /// chrome wrapped around a white console capsule. This runs from
    /// `applicationWillFinishLaunching`, before the scene body is evaluated.
    @MainActor
    static func applyRequestedAppearanceEarly() {
        guard snapshotDirectory != nil else { return }
        NSApp.appearance = NSAppearance(named: snapshotAppearance == "dark" ? .darkAqua : .aqua)
    }

    /// Switches to Memory tab by driving the tab selection the model owns.
    ///
    /// The SwiftUI tab bar is not built from AppKit buttons, so walking the view
    /// tree for an `NSButton` titled "Memory" finds nothing and the second
    /// capture silently records the Library tab again. `AppModel.mainTab` is the
    /// single source of truth — the menu bar's Settings… command already drives
    /// it this way.
    @MainActor
    private static func switchToMemoryTab() {
        guard let model = LaunchHarness.snapshotModel else {
            print("Memory tab: the main window has not handed its model to the harness yet")
            return
        }
        model.mainTab = .memory
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
    ///
    /// The capture is the window server's composited image of the window, which is
    /// exactly what the user sees on screen. `cacheDisplay` was the previous path,
    /// and it is wrong for SwiftUI toolbars: the hosting views AppKit builds for
    /// toolbar items flush to an opaque white background when rendered through the
    /// layer tree, so a dark-mode window captured that way shows white pills where
    /// the real window shows a correctly dark toolbar. The composited image has no
    /// such artifact. `cacheDisplay` remains the fallback: it needs no Screen
    /// Recording permission, which matters when the app has not been granted it yet
    /// and the compositor returns nothing of its own window.
    @MainActor
    private static func captureTitledWindows(to directory: String, label: String) async {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            await captureWindow(window, to: output, label: label)
        }
    }

    /// The window as ScreenCaptureKit sees it — the same pixels the window server
    /// composites on screen — or nil when Screen Recording has not been granted,
    /// in which case the layer-tree path captures the app's own drawing instead.
    @MainActor
    private static func compositedPNG(for window: NSWindow) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { return nil }

        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
            configuration: configuration
        ) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Captures one window: composited when the window server provides the image,
    /// layer-tree rendering when it does not.
    @MainActor
    private static func captureWindow(_ window: NSWindow, to directory: URL, label: String) async {
        let title = window.title.isEmpty ? "untitled" : window.title.replacingOccurrences(of: " ", with: "-")
        let file = directory.appendingPathComponent("\(label)-\(title).png")

        if let png = await compositedPNG(for: window) {
            write(png, to: file)
            return
        }

        print("Composited capture unavailable for \"\(title)\" — falling back to layer rendering")
        guard let content = window.contentView else { return }

        // The frame view wraps the content view and also draws the title bar and
        // toolbar, so capturing it shows the window as the user sees it.
        let view = content.superview ?? content

        // Layout first, then draw: a window that has just appeared (Settings)
        // needs its subtrees positioned before `cacheDisplay` can render the
        // list- and form-backed content SwiftUI builds on AppKit containers.
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.displayIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        write(png, to: file)
    }

    /// Writes one capture and reports it.
    private static func write(_ png: Data, to file: URL) {
        do {
            try png.write(to: file)
            print("Captured \(file.lastPathComponent)")
        } catch {
            print("Could not write \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
