import Foundation
import os

/// What DayPilot knows about a model's price.
///
/// Three states, because "unknown" is the honest answer for most
/// OpenAI-compatible endpoints, which do not publish prices from `/models`. An
/// unknown price is never filed under "Free": treating it as free would let
/// someone spend a paid key believing it was free.
enum PriceTier: String, Codable, Sendable, Equatable {
    case free
    case paid
    case unknown

    var sortRank: Int {
        switch self {
        case .free: return 0
        case .paid: return 1
        case .unknown: return 2
        }
    }
}

/// A model a provider offers, as it appears in Settings.
struct AIModel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let label: String
    let price: PriceTier
    let contextWindow: Int?

    /// Free first, then paid, then unknown. Within a tier, the largest context
    /// window comes first, then the id, so the order never shuffles between runs.
    static func precedes(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
        if lhs.price.sortRank != rhs.price.sortRank {
            return lhs.price.sortRank < rhs.price.sortRank
        }
        let left = lhs.contextWindow ?? 0
        let right = rhs.contextWindow ?? 0
        if left != right { return left > right }
        return lhs.id < rhs.id
    }
}

/// Discovers the models a provider offers, live, with a curated fallback.
///
/// Providers add and retire models constantly, so a list shipped inside the app
/// is stale the day it ships. Every OpenAI-compatible service answers
/// `GET /models`, so the catalogue is read from the provider itself.
enum ModelCatalog {

    private static let logger = Logger(subsystem: AppInfo.identifier, category: "models")
    private static let cacheFileName = "model_catalog.json"

    /// The models a provider offers now. Never throws.
    ///
    /// The live list wins. Where a provider does not publish a price, the
    /// curated price for the same model id is used. If the provider cannot be
    /// reached, the last successful list is used, then the curated list, so the
    /// picker is only empty for providers DayPilot knows nothing about.
    static func models(for provider: SkillConfiguration.AIProvider) async -> [AIModel] {
        let curated = bundled(provider: provider)
        let live = await fetch(provider: provider)

        if !live.isEmpty {
            let merged = merge(live: live, curated: curated)
            store(merged, for: provider.id)
            return merged.sorted(by: AIModel.precedes)
        }

        let remembered = storedModels(for: provider.id)
        if !remembered.isEmpty {
            return remembered.sorted(by: AIModel.precedes)
        }
        return curated.sorted(by: AIModel.precedes)
    }

    /// Curated models and documented prices for the built-in providers.
    ///
    /// A price is only written here where the provider documents it. Custom
    /// endpoints have no curated list and rely on what their `/models` returns.
    static func bundled(provider: SkillConfiguration.AIProvider) -> [AIModel] {
        switch provider.id {
        case "google_ai_studio":
            return [
                AIModel(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash", price: .free, contextWindow: 1_048_576),
                AIModel(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro", price: .unknown, contextWindow: 1_048_576),
                AIModel(id: "gemini-1.5-flash", label: "Gemini 1.5 Flash", price: .free, contextWindow: 1_048_576)
            ]
        case "openrouter_free":
            return [
                AIModel(id: "meta-llama/llama-3.3-70b-instruct:free", label: "Llama 3.3 70B Instruct", price: .free, contextWindow: 131_072),
                AIModel(id: "deepseek/deepseek-chat:free", label: "DeepSeek Chat V3", price: .free, contextWindow: 64_000),
                AIModel(id: "google/gemini-2.0-flash-exp:free", label: "Gemini 2.0 Flash (experimental)", price: .free, contextWindow: 1_048_576),
                AIModel(id: "qwen/qwen-2.5-72b-instruct:free", label: "Qwen 2.5 72B Instruct", price: .free, contextWindow: 131_072),
                AIModel(id: "openai/gpt-4o-mini", label: "GPT-4o mini", price: .paid, contextWindow: 128_000),
                AIModel(id: "openai/gpt-4o", label: "GPT-4o", price: .paid, contextWindow: 128_000),
                AIModel(id: "anthropic/claude-3.5-sonnet", label: "Claude 3.5 Sonnet", price: .paid, contextWindow: 200_000)
            ]
        case "groq":
            return [
                AIModel(id: "llama-3.3-70b-versatile", label: "Llama 3.3 70B Versatile", price: .free, contextWindow: 128_000),
                AIModel(id: "llama-3.1-8b-instant", label: "Llama 3.1 8B Instant", price: .free, contextWindow: 128_000),
                AIModel(id: "openai/gpt-oss-120b", label: "GPT-OSS 120B", price: .free, contextWindow: 128_000),
                AIModel(id: "openai/gpt-oss-20b", label: "GPT-OSS 20B", price: .free, contextWindow: 128_000)
            ]
        case "nvidia_nim":
            return [
                AIModel(id: "meta/llama-3.3-70b-instruct", label: "Llama 3.3 70B Instruct", price: .unknown, contextWindow: 128_000),
                AIModel(id: "meta/llama-3.1-405b-instruct", label: "Llama 3.1 405B Instruct", price: .unknown, contextWindow: 128_000),
                AIModel(id: "mistralai/mixtral-8x22b-instruct-v0.1", label: "Mixtral 8x22B Instruct", price: .unknown, contextWindow: 65_536)
            ]
        case "deepseek":
            return [
                AIModel(id: "deepseek-chat", label: "DeepSeek Chat (V3)", price: .paid, contextWindow: 64_000),
                AIModel(id: "deepseek-reasoner", label: "DeepSeek Reasoner (R1)", price: .paid, contextWindow: 64_000)
            ]
        default:
            return []
        }
    }

    // MARK: - Fetching

    private static func fetch(provider: SkillConfiguration.AIProvider) async -> [AIModel] {
        guard let url = URL(string: modelsURL(for: provider.baseURL)) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let key = apiKey(for: provider)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            logger.info("Model list unavailable for \(provider.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        guard let envelope = try? JSONDecoder().decode(ModelsEnvelope.self, from: data) else {
            logger.info("Model list for \(provider.id, privacy: .public) was not in the expected shape")
            return []
        }
        return envelope.data.compactMap { $0.value }.compactMap(makeModel(from:))
    }

    private static func modelsURL(for baseURL: String) -> String {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return trimmed + "/models"
    }

    /// The key to list models with: the Keychain first, then the environment.
    private static func apiKey(for provider: SkillConfiguration.AIProvider) -> String {
        if let stored = KeychainManager.getKey(for: provider.id), !stored.isEmpty {
            return stored
        }
        guard !provider.apiKeyEnvironmentVariable.isEmpty else { return "" }
        return ProcessInfo.processInfo.environment[provider.apiKeyEnvironmentVariable] ?? ""
    }

    private static func makeModel(from wire: WireModel) -> AIModel? {
        // Google's OpenAI-compatible endpoint names models "models/<id>", but chat
        // completions take the bare id. The listed id must be the id that is sent.
        let id = wire.id.hasPrefix("models/") ? String(wire.id.dropFirst("models/".count)) : wire.id
        guard !id.isEmpty else { return nil }

        let label = (wire.name?.isEmpty == false ? wire.name : nil) ?? id
        return AIModel(
            id: id,
            label: label,
            price: priceTier(for: wire),
            contextWindow: wire.contextWindow
        )
    }

    /// Free when the provider says so: an explicit `:free` id, or every published
    /// rate at zero. Paid when any rate is above zero. Otherwise unknown.
    private static func priceTier(for wire: WireModel) -> PriceTier {
        if wire.id.hasSuffix(":free") { return .free }
        guard let pricing = wire.pricing else { return .unknown }
        let rates = [pricing.prompt, pricing.completion].compactMap { $0 }
        guard !rates.isEmpty else { return .unknown }
        return rates.allSatisfy { $0 == 0 } ? .free : .paid
    }

    /// The live list, with curated prices filling in what the provider omits.
    private static func merge(live: [AIModel], curated: [AIModel]) -> [AIModel] {
        let reference = Dictionary(curated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return live.map { model in
            guard let known = reference[model.id] else { return model }
            return AIModel(
                id: model.id,
                label: model.label == model.id ? known.label : model.label,
                price: model.price == .unknown ? known.price : model.price,
                contextWindow: model.contextWindow ?? known.contextWindow
            )
        }
    }

    // MARK: - Cache

    private static func storedModels(for providerID: String) -> [AIModel] {
        readCache()[providerID] ?? []
    }

    private static func store(_ models: [AIModel], for providerID: String) {
        var cache = readCache()
        cache[providerID] = models
        guard let data = try? JSONEncoder().encode(cache) else { return }

        let url = cacheURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.info("Could not cache the model list: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readCache() -> [String: [AIModel]] {
        guard let data = FileManager.default.contents(atPath: cacheURL().path),
              let cache = try? JSONDecoder().decode([String: [AIModel]].self, from: data) else {
            return [:]
        }
        return cache
    }

    private static func cacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(DayPilotConfiguration.memoryDirectoryName, isDirectory: true)
            .appendingPathComponent(cacheFileName)
    }
}

// MARK: - Wire format

private extension ModelCatalog {

    struct ModelsEnvelope: Decodable {
        let data: [Lossy<WireModel>]
    }

    /// Decodes one element, or nothing, so a single malformed entry in a long
    /// catalogue cannot discard the rest of it.
    struct Lossy<Element: Decodable>: Decodable {
        let value: Element?

        init(from decoder: Decoder) throws {
            value = try? Element(from: decoder)
        }
    }

    struct WireModel: Decodable {

        struct Pricing: Decodable {
            let prompt: Double?
            let completion: Double?

            private enum Keys: String, CodingKey {
                case prompt
                case completion
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                prompt = Pricing.rate(in: container, for: .prompt)
                completion = Pricing.rate(in: container, for: .completion)
            }

            /// Providers publish rates as numbers or as strings; both are accepted.
            private static func rate(in container: KeyedDecodingContainer<Keys>, for key: Keys) -> Double? {
                if let number = try? container.decodeIfPresent(Double.self, forKey: key) {
                    return number
                }
                if let text = try? container.decodeIfPresent(String.self, forKey: key) {
                    return Double(text)
                }
                return nil
            }
        }

        private struct TopProvider: Decodable {
            let contextLength: Int?

            private enum Keys: String, CodingKey {
                case contextLength = "context_length"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                contextLength = try? container.decodeIfPresent(Int.self, forKey: .contextLength)
            }
        }

        let id: String
        let name: String?
        let pricing: Pricing?
        let contextWindow: Int?

        private enum Keys: String, CodingKey {
            case id
            case name
            case pricing
            case contextLength = "context_length"
            case contextWindow = "context_window"
            case topProvider = "top_provider"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            pricing = try? container.decodeIfPresent(Pricing.self, forKey: .pricing)

            // Providers disagree on where the window is reported: OpenRouter uses
            // `context_length`, Groq uses `context_window`, and some nest it.
            let nested = try? container.decodeIfPresent(TopProvider.self, forKey: .topProvider)
            contextWindow = WireModel.window(in: container) ?? nested?.contextLength
        }

        private static func window(in container: KeyedDecodingContainer<Keys>) -> Int? {
            for key in [Keys.contextLength, Keys.contextWindow] {
                if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return value
                }
            }
            return nil
        }
    }
}
