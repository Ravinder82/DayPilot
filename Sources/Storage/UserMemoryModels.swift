import Foundation

/// The persistent first-person identity DayPilot carries about its user.
///
/// This is deliberately written from the user's point of view — it is the
/// app's self-understanding of who it is working for — and it accumulates
/// across sessions rather than being regenerated each day.
struct UserMemoryProfile: Codable, Sendable, Equatable {

    struct UserIdentity: Codable, Sendable, Equatable {
        var role: String
        var coreStack: [String]
        var ecosystems: [String]
    }

    struct AppPurposeAndMandate: Codable, Sendable, Equatable {
        var whatDayPilotDoesForMe: String
        var trackingPhilosophy: String
    }

    struct ActiveProject: Codable, Sendable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        var type: String
        var status: String
        var objective: String
    }

    struct CognitiveProfile: Codable, Sendable, Equatable {
        var peakFlowWindow: String
        var frictionPatterns: [String]
        var creativeHabits: [String]
    }

    struct SessionTelemetrySummary: Codable, Sendable, Equatable {
        var totalSessionsCompleted: Int
        var totalHoursTracked: Double
        var totalBreadcrumbsHarvested: Int
        var lastSessionTimestamp: String?
    }

    var userIdentity: UserIdentity
    var appPurposeAndMandate: AppPurposeAndMandate
    var activeProjects: [ActiveProject]
    var cognitiveProfile: CognitiveProfile
    var cumulativeRulesOfThumb: [String]
    var sessionTelemetrySummary: SessionTelemetrySummary
}

// MARK: - Seed

extension UserMemoryProfile {

    /// The file daypilot writes on first launch.
    ///
    /// It is intentionally explicit about the mandate ("executive partner",
    /// "noise killer") because `exportContextForPrompt()` is injected straight
    /// into the synthesis model's system prompt: the seed doubles as the
    /// standing instructions the model reads every day.
    static let seed = UserMemoryProfile(
        userIdentity: .init(
            role: "Indie Software Developer & Product Builder",
            coreStack: ["Swift", "SwiftUI", "React Native", "Expo", "TypeScript", "Python"],
            ecosystems: ["iOS / App Store Connect", "RevenueCat", "Apple Silicon", "AI APIs & MCP"]
        ),
        appPurposeAndMandate: .init(
            whatDayPilotDoesForMe: """
            Acts as my executive partner, mentor, noise killer, and creative breadcrumb harvester. \
            It watches my work sessions between Start and Stop, discards passive digital noise, \
            and packages loose thoughts into concrete shippable assets.
            """,
            trackingPhilosophy: """
            Passive capture via Neural Engine OCR. Zero video storage. Zero surveillance creep. \
            High-density synthesis only.
            """
        ),
        activeProjects: [
            .init(
                name: "DayPilot",
                type: "macOS Native Menu Bar Tool",
                status: "In Active Development",
                objective: "Ship standalone lightweight menu bar productivity agent"
            )
        ],
        cognitiveProfile: .init(
            peakFlowWindow: "Morning / Early Afternoon",
            frictionPatterns: [
                "Over-debugging compiler warnings",
                "Browsing X/Twitter instead of core shipping"
            ],
            creativeHabits: [
                "Drafting hooks in Stickies",
                "Testing prompts in AI Studio and closing tabs"
            ]
        ),
        cumulativeRulesOfThumb: [
            "Always resolve actor isolation warnings at class boundaries rather than async callback wraps.",
            "Never let transient ideas die in closed browser tabs; harvest them immediately."
        ],
        sessionTelemetrySummary: .init(
            totalSessionsCompleted: 0,
            totalHoursTracked: 0.0,
            totalBreadcrumbsHarvested: 0,
            lastSessionTimestamp: nil
        )
    )
}
