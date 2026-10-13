import Foundation

/// Failures specific to launching a diagnostic mode.
enum LaunchHarnessError: LocalizedError {
    case notReady
    case storesUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            "DayPilot's subsystems are not ready yet."
        case .storesUnavailable(let message):
            "DayPilot could not open its stores: \(message)"
        }
    }
}
