import Foundation

/// A provider plus the key that makes it usable, resolved from the skill
/// configuration and the environment.
struct ResolvedAPIProvider: Sendable, Equatable {
    let provider: SkillConfiguration.AIProvider
    let apiKey: String
    /// Truncated key, for logs and reports only.
    var maskedKey: String {
        guard apiKey.count > 8 else { return "****" }
        return "\(apiKey.prefix(4))…\(apiKey.suffix(4))"
    }
}

/// Everything the speech and synthesis layers need to know about the session
/// that just finished. Built once by the coordinator and reused for the report
/// header, the archive filename and the memory update.
struct SessionCompletionContext: Sendable, Equatable {
    let sessionId: String
    let startedAt: Date
    let stoppedAt: Date
    let eventCount: Int
    let breadcrumbCount: Int
    let suppressedFrameCount: Int

    var durationSeconds: TimeInterval { stoppedAt.timeIntervalSince(startedAt) }
}

/// Failures that are the caller's fault to fix, as opposed to transient.
enum APIClientError: LocalizedError {

    /// No provider had a key in the Keychain or the environment.
    ///
    /// `hint` carries the specific next step — which providers the Keychain does
    /// hold, or the variable to export — because "missing key" with no guidance
    /// is the one error a user cannot act on.
    case missingAPIKey(
        provider: String,
        environmentVariable: String,
        hint: String = ""
    )

    /// The 2xx path returned something unreadable.
    case parsingError(String)

    /// A non-2xx response, with the server's own message where available.
    case networkError(statusCode: Int, message: String, hint: String = "")

    /// The 2xx response had no usable choices array.
    case emptyResponse

    /// Transport-level failure (DNS, TLS, connection reset, timeout).
    case transportFailure(String)

    /// No model was chosen for the provider, so there is nothing to send.
    case noModelSelected(provider: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider, let variable, let hint):
            let guidance = hint.isEmpty
                ? "Export \(variable) in your environment, or add a key in Settings."
                : hint
            return "No API key for \(provider). \(guidance)"
        case .parsingError(let detail):
            return "The API response could not be parsed: \(detail)"
        case .networkError(let statusCode, let message, let hint):
            let base = "The API returned HTTP \(statusCode): \(message)"
            return hint.isEmpty ? base : "\(base) — \(hint)"
        case .emptyResponse:
            return "The API returned a 200 response with no choices"
        case .transportFailure(let detail):
            return "The API request failed: \(detail)"
        case .noModelSelected(let provider):
            return "No model is chosen for \(provider). Pick one in Settings, or type its model ID."
        }
    }

    /// Adds actionable advice to a missing-key error.
    ///
    /// Only a missing-key error can carry a hint; anything else is returned
    /// untouched rather than being silently rewritten into the wrong failure.
    func withHint(_ hint: String) -> APIClientError {
        guard !hint.isEmpty,
              case .missingAPIKey(let provider, let variable, _) = self else {
            return self
        }
        return .missingAPIKey(
            provider: provider,
            environmentVariable: variable,
            hint: hint
        )
    }

    /// True for failures a retry could fix.
    var isRetryable: Bool {
        switch self {
        case .transportFailure: return true
        case .networkError(let statusCode, _, _):
            return statusCode == 408 || statusCode == 429 || statusCode >= 500
        default: return false
        }
    }
}

/// Minimal client for the OpenAI-compatible `/chat/completions` endpoint.
///
/// The OpenAI wire format is the lingua franca of every provider DayPilot
/// speaks to — Google AI Studio, OpenRouter, Groq, NVIDIA NIM and DeepSeek all
/// expose it — so one implementation covers them all and switching provider is
/// a config change rather than a code change.
///
/// `URLSession`'s async APIs run on a cooperative thread, never the main actor,
/// so a slow synthesis cannot stall the menu bar.
struct APIClient {

    let provider: ResolvedAPIProvider
    let audioVoiceTags: (start: String, end: String)
    let requestTimeout: TimeInterval

    /// The model to send. Overrides the provider default, which is how the
    /// Settings model picker actually takes effect.
    let modelOverride: String?
    private let session: URLSession

    init(
        provider: ResolvedAPIProvider,
        voiceScriptStartTag: String,
        voiceScriptEndTag: String,
        modelOverride: String? = nil,
        timeout: TimeInterval = 180
    ) {
        self.provider = provider
        audioVoiceTags = (voiceScriptStartTag, voiceScriptEndTag)
        requestTimeout = timeout
        self.modelOverride = modelOverride

        let configuration = URLSessionConfiguration.default
        // Waits for connectivity rather than failing instantly on a flaky
        // network, which matters because this runs unattended at the end of a
        // workday and nobody is watching for a first-attempt failure.
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
    }

    /// Builds a client from the skill configuration, the Keychain and the
    /// environment.
    ///
    /// Key precedence is deliberate: the Keychain is what the user manages from
    /// the Settings window, so it wins. An environment variable is only a
    /// fallback for developers and CI who export a key in a shell.
    ///
    /// Providers are tried in the fixed preference order, so whichever service
    /// the user has actually set up simply works — they do not have to edit the
    /// config to match their key.
    static func resolve(
        from skill: SkillConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredProviderID: String? = nil,
        allowKeychain: Bool = true
    ) throws -> APIClient {
        let ordered = orderedProviders(skill: skill, preferredProviderID: preferredProviderID)

        if let chosen = ordered.first(where: { provider in
            if allowKeychain, let stored = KeychainManager.getKey(for: provider.id),
               !stored.isEmpty {
                return true
            }
            guard let variable = provider.apiKeyEnvironmentVariable.nilIfEmpty else { return false }
            return environment[variable]?.isEmpty == false
        }) {
            let apiKey: String
            if allowKeychain, let stored = KeychainManager.getKey(for: chosen.id),
               !stored.isEmpty {
                apiKey = stored
            } else {
                apiKey = environment[chosen.apiKeyEnvironmentVariable] ?? ""
            }
            return APIClient(
                provider: .init(provider: chosen, apiKey: apiKey),
                voiceScriptStartTag: skill.audio.voiceScriptStartTag,
                voiceScriptEndTag: skill.audio.voiceScriptEndTag,
                modelOverride: Self.preferredModelOverride(for: chosen.id)
            )
        }

        let nominated = skill.defaultProvider
        ?? SkillConfiguration.fallback.defaultProvider
        ?? SkillConfiguration.AIProvider(
            id: "unconfigured",
            label: "no provider",
            baseURL: "https://api.openai.com/v1",
            apiKeyEnvironmentVariable: "OPENAI_API_KEY",
            model: "gpt-4o-mini",
            temperature: 0.3,
            maxContextWindow: 32_768,
            costPerMillionInput: 0,
            isFreeTier: false
        )

        throw Self.missingKeyError(for: nominated)
    }

    /// Builds a client for one provider with one specific key.
    ///
    /// Exists for the Settings window, which must be able to test a key the user
    /// has *typed but not yet saved* — the whole point of "Test Connection" is to
    /// find out whether the key is good before it is committed to the Keychain.
    /// `resolve(from:)` cannot do that: it only knows about keys that are already
    /// stored or exported.
    static func make(
        provider: SkillConfiguration.AIProvider,
        apiKey: String,
        voiceScriptStartTag: String,
        voiceScriptEndTag: String,
        modelOverride: String? = nil
    ) -> APIClient {
        APIClient(
            provider: .init(provider: provider, apiKey: apiKey),
            voiceScriptStartTag: voiceScriptStartTag,
            voiceScriptEndTag: voiceScriptEndTag,
            modelOverride: modelOverride
        )
    }

    /// The model the user chose for a provider, or nil to use the config default.
    ///
    /// Reads `UserDefaults` directly rather than taking the whole settings
    /// object, so the client stays constructible from the CLI harness, where no
    /// AppKit or `AppSettings` exists.
    private static func preferredModelOverride(for providerID: String) -> String? {
        let map = UserDefaults.standard.dictionary(
            forKey: "settings.selectedModelByProvider"
        ) as? [String: String]
        return map?[providerID]
    }

    /// The configured providers, with an explicitly-chosen one first.
    private static func orderedProviders(
        skill: SkillConfiguration,
        preferredProviderID: String?
    ) -> [SkillConfiguration.AIProvider] {
        let providers = skill.allProviders()
        guard let preferred = preferredProviderID,
              let chosen = providers.first(where: { $0.id == preferred }) else {
            return providers
        }
        return [chosen] + providers.filter { $0.id != preferred }
    }

    /// Sends a deliberately tiny completion to prove a key works.
    ///
    /// The Settings window calls this with a freshly typed key *before* saving
    /// it, so the user finds out immediately that they pasted the wrong value
    /// rather than discovering it at the end of a workday. `max_tokens` is
    /// capped so the probe is effectively free.
    func testConnection() async throws -> String {
        let request = try makeRequest(
            systemPrompt: "You are a health check. Reply with the single word: OK",
            userPayload: "ping",
            maxTokens: DayPilotConfiguration.connectionProbeMaxTokens
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIClientError.transportFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.transportFailure("The response was not HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIClientError.networkError(
                statusCode: http.statusCode,
                message: Self.errorMessage(from: data) ?? Self.firstBytes(data),
                hint: Self.hint(for: http.statusCode)
            )
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw APIClientError.parsingError(error.localizedDescription)
        }
        guard let reply = decoded.choices.first?.message.content else {
            throw APIClientError.emptyResponse
        }
        return reply.isEmpty ? "(empty reply)" : reply
    }

    /// Requests a debrief and splits the spoken script out of it.
    ///
    /// - Parameters:
    ///   - systemPrompt: The skill's operating rules plus the user's identity.
    ///   - userPayload: The pruned, compressed session telemetry.
    /// - Returns: The clean Markdown report and the text for the voice engine.
    func generateDebrief(
        systemPrompt: String,
        userPayload: String
    ) async throws -> (reportMarkdown: String, voiceScript: String) {
        let text = try await complete(systemPrompt: systemPrompt, userPayload: userPayload)
        let split = Self.splitVoiceScript(
            from: text,
            startTag: audioVoiceTags.start,
            endTag: audioVoiceTags.end
        )
        return (split.reportMarkdown, split.voiceScript)
    }

    /// Performs one chat completion and returns the assistant's raw text.
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        let request = try makeRequest(systemPrompt: systemPrompt, userPayload: userPayload)
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw APIClientError.transportFailure("The request was cancelled before it completed.")
        } catch {
            throw APIClientError.transportFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.transportFailure("The response was not HTTP.")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw APIClientError.networkError(
                statusCode: http.statusCode,
                message: Self.errorMessage(from: data) ?? Self.firstBytes(data),
                hint: Self.hint(for: http.statusCode)
            )
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw APIClientError.parsingError(error.localizedDescription)
        }

        guard let choice = decoded.choices.first else {
            throw APIClientError.emptyResponse
        }

        guard !choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIClientError.emptyResponse
        }

        return choice.message.content
    }

    /// The missing-key error, tailored to which sources were consulted.
    ///
    /// A user who pasted a key into Settings and picked Groq should be told that
    /// a Google AI Studio key is what the Keychain is holding, not be left with
    /// a bare "missing key".
    static func missingKeyError(
        for provider: SkillConfiguration.AIProvider
    ) -> APIClientError {
        let held = KeychainManager.storedProviders()
        let variable = provider.apiKeyEnvironmentVariable.nilIfEmpty

        let hint: String
        if !held.isEmpty {
            hint = "The Keychain holds keys for: \(held.joined(separator: ", "))."
        } else if let variable {
            hint = "Add a key in Settings, or export \(variable)."
        } else {
            hint = "Add a key in Settings."
        }

        return APIClientError.missingAPIKey(
            provider: provider.label,
            environmentVariable: provider.apiKeyEnvironmentVariable,
            hint: hint
        )
    }

    // MARK: - Request construction

    /// The model to send: the user's choice, else the provider's configured default.
    ///
    /// A custom endpoint has no default, so an unchosen model is reported as the
    /// user's to fix in Settings, rather than sent and rejected by the server with
    /// a message that does not say what to do.
    private func requestModel() throws -> String {
        let chosen = (modelOverride ?? provider.provider.model)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty else {
            throw APIClientError.noModelSelected(provider: provider.provider.label)
        }
        return chosen
    }

    private func makeRequest(
        systemPrompt: String,
        userPayload: String,
        maxTokens: Int = DayPilotConfiguration.synthesisMaxTokens
    ) throws -> URLRequest {
        let endpoint = provider.provider.baseURL.hasSuffix("/")
            ? provider.provider.baseURL + "chat/completions"
            : provider.provider.baseURL + "/chat/completions"

        guard let url = URL(string: endpoint) else {
            throw APIClientError.networkError(statusCode: 0, message: "Invalid base URL \(endpoint)")
        }

        let chosenModel = try requestModel()
        let body = ChatCompletionRequest(
            model: chosenModel,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPayload)
            ],
            temperature: provider.provider.temperature,
            max_tokens: maxTokens
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Every provider in DayPilot's config accepts the key as a bearer token;
        // Google's OpenAI-compat layer does too, which is why it can sit in the
        // same code path as OpenRouter.
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Splits the assistant's text into the Markdown report and the voice script.
    ///
    /// The model is instructed to append `[VOICE_SCRIPT]…[/VOICE_SCRIPT]`. If it
    /// does not, the whole text is treated as the report and the voice script is
    /// empty — the caller then skips speech rather than reading a bunch of
    /// Markdown markup aloud.
    static func splitVoiceScript(
        from text: String,
        startTag: String,
        endTag: String
    ) -> (reportMarkdown: String, voiceScript: String) {
        guard let startRange = text.range(of: startTag) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }

        let report = String(text[text.startIndex..<startRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bodyStart = startRange.upperBound
        if let endRange = text.range(of: endTag, range: bodyStart..<text.endIndex) {
            let script = String(text[bodyStart..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (report, script)
        }

        let script = String(text[bodyStart..<text.endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (report, script)
    }

    /// The next step for an HTTP status, or "" when the message is already clear.
    ///
    /// 401/403 deserves its own treatment: OpenRouter, and several other
    /// OpenAI-compatible providers, answer a *validly formatted but rejected*
    /// key with "Missing Authentication header" — which sends the user hunting
    /// for a header problem that does not exist. The key is present and wrong.
    /// Phase 4's Settings window is the fix for that, so say so.
    static func hint(for statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return "the key was present but rejected. Check that you pasted it correctly, and that it belongs to this provider — open Settings (⌘,) to replace it."
        case 403:
            return "the key does not have permission for this request, or its quota is exhausted."
        case 429:
            return "rate limited. Wait a moment, or switch provider in Settings."
        default:
            return ""
        }
    }

    /// Pulls a human-readable message out of an OpenAI-style error body.
    private static func errorMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct ErrorBody: Decodable {
                let message: String?
                let type: String?
            }
            let error: ErrorBody?
        }

        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let body = envelope.error else {
            return nil
        }
        let type = body.type.map { " (\($0))" } ?? ""
        return (body.message ?? "unknown error") + type
    }

    /// Last resort when the error body is not JSON — short, so a raw HTML error
    /// page does not flood the log.
    private static func firstBytes(_ data: Data) -> String {
        let prefix = data.prefix(240)
        return String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire models

private extension String {
    /// `nil` when empty, so a provider with no configured key variable behaves
    /// like one with no key at all instead of looking up "" in the environment.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension APIClient {
    /// Encodable request matching the OpenAI chat completion schema.
    struct ChatCompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
    }

    /// Decodable response. Providers are inconsistent about `finish_reason`
    /// and usage, both of which are decoded absent rather than required, so a
    /// provider that omits them still parses.
    struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String
                let content: String
            }
            let index: Int
            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]
    }
}
