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
    private let apiKey: String?
    private let model: String
    private let systemPrompt: String
    private let stateLock = NSLock()
    private var history: [[String: String]] = []
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
        guard let chat = endpointURL(baseURL: baseURL),
              var components = URLComponents(url: chat, resolvingAgainstBaseURL: false) else {
            throw OpenAICompatError.badURL
        }
        // The normalized endpoint always ends in /chat/completions; the models
        // listing lives beside it.
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
        return models.compactMap { $0["id"] as? String }.sorted()
    }

    init(baseURL: String, apiKey: String?, model: String, systemPrompt: String) {
        self.endpoint = Self.endpointURL(baseURL: baseURL)
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.sendReasoningEffort = (self.endpoint?.host() == "api.openai.com")
    }

    func translate(_ text: String) async throws -> String {
        let userMessage = ["role": "user", "content": "<u>\(text)</u>"]
        let result = try await performChat(messages: contextMessages(appending: userMessage))
        // Record only after the response passed validation — appending first
        // would duplicate the same utterance's user message on retry and leave
        // a failed assistant response polluting the context from then on,
        // degrading translation quality.
        recordExchange(userMessage, result: result)
        return result
    }

    /// Translate without recording the exchange into the conversation history.
    /// The current history is read as context, so provisional translations
    /// benefit from the meeting context without polluting it (the finalized
    /// version of the same sentences is recorded later by translate()).
    /// May run concurrently with translate().
    func translateEphemeral(_ text: String) async throws -> String {
        let userMessage = ["role": "user", "content": "<u>\(text)</u>"]
        return try await performChat(messages: contextMessages(appending: userMessage))
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
        // History cap (120 utterances). Beyond it, drop the first 60 utterances
        // in one batch.
        if history.count >= 240 {
            history.removeFirst(120)
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
