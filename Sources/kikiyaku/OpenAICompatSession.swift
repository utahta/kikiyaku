import Foundation
import Security

/// Generic password storage in the Keychain, so API keys never live in plain files.
enum KeychainStore {
    private static let service = "com.utahta.kikiyaku"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pass nil or an empty string to delete.
    static func set(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum OpenAICompatError: Error, CustomStringConvertible {
    case badURL
    case httpError(Int, String)
    case badResponse
    case emptyResponse

    var description: String {
        switch self {
        case .badURL: return "invalid base URL"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .badResponse: return "unexpected response shape"
        case .emptyResponse: return "empty translation"
        }
    }
}

/// Translation session over an OpenAI-compatible API (/v1/chat/completions).
/// Connects both to cloud OpenAI (api.openai.com + API key) and to local or
/// self-hosted servers such as LM Studio / llama.cpp / Ollama / vLLM (no key).
///
/// The conversation history is kept locally and sent in full on every request
/// (the cloud side applies automatic prompt caching; llama.cpp-style servers
/// reuse the KV-cache prefix). When the history grows too large, the first half
/// is dropped in one batch (a sliding window would break the cache's
/// prefix-invariance on every request).
///
/// `translate` is called serially from a single Task (the LLM lane's
/// discipline). `translateEphemeral` (the provisional lane) may run
/// concurrently with it — the shared mutable state (history, effort flag) is
/// guarded by `stateLock`.
final class OpenAICompatSession: LLMTranslator, @unchecked Sendable {
    private let endpoint: URL?
    /// Kept for the model listing, which lives beside the chat endpoint but is
    /// asked for again after the first translation (see probeContextLength).
    private let baseURL: String
    private let apiKey: String?
    private let model: String
    private let systemPrompt: String
    private let stateLock = NSLock()
    private var history: [[String: String]] = []
    /// How many utterances of conversation to carry, guarded by stateLock.
    ///
    /// Starts at a figure that fits the 8192-token context most local servers
    /// load by default, and is raised once the endpoint says it can take more.
    /// Sized in utterances rather than tokens because that is what the history
    /// is made of; the conversion below is measured, not guessed.
    private var historyCap = OpenAICompatSession.defaultHistoryCap
    /// How many times the context length has been asked for, and whether an
    /// answer ever came. Guarded by stateLock.
    private var contextProbes = 0
    private var contextAdapted = false
    /// On gpt-5-family cloud models, reasoning_effort=none helps speed (gpt-5.5
    /// measured: default reasoning 2.0s → none 1.7s per utterance, no quality loss
    /// as long as history context is present. "minimal" was removed in gpt-5.5, so
    /// it is not used). Local servers such as LM Studio, however, interpret this
    /// parameter as "enable thinking", overriding the model's Enable Thinking = off
    /// setting and becoming ~10x slower (measured: 0.8s → 7.6s). Send it only when
    /// connecting to OpenAI's cloud. The 400-response fallback is kept as well.
    private var sendReasoningEffort: Bool
    /// Guarded by stateLock: both lanes call performChat concurrently and can
    /// write this (bad-URL path) while the main lane reads isAlive.
    private var alive = true

    var isAlive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return alive
    }
    /// Per-request HTTP. A failed request is never recorded in the history, so the
    /// same session can safely be reused after an error (the meeting context is
    /// preserved). History size is also capped locally (batch trim below).
    var isPerRequest: Bool { true }

    /// Normalizes base-URL variants into the endpoint URL. LM Studio and friends
    /// document "http://host:1234/v1" as the base URL, so a trailing /v1 gets only
    /// /chat/completions appended; a pasted full endpoint (…/chat/completions) is
    /// used as-is. The URL is decomposed with URLComponents so only the path is
    /// inspected and rewritten — a query string ("…/v1?tenant=x") is preserved
    /// instead of having the path concatenated into it. A URL without a host
    /// (e.g. a missing scheme) returns nil so the failure surfaces as a clear
    /// bad-URL error.
    static func endpointURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: trimmed), components.host != nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            // full endpoint pasted — use as-is
        } else if path.hasSuffix("/v1") {
            path += "/chat/completions"
        } else {
            path += "/v1/chat/completions"
        }
        components.path = path
        return components.url
    }

    // MARK: - API key storage (per endpoint origin)

    /// API keys are stored separately per endpoint. With a single key, switching
    /// the endpoint to e.g. a LAN server while an OpenAI key is saved would send
    /// that key to an unintended party (in cleartext over http).
    ///
    /// The identifier is the normalized origin "scheme://host:port": the scheme is
    /// included (an http endpoint must never read the https endpoint's key), the
    /// port is made effective (explicit, or the scheme default), and IPv6 literals
    /// are bracketed so host and port cannot be conflated — with a bare
    /// "host:port" concatenation, "[::1]:1234" and "[::1:1234]" both collapse to
    /// "::1:1234" and the wrong server could receive the key.
    static func keychainOriginKey(forBaseURL baseURL: String) -> String? {
        guard let url = endpointURL(baseURL: baseURL),
              let scheme = url.scheme?.lowercased(),
              let rawHost = url.host() else { return nil }
        let host = rawHost.lowercased()
        let bracketed = host.contains(":") ? "[\(host)]" : host
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(bracketed):\(port)"
    }

    /// Pre-origin account format ("host" or "host:port", scheme-blind). Kept only
    /// to migrate previously saved keys.
    private static func preOriginHostKey(forBaseURL baseURL: String) -> String? {
        guard let url = endpointURL(baseURL: baseURL), let host = url.host() else { return nil }
        let hostKey = host.lowercased()
        if let port = url.port { return "\(hostKey):\(port)" }
        return hostKey
    }

    /// Legacy format (a single host-independent account). Carried over only as the
    /// key for OpenAI's official host.
    private static let legacyKeyAccount = "openai-api-key"
    private static let openAIOrigin = "https://api.openai.com:443"

    static func apiKey(forBaseURL baseURL: String) -> String? {
        guard let originKey = keychainOriginKey(forBaseURL: baseURL) else { return nil }
        let account = "openai-api-key/\(originKey)"
        if let key = KeychainStore.get(account) { return key }
        // Migrate from the pre-origin per-host format. Only into https origins:
        // the old format was scheme-blind, and inheriting an https-era key into an
        // http origin would downgrade its transport.
        if originKey.hasPrefix("https://"),
           let old = preOriginHostKey(forBaseURL: baseURL),
           let key = KeychainStore.get("openai-api-key/\(old)") {
            KeychainStore.set(account, key)
            KeychainStore.set("openai-api-key/\(old)", nil)
            return key
        }
        // Migrate from the legacy single account (OpenAI's official host only).
        if originKey == openAIOrigin, let legacy = KeychainStore.get(legacyKeyAccount) {
            KeychainStore.set(account, legacy)
            KeychainStore.set(legacyKeyAccount, nil)
            return legacy
        }
        return nil
    }

    static func setAPIKey(_ key: String?, forBaseURL baseURL: String) {
        guard let originKey = keychainOriginKey(forBaseURL: baseURL) else { return }
        KeychainStore.set("openai-api-key/\(originKey)", key)
        // Clear stale copies under the older account formats.
        if let old = preOriginHostKey(forBaseURL: baseURL) {
            KeychainStore.set("openai-api-key/\(old)", nil)
        }
        if originKey == openAIOrigin {
            KeychainStore.set(legacyKeyAccount, nil)
        }
    }

    /// Lists the model IDs the endpoint offers (GET /v1/models). Works for
    /// OpenAI cloud (key required) and OpenAI-compatible local servers.
    static func listModels(baseURL: String, apiKey: String?) async throws -> [String] {
        try await listModelEntries(baseURL: baseURL, apiKey: apiKey)
            .compactMap { $0["id"] as? String }
            .sorted()
    }

    /// How much context the endpoint says the chosen model has, or nil when it
    /// does not say.
    ///
    /// The listing is not standardized beyond the model ids, so this reads the
    /// keys the servers in use actually publish. LM Studio reports both what
    /// the model could take and what it was loaded with — the latter is the
    /// one that matters, since a model loaded at 8192 will not accept more for
    /// having been trained on 32k. OpenAI's cloud publishes none of this, and
    /// answering nil is the correct outcome there.
    static func contextLength(baseURL: String, apiKey: String?, model: String) async -> Int? {
        // The OpenAI-compatible listing carries none of this — LM Studio's
        // returns id, object and owned_by, and that is the whole of it — so the
        // question is put to its own API, which sits beside the compatible one
        // on the same host. Anything else answers 404 and the caller keeps its
        // default.
        guard let entries = try? await listNativeModelEntries(baseURL: baseURL, apiKey: apiKey),
              let entry = entries.first(where: { $0["id"] as? String == model })
        else { return nil }

        // Only the length the model was actually loaded with. max_context_length
        // is what the weights could take — 262144 for a model LM Studio may
        // well have loaded at 4096 — and sizing a history to it would overflow
        // every request, which servers answer by dropping the front of the
        // prompt in silence. A model that is not loaded reports no loaded
        // length, and there is nothing to adapt to until it is.
        if let loaded = entry["loaded_context_length"] as? Int, loaded > 0 {
            return loaded
        }
        return nil
    }

    /// LM Studio's own model listing (GET /api/v0/models), which unlike the
    /// OpenAI-compatible one reports how each model was loaded.
    private static func listNativeModelEntries(
        baseURL: String, apiKey: String?
    ) async throws -> [[String: Any]] {
        guard let chat = endpointURL(baseURL: baseURL),
              var components = URLComponents(url: chat, resolvingAgainstBaseURL: false) else {
            throw OpenAICompatError.badURL
        }
        // Relative to whatever prefix the chat endpoint sits behind, not
        // absolute: an instance published at https://host/lm/v1 keeps its own
        // listing at /lm/api/v0/models, and an absolute path would drop the
        // /lm and ask a proxy about a route it does not have. endpointURL
        // always normalizes to a path ending in /chat/completions, so removing
        // that and the /v1 before it leaves exactly the prefix.
        var prefix = components.path
        for suffix in ["/v1/chat/completions", "/chat/completions"]
        where prefix.hasSuffix(suffix) {
            prefix = String(prefix.dropLast(suffix.count))
            break
        }
        components.path = prefix + "/api/v0/models"
        guard let url = components.url else { throw OpenAICompatError.badURL }

        var request = URLRequest(url: url, timeoutInterval: 10)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAICompatError.badResponse
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["data"] as? [[String: Any]] else {
            throw OpenAICompatError.badResponse
        }
        return models
    }

    private static func listModelEntries(
        baseURL: String, apiKey: String?
    ) async throws -> [[String: Any]] {
        guard let chat = endpointURL(baseURL: baseURL),
              var components = URLComponents(url: chat, resolvingAgainstBaseURL: false) else {
            throw OpenAICompatError.badURL
        }
        components.path = components.path.replacingOccurrences(
            of: "/chat/completions", with: "/models")
        guard let url = components.url else { throw OpenAICompatError.badURL }

        var request = URLRequest(url: url, timeoutInterval: 15)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAICompatError.badResponse }
        guard http.statusCode == 200 else {
            throw OpenAICompatError.httpError(
                http.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["data"] as? [[String: Any]] else {
            throw OpenAICompatError.badResponse
        }
        return models
    }

    /// Utterances of history when the endpoint will not say how much context it
    /// has. Chosen for the 8192 tokens local servers commonly load by default:
    /// 60 utterances is around 4,300 tokens of history, which leaves room for
    /// the utterance being translated and its answer. Guessing high instead
    /// would overflow silently — the server drops the front of the prompt and
    /// nothing says so, leaving a session that believes it has context it lost.
    static let defaultHistoryCap = 60

    /// Never carry more than this, however much context is on offer. Deeper
    /// histories were measured as no faster to serve (the prompt cache sees to
    /// that) but they do lengthen the pause when half of one is dropped, and
    /// the translation quality gained past this point did not show up in the
    /// comparison.
    private static let maximumHistoryCap = 120

    /// How many times to ask the endpoint for its context length: once at
    /// startup, once after the first translation. Beyond that the endpoint has
    /// made clear it does not publish one, and asking on every utterance would
    /// be a request per translation for an answer that is not coming.
    private static let maximumContextProbes = 2

    /// Measured mean cost of one utterance and its translation, in tokens:
    /// roughly 30 for the transcript, 22 for the translation, the rest the <u>
    /// wrapper and message overhead.
    private static let tokensPerExchange = 70

    /// Share of the context given over to history. The rest holds the system
    /// prompt, the utterance being translated, its answer, and enough slack
    /// that a long utterance late in a meeting does not push the whole thing
    /// over the edge.
    private static let historyShareOfContext = 0.55

    init(baseURL: String, apiKey: String?, model: String, systemPrompt: String) {
        self.endpoint = Self.endpointURL(baseURL: baseURL)
        self.baseURL = baseURL
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.sendReasoningEffort = (self.endpoint?.host() == "api.openai.com")

        probeContextLength()
    }

    /// Asks the endpoint how much context the model was loaded with, and sizes
    /// the history to it.
    ///
    /// Asked in the background, never awaited: a session must start whether or
    /// not the endpoint answers, and the default cap is safe until it does. The
    /// opening utterances of a meeting cannot exceed any cap anyway, so there
    /// is nothing lost by learning this a moment late.
    ///
    /// Asked more than once, and it has to be. LM Studio can be set to load a
    /// model only when the first request arrives, and until then it reports the
    /// model as not-loaded with no loaded length at all. A single question at
    /// startup would therefore never get an answer on such a setup, and the
    /// adaptation would silently never happen — which is exactly what it did.
    /// The second question follows the first translation, by which time the
    /// model is in memory whichever way it was configured.
    private func probeContextLength() {
        stateLock.lock()
        let attempted = contextProbes
        contextProbes += 1
        let settled = contextAdapted
        stateLock.unlock()
        guard !settled, attempted < Self.maximumContextProbes else { return }

        let baseURL = baseURL
        let apiKey = apiKey
        let model = model
        Task { [weak self] in
            guard let length = await Self.contextLength(
                baseURL: baseURL, apiKey: apiKey, model: model) else {
                debugLog("no loaded context length on probe \(attempted + 1); history cap stays at \(Self.defaultHistoryCap)")
                return
            }
            self?.adoptContextLength(length)
        }
    }

    /// Sizes the history to a context the endpoint has just reported.
    ///
    /// The point is not to use every token on offer but to stop guessing: a cap
    /// chosen blind is either too small for a machine set up for long context,
    /// or too large for one left at its default — and being too large is the
    /// bad direction, since the server drops the front of an over-long prompt
    /// without telling anyone.
    private func adoptContextLength(_ contextLength: Int) {
        let affordable = Int(Double(contextLength) * Self.historyShareOfContext)
            / Self.tokensPerExchange
        let cap = min(Self.maximumHistoryCap, max(20, affordable))
        stateLock.lock()
        let previous = historyCap
        historyCap = cap
        contextAdapted = true
        stateLock.unlock()
        if cap != previous {
            debugLog("endpoint reports \(contextLength) tokens of context; history cap \(previous) -> \(cap)")
        }
    }

    func translate(_ text: String, sourceID: String, targetID: String) async throws -> String {
        let userMessage = [
            "role": "user",
            "content": UtterancePayload.wrap(text, sourceID: sourceID, targetID: targetID),
        ]
        let raw = try await performChat(messages: contextMessages(appending: userMessage))
        // Normalized before it is recorded, not merely before it is shown: the
        // history is what the model reads back as an example of its own
        // answers, so a wrapped one left in it teaches the next hundred.
        let result = normalized(raw, sourceID: sourceID, targetID: targetID)
        guard !result.isEmpty else { throw OpenAICompatError.emptyResponse }
        // Record only after the response passed validation — appending first
        // would duplicate the same utterance's user message on retry and leave
        // a failed assistant response polluting the context from then on,
        // degrading translation quality.
        recordExchange(userMessage, result: result)
        // The model is loaded now if it was not before; ask again for what a
        // just-in-time setup could not answer at startup.
        probeContextLength()
        return result
    }

    /// Translate without recording the exchange into the conversation history.
    /// The current history is read as context, so provisional translations
    /// benefit from the meeting context without polluting it (the finalized
    /// version of the same sentences is recorded later by translate()).
    /// May run concurrently with translate().
    func translateEphemeral(_ text: String, sourceID: String, targetID: String) async throws -> String {
        let userMessage = [
            "role": "user",
            "content": UtterancePayload.wrap(text, sourceID: sourceID, targetID: targetID),
        ]
        let raw = try await performChat(messages: contextMessages(appending: userMessage))
        let result = normalized(raw, sourceID: sourceID, targetID: targetID)
        guard !result.isEmpty else { throw OpenAICompatError.emptyResponse }
        return result
    }

    /// Strips the request's own envelope when the model has copied it back, and
    /// says so once per occurrence — without the text, which never goes to the
    /// log.
    private func normalized(_ response: String, sourceID: String, targetID: String) -> String {
        let (text, stripped) = UtterancePayload.unwrap(
            response, sourceID: sourceID, targetID: targetID)
        if stripped {
            debugLog("openai backend (\(model)) echoed the <u> envelope on \(sourceID)->\(targetID)")
        }
        return text
    }

    private func contextMessages(appending userMessage: [String: String]) -> [[String: String]] {
        stateLock.lock()
        let snapshot = history
        stateLock.unlock()
        return [["role": "system", "content": systemPrompt]] + snapshot + [userMessage]
    }

    // NSLock cannot be taken directly inside async functions; these synchronous
    // helpers keep each critical section lock-scoped and async-safe.

    private func recordExchange(_ userMessage: [String: String], result: String) {
        stateLock.lock()
        history.append(userMessage)
        history.append(["role": "assistant", "content": result])
        // Half the cap is dropped in one batch when it is reached. A sliding
        // window would move the prefix on every request and cost the prompt
        // cache each time; this pays for it once, and then not again for
        // another half-cap of conversation.
        //
        // Counted in exchanges and removed in pairs. The cap is a number of
        // utterances while the array holds two messages each, so an odd cap —
        // 39 utterances, say, which a 5,000-token context produces — would
        // otherwise strand an assistant message with no user message before
        // it, and hand the model a conversation that never happened.
        if history.count >= historyCap * 2 {
            history.removeFirst((historyCap / 2) * 2)
        }
        stateLock.unlock()
    }

    private func shouldSendReasoningEffort() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sendReasoningEffort
    }

    private func disableReasoningEffort() {
        stateLock.lock()
        sendReasoningEffort = false
        stateLock.unlock()
    }

    private func markDead() {
        stateLock.lock()
        alive = false
        stateLock.unlock()
    }

    /// One /chat/completions round trip, shared by translate and
    /// translateEphemeral. Validates the response (an empty translation is a
    /// failure) but never touches the history.
    private func performChat(messages: [[String: String]]) async throws -> String {
        guard let endpoint else {
            markDead()
            throw OpenAICompatError.badURL
        }
        let includeEffort = shouldSendReasoningEffort()

        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 2000,
            "messages": messages,
        ]
        if includeEffort {
            body["reasoning_effort"] = "none"
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAICompatError.badResponse }
        guard http.statusCode == 200 else {
            let detail = String(decoding: data.prefix(400), as: UTF8.self)
            // Fallback for servers that reject reasoning_effort (retry once).
            if includeEffort, http.statusCode == 400, detail.contains("reasoning_effort") {
                disableReasoningEffort()
                return try await performChat(messages: messages)
            }
            throw OpenAICompatError.httpError(http.statusCode, detail)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAICompatError.badResponse
        }
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw OpenAICompatError.emptyResponse }
        return result
    }

    func shutdown() {
        markDead()
    }
}
