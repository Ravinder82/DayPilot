import AppKit
import ApplicationServices
import os

/// Reads the frontmost application and its focused window through the
/// Accessibility API.
///
/// The Accessibility API is the only supported way to get the *focused* window
/// title — `NSWorkspace` alone only tells you which app is active, not which of
/// its windows the user is working in. Permission is requested lazily: the
/// first call prompts, subsequent calls are quiet.
@MainActor
final class WindowManager {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "window")

    /// Bounds on the address-bar search so a hostile or pathological AX tree
    /// can never turn into an unbounded walk.
    private static let maximumSearchDepth = 4
    private static let maximumSearchNodes = 256

    /// What the user was looking at at the moment of a capture.
    struct FocusedSurface: Sendable {
        let appName: String
        let bundleIdentifier: String
        let processIdentifier: Int32
        let windowTitle: String
        let addressBarText: String?
        let isSuppressed: Bool
        let suppressionReason: String?
        let ephemeral: EphemeralClassification
    }

    /// Snapshots the frontmost application.
    ///
    /// Returns `nil` when the frontmost application cannot be determined, which
    /// happens briefly during login and full-screen transitions.
    func frontmostSurface() -> FocusedSurface? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleIdentifier = application.bundleIdentifier ?? "unknown"
        let appName = application.localizedName ?? bundleIdentifier
        let pid = application.processIdentifier

        // Touch the Accessibility API only when it is already trusted. Calling
        // it while untrusted raises the system consent dialog, which blocks the
        // session start; without trust the capture still works, it just has no
        // window title.
        let axAvailable = AXIsProcessTrusted()
        let windowTitle = axAvailable ? (Self.focusedWindowTitle(processIdentifier: pid) ?? "") : ""
        let addressBarText = axAvailable ? Self.addressBarText(processIdentifier: pid) : nil

        let suppressionReason = SensitiveAppShield.suppressionReason(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            addressBarText: addressBarText
        )

        return FocusedSurface(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: pid,
            windowTitle: windowTitle,
            addressBarText: addressBarText,
            isSuppressed: suppressionReason != nil,
            suppressionReason: suppressionReason,
            ephemeral: EphemeralSurfaceClassifier.classify(
                bundleIdentifier: bundleIdentifier,
                addressBarText: addressBarText
            )
        )
    }

    /// `kAXTrustedCheckOptionPrompt` is a shared global in HIServices, which
    /// strict concurrency checking flags. The API's key is documented as the
    /// literal `"AXTrustedCheckOptionPrompt"`, so referencing the string avoids
    /// the global entirely.
    private static let axTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

    /// Silent trust check — never prompts. Session start uses this so pressing
    /// Start can never raise a system dialog; window titles simply stay empty
    /// until the user grants access in System Settings.
    @discardableResult
    func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            logger.notice("Accessibility permission not granted — window titles unavailable")
        }
        return trusted
    }

    /// Deliberate, user-initiated prompt. Call only from a visible "Grant…"
    /// action so the dialog always follows an explicit click.
    @discardableResult
    static func requestAccessibilityPermissionPrompt() -> Bool {
        let options = [axTrustedCheckOptionPrompt: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Accessibility plumbing

    private static func focusedWindowTitle(processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              let windowElement = windowValue as! AXUIElement? else {
            return nil
        }

        return stringAttribute(kAXTitleAttribute as CFString, of: windowElement)
    }

    /// Best-effort address bar read.
    ///
    /// Strategy one is `AXDocument`, which browsers set to the page URL. If
    /// that fails, walk the window tree looking for the address text field and
    /// read its value. Either way, `nil` is a normal outcome.
    private static func addressBarText(processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              let windowElement = windowValue as! AXUIElement? else {
            return nil
        }

        if let document = stringAttribute(kAXDocumentAttribute as CFString, of: windowElement),
           EphemeralSurfaceClassifier.host(from: document) != nil {
            return document
        }

        return searchForAddressBar(element: windowElement, depth: 0, visited: 0).1
    }

    /// Breadth-first search for the address text field.
    ///
    /// Returns the field's value plus the number of nodes visited, so the
    /// traversal stays bounded on pathological AX trees.
    private static func searchForAddressBar(
        element: AXUIElement,
        depth: Int,
        visited remaining: Int
    ) -> (Int, String?) {
        guard depth <= maximumSearchDepth, remaining < maximumSearchNodes else {
            return (remaining, nil)
        }
        var consumed = remaining + 1

        if let role = stringAttribute(kAXRoleAttribute as CFString, of: element),
           role == (kAXTextFieldRole as String),
           let description = stringAttribute(kAXDescriptionAttribute as CFString, of: element),
           Self.isAddressBarDescription(description),
           let value = stringAttribute(kAXValueAttribute as CFString, of: element),
           !value.isEmpty {
            return (consumed, value)
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return (consumed, nil)
        }

        for child in children {
            let (next, match) = searchForAddressBar(
                element: child,
                depth: depth + 1,
                visited: consumed
            )
            consumed = next
            if let match {
                return (consumed, match)
            }
        }
        return (consumed, nil)
    }

    private static func isAddressBarDescription(_ description: String) -> Bool {
        let normalized = description.lowercased()
        return normalized.contains("address")
            || normalized.contains("search or enter")
    }

    private static func stringAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }
}
