// swift-tools-version: 6.0
//
// DayPilot — native macOS app: a windowed library and editor, with a menu bar item.
//
// Toolchain notes (read before "cleaning up"):
//   • macOS 14.0 is the deployment floor because ScreenCaptureKit's
//     SCShareableContent content-sharing APIs and Vision's ANE-backed
//     VNRecognizeTextRequest are stable and shipping from Sonoma onward.
//   • The target stays on Swift language mode 5 with
//     `-strict-concurrency=complete`. That keeps every isolation decision
//     (Sendable, MainActor, actor hops) enforced at compile time while the
//     ScreenCaptureKit + AVSpeechSynthesizer pipeline is built out, instead of
//     surfacing the whole codebase as hard errors the moment a phase lands.
//   • All frameworks are linked explicitly so the binary is self-describing
//     and never relies on implicit module-to-framework resolution.
//   • SQLite comes from the system via a system-library target rather than a
//     package dependency, so DayPilot has zero network dependencies and the
//     binary tracks Apple's own SQLite security updates.
import PackageDescription

let package = Package(
    name: "DayPilot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DayPilot", targets: ["DayPilot"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(
            name: "DayPilot",
            dependencies: ["CSQLite"],
            // The binary is the whole Sources tree, laid out by module.
            // `CSQLite` is excluded because it is a system library target
            // with its own module map, not Swift sources.
            path: "Sources",
            exclude: ["CSQLite"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-strict-concurrency=complete"])
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
