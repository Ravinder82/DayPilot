import Foundation

/// The runtime form of `.opencode/skills/daypilot-tracker/daypilot-tracker.config.json`.
///
/// The app reads its synthesis providers and voice settings from here at runtime
/// rather than baking them into code, because the whole point of the config file
/// is that switching provider (or adding a new free tier) is a one-line change
/// people make while the app ships untouched.
///
/// Decoding is deliberately defensive: a missing optional field falls back to a
/// sane default rather than failing the whole load, because a truncated config
/// must not take screen capture down with it.
struct SkillConfiguration: Sendable, Equatable {

    struct APIProviders: Sendable, Equatable {
        let defaultProviderID: String
        let providers: [AIProvider]
    }

    struct AIProvider: Sendable, Equatable, Identifiable {
        let id: String
        let label: String
        let baseURL: String
        let apiKeyEnvironmentVariable: String
        let model: String
        let temperature: Double
        let maxContextWindow: Int
        let costPerMillionInput: Double
        let isFreeTier: Bool

        /// Display string for logs and reports.
        var displayName: String { "\(label) (\(model))" }
    }

    struct Audio: Sendable, Equatable {
        let engine: String
        let preferredVoiceIdentifiers: [String]
        let rate: Float
        let pitchMultiplier: Float
        let voiceScriptStartTag: String
        let voiceScriptEndTag: String
    }

    let apiProviders: APIProviders
    let audio: Audio

    // MARK: - Defaults

    /// Used when the config file cannot be found or decoded at all, so the app
    /// still works standalone. Mirrors the shipped config exactly.
    static let fallback = SkillConfiguration(
        apiProviders: APIProviders(
            defaultProviderID: "google_ai_studio",
            providers: [
                .init(
                    id: "google_ai_studio",
                    label: "Google AI Studio (Gemini 2.0 Flash)",
                    baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
                    apiKeyEnvironmentVariable: "GEMINI_API_KEY",
                    model: "gemini-2.0-flash",
                    temperature: 0.3,
                    maxContextWindow: 1_048_576,
                    costPerMillionInput: 0,
                    isFreeTier: true
                ),
                .init(
                    id: "openrouter_free",
                    label: "OpenRouter Free Models",
                    baseURL: "https://openrouter.ai/api/v1",
                    apiKeyEnvironmentVariable: "OPENROUTER_API_KEY",
                    model: "meta-llama/llama-3.3-70b-instruct:free",
                    temperature: 0.4,
                    maxContextWindow: 131_072,
                    costPerMillionInput: 0,
                    isFreeTier: true
                ),
                .init(
                    id: "groq",
                    label: "Groq Fast Inference",
                    baseURL: "https://api.groq.com/openai/v1",
                    apiKeyEnvironmentVariable: "GROQ_API_KEY",
                    model: "llama-3.3-70b-versatile",
                    temperature: 0.3,
                    maxContextWindow: 128_000,
                    costPerMillionInput: 0,
                    isFreeTier: true
                ),
                .init(
                    id: "nvidia_nim",
                    label: "NVIDIA NIM Cloud",
                    baseURL: "https://integrate.api.nvidia.com/v1",
                    apiKeyEnvironmentVariable: "NVIDIA_API_KEY",
                    model: "meta/llama-3.3-70b-instruct",
                    temperature: 0.4,
                    maxContextWindow: 128_000,
                    costPerMillionInput: 0,
                    isFreeTier: true
                ),
                .init(
                    id: "deepseek",
                    label: "DeepSeek API",
                    baseURL: "https://api.deepseek.com/v1",
                    apiKeyEnvironmentVariable: "DEEPSEEK_API_KEY",
                    model: "deepseek-chat",
                    temperature: 0.3,
                    maxContextWindow: 64_000,
                    costPerMillionInput: 0.14,
                    isFreeTier: false
                )
            ]
        ),
        audio: Audio(
            engine: "macOS_AVSpeechSynthesizer",
            preferredVoiceIdentifiers: [
                "com.apple.voice.enhanced.en-US.Ava",
                "com.apple.voice.compact.en-US.Samantha",
                "com.apple.speech.synthesis.voice.Alex"
            ],
            rate: 0.52,
            pitchMultiplier: 1.0,
            voiceScriptStartTag: "[VOICE_SCRIPT]",
            voiceScriptEndTag: "[/VOICE_SCRIPT]"
        )
    )

    // MARK: - Provider lookup

    /// The provider the config nominates as the default.
    var defaultProvider: AIProvider? {
        apiProviders.providers.first { $0.id == apiProviders.defaultProviderID }
            ?? apiProviders.providers.first
    }

    /// The single provider whose API key is present in the environment.
    ///
    /// Preference order is explicit rather than config-driven because JSON
    /// objects are unordered by the time they reach Swift, and provider choice
    /// must be deterministic across launches.
    private static let providerPriority: [String] = [
        "google_ai_studio",
        "openrouter_free",
        "groq",
        "nvidia_nim",
        "deepseek"
    ]

    /// Every provider that currently has a usable key, best first.
    func availableProviders(environment: [String: String] = ProcessInfo.processInfo.environment) -> [AIProvider] {
        apiProviders.providers
            .filter { !$0.apiKeyEnvironmentVariable.isEmpty && environment[$0.apiKeyEnvironmentVariable]?.isEmpty == false }
            .sorted { lhs, rhs in
                let leftRank = Self.providerPriority.firstIndex(of: lhs.id) ?? Int.max
                let rightRank = Self.providerPriority.firstIndex(of: rhs.id) ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.id < rhs.id
            }
    }
}

// MARK: - Decoding

extension SkillConfiguration: Decodable {

    private enum CodingKeys: String, CodingKey {
        case apiProviders = "api_providers"
        case audio = "audio_synthesis"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiProviders = try container.decodeIfPresent(APIProviders.self, forKey: .apiProviders)
            ?? Self.fallback.apiProviders
        audio = try container.decodeIfPresent(Audio.self, forKey: .audio) ?? Self.fallback.audio
    }
}

extension SkillConfiguration.APIProviders: Decodable {

    private enum CodingKeys: String, CodingKey {
        case defaultProviderID = "default_provider"
        case providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultProviderID = try container.decodeIfPresent(String.self, forKey: .defaultProviderID) ?? ""
        let raw = try container.decodeIfPresent([String: WireProvider].self, forKey: .providers) ?? [:]

        providers = raw.compactMap { key, wire in
            guard let url = URL(string: wire.baseURL), !url.scheme.isNilOrEmpty else { return nil }
            return SkillConfiguration.AIProvider(
                id: key,
                label: wire.label ?? key,
                baseURL: wire.baseURL,
                apiKeyEnvironmentVariable: wire.apiKeyEnvironmentVariable,
                model: wire.model,
                temperature: wire.temperature ?? 0.3,
                maxContextWindow: wire.maxContextWindow ?? 32_768,
                costPerMillionInput: wire.costPerMillionInput ?? 0,
                isFreeTier: wire.isFreeTier ?? false
            )
        }
    }

    /// Wire form of a provider. Every field but the endpoint and key variable is
    /// optional so a hand-edited config still loads.
    private struct WireProvider: Decodable {
        let label: String?
        let baseURL: String
        let apiKeyEnvironmentVariable: String
        let model: String

        let temperature: Double?
        let maxContextWindow: Int?
        let costPerMillionInput: Double?
        let isFreeTier: Bool?

        private enum CodingKeys: String, CodingKey {
            case label
            case baseURL = "base_url"
            case apiKeyEnvironmentVariable = "api_key_env"
            case model
            case temperature
            case maxContextWindow = "max_context_window"
            case costPerMillionInput = "cost_per_million_input"
            case isFreeTier = "is_free_tier"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            baseURL = try container.decode(String.self, forKey: .baseURL)
            apiKeyEnvironmentVariable = try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironmentVariable) ?? ""
            model = try container.decode(String.self, forKey: .model)
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            maxContextWindow = try container.decodeIfPresent(Int.self, forKey: .maxContextWindow)
            costPerMillionInput = try container.decodeIfPresent(Double.self, forKey: .costPerMillionInput)
            isFreeTier = try container.decodeIfPresent(Bool.self, forKey: .isFreeTier)
        }
    }
}

extension SkillConfiguration.Audio: Decodable {

    private enum CodingKeys: String, CodingKey {
        case engine
        case preferredVoiceIdentifiers = "voice_identifiers"
        case rate
        case pitchMultiplier = "pitch_multiplier"
        case delimiterTags = "delimiter_tags"
        case start = "start"
        case end = "end"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? "macOS_AVSpeechSynthesizer"
        preferredVoiceIdentifiers = try container.decodeIfPresent([String].self, forKey: .preferredVoiceIdentifiers) ?? []
        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? 0.52
        pitchMultiplier = try container.decodeIfPresent(Float.self, forKey: .pitchMultiplier) ?? 1.0

        if let tags = try container.decodeIfPresent(
            Delimiters.self,
            forKey: .delimiterTags
        ) {
            voiceScriptStartTag = tags.start
            voiceScriptEndTag = tags.end
        } else {
            voiceScriptStartTag = "[VOICE_SCRIPT]"
            voiceScriptEndTag = "[/VOICE_SCRIPT]"
        }
    }

    private struct Delimiters: Decodable {
        let start: String
        let end: String
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

// MARK: - Discovery

/// Finds and decodes the skill config wherever it happens to live.
///
/// The file lives in the repository during development, which means it is not
/// in the app bundle once the app is packaged. Rather than pick one location,
/// this walks a list of candidates so the same binary works from the repo, from
/// a bundle, and from a user-installed copy.
enum SkillConfigurationLoader {

    private static let relativePath = ".opencode/skills/daypilot-tracker/daypilot-tracker.config.json"
    private static let fileName = "daypilot-tracker.config.json"

    /// Loads the config, falling back to built-in defaults.
    ///
    /// Never throws: a missing or malformed config must degrade to defaults
    /// rather than take the app down.
    static func load() -> (configuration: SkillConfiguration, source: Source) {
        if let explicit = ProcessInfo.processInfo.environment["DAYPILOT_CONFIG"],
           let url = URL(string: explicit),
           let decoded = decode(at: url) {
            return (decoded, .explicit(url))
        }

        for url in candidateURLs() {
            if let decoded = decode(at: url) {
                return (decoded, .discovered(url))
            }
        }
        return (SkillConfiguration.fallback, .builtIn)
    }

    enum Source: Equatable {
        case explicit(URL)
        case discovered(URL)
        case builtIn

        var description: String {
            switch self {
            case .explicit(let url): return "DAYPILOT_CONFIG → \(url.path)"
            case .discovered(let url): return url.path
            case .builtIn: return "built-in defaults (no config file found)"
            }
        }
    }

    private static func decode(at url: URL) -> SkillConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = FileManager.default.contents(atPath: url.path),
              let decoded = try? JSONDecoder().decode(SkillConfiguration.self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func candidateURLs() -> [URL] {
        var candidates: [URL] = []

        // A user-installed override beside the rest of DayPilot's data.
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(DayPilotConfiguration.memoryDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        candidates.append(appSupport)

        // The copy packaged inside the app, so an installed copy is configured the
        // same way the repository is, instead of falling back to built-in defaults.
        if let packaged = Bundle.main.url(forResource: "daypilot-tracker.config", withExtension: "json") {
            candidates.append(packaged)
        }

        // Walk up from the executable and from any argument that looks like a
        // path, which covers `make run` (.build/release/DayPilot), a bundle
        // (…/Contents/MacOS/DayPilot) and running from the repo root.
        var roots: [URL] = [Bundle.main.executableURL.flatMap { $0.deletingLastPathComponent() }].compactMap { $0 }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        for root in roots where root.path != "/" {
            var current = root
            for _ in 0..<5 {
                candidates.append(current.appendingPathComponent(relativePath))
                guard current.path != "/" else { break }
                current = current.deletingLastPathComponent()
            }
        }

        // Duplicate URLs are harmless but make the search order non-obvious.
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
