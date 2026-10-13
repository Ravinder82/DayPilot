import Foundation

/// Static build identity.
///
/// The SPM executable ships unbundled, so `Bundle.main` carries no
/// `Info.plist` at runtime; the packaged `.app` overrides every one of these
/// values from `Resources/Info.plist`. Anything that needs an identity (status
/// bar, unified-logging subsystem, report header) reads it from here.
enum AppInfo {

    /// Base bundle identifier, also used as the unified-logging subsystem.
    static let identifier = "com.daypilot.app"

    /// Product name shown in the status bar and reports.
    static let name = "DayPilot"

    /// Marketing version reported by the health check.
    static let version = "1.0.0"

    /// Deployment floor, mirrored by `Package.swift` and `Info.plist`.
    static let minimumOSVersion = "14.0"

    /// Deployment floor as an integer, used by the OS probe.
    static let minimumOSMajor = 14
}
