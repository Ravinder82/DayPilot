import Foundation

/// A user-defined OpenAI-compatible endpoint, entered in Settings.
///
/// Any service that speaks `/chat/completions` and `/models` works: a hosted
/// aggregator, a self-hosted server, a local model runner. The API key lives in
/// the Keychain under `id`, exactly like the built-in providers, so the rest of
/// the pipeline cannot tell a custom endpoint from a configured one.
struct CustomProviderProfile: Codable, Sendable, Identifiable, Equatable {
    let id: String
    var label: String
    var baseURL: String

    /// The provider value the synthesis and catalogue code consume. The model is
    /// deliberately empty: a custom endpoint has no default, and the user's
    /// choice is applied as an override.
    var provider: SkillConfiguration.AIProvider {
        SkillConfiguration.AIProvider(
            id: id,
            label: label,
            baseURL: baseURL,
            apiKeyEnvironmentVariable: "",
            model: "",
            temperature: 0.3,
            maxContextWindow: 128_000,
            costPerMillionInput: 0,
            isFreeTier: false
        )
    }
}

enum CustomProviderError: LocalizedError {
    case emptyName
    case duplicateName(String)
    case invalidURL
    case insecureURL

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Give the provider a name, such as the service's own name."
        case .duplicateName(let name):
            return "A provider called \"\(name)\" already exists."
        case .invalidURL:
            return "The base URL is not valid. It should look like https://api.example.com/v1"
        case .insecureURL:
            return "Use an https:// address. Plain http is accepted only for localhost, because the API key would otherwise travel unencrypted."
        }
    }
}

/// Persists custom providers in `UserDefaults`, and validates what is entered.
enum CustomProviderStore {

    private static let defaultsKey = "settings.customProviders"

    static func profiles(defaults: UserDefaults = .standard) -> [CustomProviderProfile] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomProviderProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    @discardableResult
    static func add(label: String, baseURL: String, defaults: UserDefaults = .standard) throws -> CustomProviderProfile {
        let existing = profiles(defaults: defaults)
        let name = try validatedName(label, among: existing, excluding: nil)
        let endpoint = try normalisedEndpoint(baseURL)

        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let profile = CustomProviderProfile(id: "custom_" + suffix, label: name, baseURL: endpoint)
        save(existing + [profile], defaults: defaults)
        return profile
    }

    @discardableResult
    static func update(
        _ existing: CustomProviderProfile,
        label: String,
        baseURL: String,
        defaults: UserDefaults = .standard
    ) throws -> CustomProviderProfile {
        let all = profiles(defaults: defaults)
        let name = try validatedName(label, among: all, excluding: existing.id)
        let endpoint = try normalisedEndpoint(baseURL)

        let updated = CustomProviderProfile(id: existing.id, label: name, baseURL: endpoint)
        save(all.map { $0.id == existing.id ? updated : $0 }, defaults: defaults)
        return updated
    }

    static func remove(id: String, defaults: UserDefaults = .standard) {
        save(profiles(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    /// Accepts what people actually paste: a bare host gets `https://`, trailing
    /// slashes are dropped, and plain `http` is refused unless it is local.
    static func normalisedEndpoint(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CustomProviderError.invalidURL }
        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }

        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw CustomProviderError.invalidURL
        }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw CustomProviderError.insecureURL
        }
        return text
    }

    private static func validatedName(
        _ raw: String,
        among existing: [CustomProviderProfile],
        excluding id: String?
    ) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CustomProviderError.emptyName }
        let clash = existing.contains { profile in
            profile.id != id && profile.label.caseInsensitiveCompare(name) == .orderedSame
        }
        guard !clash else { throw CustomProviderError.duplicateName(name) }
        return name
    }

    private static func save(_ profiles: [CustomProviderProfile], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

extension SkillConfiguration {
    /// Every provider the user can choose: the configured ones, then the custom ones.
    func allProviders(customProfiles: [CustomProviderProfile] = CustomProviderStore.profiles()) -> [AIProvider] {
        apiProviders.providers + customProfiles.map(\.provider)
    }
}
