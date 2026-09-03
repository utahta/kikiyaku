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
    /// The stream ended before the server said the answer was complete.
    case streamTruncated
    /// The server sent an error object in place of a chunk.
    case streamError(String)

    var description: String {
        switch self {
        case .badURL: return "invalid base URL"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .badResponse: return "unexpected response shape"
        case .emptyResponse: return "empty translation"
        case .streamTruncated: return "stream ended before completion"
        case .streamError(let message): return "stream error: \(message)"
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
    /// Whether to ask for no reasoning. Sent to every endpoint until one
    /// refuses it, which the 400 fallback below then remembers.
    ///
    /// Reasoning is time spent not translating, and a model left to it spends a
    /// great deal: 355–766 tokens of reasoning for a sentence whose translation
    /// is 16, taking 6.2–11.9s instead of 0.6s. Asking for none brings that
    /// back whether the server's own thinking setting is on or off, and costs
    /// nothing when it was already off. Measured on gemma4 26B through both
    /// Ollama and LM Studio, with the real prompt and 20 utterances of history.
    ///
    /// An earlier note here had it that local servers read this parameter as
    /// "enable thinking" and became ten times slower, so it went to
    /// api.openai.com alone. The measurement behind that had the cause the
    /// wrong way round — those seconds were the model thinking, which the
    /// parameter is what turns off — and Ollama, where thinking is on unless
    /// asked otherwise, was left doing it on every utterance.
    private var sendReasoningEffort = true
    /// Whether to ask for a streamed answer. Asked of every endpoint until
    /// one refuses it with a 400/422 naming the field, which is then
    /// remembered like the reasoning parameter: an endpoint that serves the
    /// ordinary completion but not the streamed one still translates, only
    /// without partial text on the way. Guarded by stateLock.
    private var sendStream = true
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
        // The OpenAI-compatible listing carries none of this — it returns ids
        // and little else on both servers — so the question is put to whichever
        // native API is beside it. Asking the wrong one costs a refusal and
        // nothing else: Ollama 404s on LM Studio's route, LM Studio answers 200
        // with an error object where Ollama's would be, and neither carries the
        // key being looked for. An endpoint that is neither server refuses both
        // and keeps the default.
        //
        // In both cases the figure has to be the length the model was loaded
        // with, never what its weights could take: the latter reads 262144 for
        // a model that may well be running at 4096, and a history sized to it
        // would overflow every request — which servers answer by dropping the
        // front of the prompt in silence.
        if let entries = try? await listNativeModelEntries(baseURL: baseURL, apiKey: apiKey),
           let entry = entries.first(where: { $0["id"] as? String == model }),
           let loaded = entry["loaded_context_length"] as? Int, loaded > 0 {
            return loaded
        }
        if let running = try? await listRunningModels(baseURL: baseURL, apiKey: apiKey),
           let entry = running.first(where: {
               namesTheSameOllamaModel($0["name"] as? String, model)
           }),
           let loaded = entry["context_length"] as? Int, loaded > 0 {
            return loaded
        }
        return nil
    }

    /// Whether two Ollama model names refer to the same model.
    ///
    /// A name without a tag means the `latest` one, and Ollama answers with the
    /// tag filled in: ask for "gemma4" and it reports "gemma4:latest". Compared
    /// as plain strings those miss each other, and the session would fall back
    /// to a default history size while believing it had asked. Only the missing
    /// tag is supplied — two names that each name a tag are the same model only
    /// if they name the same one.
    ///
    /// A tag is a colon after the last slash. Looking for any colon mistook
    /// the port of a registry-qualified name (`localhost:5000/team/model`)
    /// for a tag, and such a name never matched its own `:latest` form.
    static func namesTheSameOllamaModel(_ reported: String?, _ configured: String) -> Bool {
        guard let reported else { return false }
        func tagged(_ name: String) -> String {
            let afterSlash = name.lastIndex(of: "/").map { name[name.index(after: $0)...] } ?? name[...]
            return afterSlash.contains(":") ? name : name + ":latest"
        }
        return tagged(reported) == tagged(configured)
    }

    /// Ollama's list of models currently in memory (GET /api/ps), which reports
    /// the context each was loaded with — the figure OLLAMA_CONTEXT_LENGTH sets.
    /// Its own model listing gives only what the weights support, and the
    /// OpenAI-compatible one not even that.
    private static func listRunningModels(
        baseURL: String, apiKey: String?
    ) async throws -> [[String: Any]] {
        let data = try await nativeGet(path: "/api/ps", baseURL: baseURL, apiKey: apiKey)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else {
            throw OpenAICompatError.badResponse
        }
        return models
    }

    /// LM Studio's own model listing (GET /api/v0/models), which unlike the
    /// OpenAI-compatible one reports how each model was loaded.
    private static func listNativeModelEntries(
        baseURL: String, apiKey: String?
    ) async throws -> [[String: Any]] {
        let data = try await nativeGet(path: "/api/v0/models", baseURL: baseURL, apiKey: apiKey)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["data"] as? [[String: Any]] else {
            throw OpenAICompatError.badResponse
        }
        return models
    }

    /// GETs a path on the server's own API, alongside the OpenAI-compatible one.
    ///
    /// Relative to whatever prefix the chat endpoint sits behind, never
    /// absolute: an instance published at https://host/lm/v1 keeps its native
    /// routes under /lm, and an absolute path would drop it and ask a proxy
    /// about something it does not serve. endpointURL always normalizes to a
    /// path ending in /chat/completions, so removing that and the /v1 before it
    /// leaves exactly the prefix.
    private static func nativeGet(
        path: String, baseURL: String, apiKey: String?
    ) async throws -> Data {
        guard let chat = endpointURL(baseURL: baseURL),
              var components = URLComponents(url: chat, resolvingAgainstBaseURL: false) else {
            throw OpenAICompatError.badURL
        }
        var prefix = components.path
        for suffix in ["/v1/chat/completions", "/chat/completions"]
        where prefix.hasSuffix(suffix) {
            prefix = String(prefix.dropLast(suffix.count))
            break
        }
        components.path = prefix + path
        guard let url = components.url else { throw OpenAICompatError.badURL }

        var request = URLRequest(url: url, timeoutInterval: 10)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAICompatError.badResponse
        }
        return data
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

    /// How many utterances of history a reported context length affords.
    static func historyCap(forContextLength contextLength: Int) -> Int {
        let affordable = Int(Double(contextLength) * historyShareOfContext) / tokensPerExchange
        return min(maximumHistoryCap, max(20, affordable))
    }

    init(baseURL: String, apiKey: String?, model: String, systemPrompt: String) {
        self.endpoint = Self.endpointURL(baseURL: baseURL)
        self.baseURL = baseURL
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.model = model
        self.systemPrompt = systemPrompt


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
        let cap = Self.historyCap(forContextLength: contextLength)
        stateLock.lock()
        let previous = historyCap
        historyCap = cap
        contextAdapted = true
        stateLock.unlock()
        if cap != previous {
            debugLog("endpoint reports \(contextLength) tokens of context; history cap \(previous) -> \(cap)")
        }
    }

    func translate(
        _ text: String, sourceID: String, targetID: String,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let userMessage = [
            "role": "user",
            "content": UtterancePayload.wrap(text, sourceID: sourceID, targetID: targetID),
        ]
        let raw = try await performChat(
            messages: contextMessages(appending: userMessage), onPartial: onPartial)
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
        history = Self.trimmedHistory(history, cap: historyCap)
        stateLock.unlock()
    }

    /// Half the cap is dropped in one batch when it is reached. A sliding
    /// window would move the prefix on every request and cost the prompt
    /// cache each time; this pays for it once, and then not again for
    /// another half-cap of conversation.
    ///
    /// Counted in exchanges and removed in pairs. The cap is a number of
    /// utterances while the array holds two messages each, so an odd cap —
    /// 39 utterances, say, which a 5,000-token context produces — would
    /// otherwise strand an assistant message with no user message before
    /// it, and hand the model a conversation that never happened.
    static func trimmedHistory(
        _ history: [[String: String]], cap: Int
    ) -> [[String: String]] {
        guard history.count >= cap * 2 else { return history }
        return Array(history.dropFirst((cap / 2) * 2))
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

    private func shouldSendStream() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sendStream
    }

    private func disableStream() {
        stateLock.lock()
        sendStream = false
        stateLock.unlock()
    }

    /// Whether a failed request was refused over one optional field: a
    /// 400 or 422 whose body names it. Only then is a retry without the
    /// field worth making; any other failure retried that way would hide
    /// the real complaint behind a second identical one.
    static func refuses(field: String, status: Int, body: String) -> Bool {
        (status == 400 || status == 422) && body.contains(field)
    }

    private func markDead() {
        stateLock.lock()
        alive = false
        stateLock.unlock()
    }

    /// Loads the model ahead of the first utterance.
    ///
    /// A local server loads the model when the first request arrives, and on
    /// the machines this runs on that took 20–45 seconds (gemma4 26B on
    /// Ollama 0.33, Apple M1 Pro / 32 GB) — all of it waited out by the first
    /// utterance of every session. A one-token completion at session start
    /// takes that wait while the user is still getting ready to speak, and
    /// carries the system prompt so its prefix is in the server's cache
    /// when the first real request follows.
    ///
    /// Never awaited and never cancelled: a client that disconnects while
    /// the model is loading makes Ollama abort the load and start over on
    /// the next request, which would leave the first utterance waiting the
    /// full time after all. A failure is only logged — the first utterance
    /// then loads the model the way it always did — and neither this nor
    /// its answer goes anywhere near the history.
    ///
    /// The timeout is the model load plus margin; the translation requests
    /// keep their own, which the load would otherwise be measured against.
    ///
    /// Reasoning is asked off here as on every translation: a model that
    /// thinks is not held to the one-token limit while it does (Ollama
    /// counts only the answer), and a bare "." set one reasoning about what
    /// was meant for some 20 seconds — the load time this is meant to hide.
    ///
    /// Only for an endpoint that looks self-hosted (see `shouldPreload`): a
    /// cloud service has nothing to load, and the request would be a billed,
    /// rate-limited completion for nothing on every session start.
    ///
    /// A refusal of `reasoning_effort` gets the same fallback as a
    /// translation: the parameter is dropped for the session and the
    /// request sent once more. Without that, a server that validates a
    /// request before loading anything would refuse the preload, load
    /// nothing, and hand the first utterance the whole wait — and then
    /// refuse that utterance's first attempt too.
    func preload() {
        guard let endpoint, Self.shouldPreload(host: endpoint.host(), apiKey: apiKey) else { return }
        Task.detached { [self] in
            let started = Date()
            var includeEffort = shouldSendReasoningEffort()
            for _ in 0..<2 {
                let body = Self.preloadBody(
                    model: model, systemPrompt: systemPrompt, includeEffort: includeEffort)
                var request = URLRequest(url: endpoint, timeoutInterval: 180)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let apiKey {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
                request.httpBody = payload
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let detail = String(decoding: data.prefix(400), as: UTF8.self)
                    if code == 200 {
                        debugLog("preloaded \(model) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                        return
                    }
                    if includeEffort, code == 400 || code == 422, detail.contains("reasoning_effort") {
                        debugLog("endpoint refused reasoning_effort on preload (HTTP \(code)); retrying without it")
                        disableReasoningEffort()
                        includeEffort = false
                        continue
                    }
                    debugLog("preload of \(model) answered HTTP \(code): \(detail.prefix(200))")
                } catch {
                    debugLog("preload of \(model) failed: \(error)")
                }
                return
            }
        }
    }

    /// The preload request: the system prompt, so the server's cache holds
    /// its prefix for the first real request, and the smallest user turn
    /// and answer that a chat completion can be made of.
    static func preloadBody(model: String, systemPrompt: String, includeEffort: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 1,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "."],
            ],
        ]
        if includeEffort {
            body["reasoning_effort"] = "none"
        }
        return body
    }

    /// Whether an endpoint is one a preload can help: a server this machine
    /// or its network runs, which loads the model on first use.
    ///
    /// Judged by the host, and failing that by the key. A loopback, private
    /// or link-local address, or a `.local` name, is a machine within reach
    /// and never a metered service. Anything else is taken for self-hosted
    /// only when no API key is set: the servers this connects to without a
    /// key are the local ones, and a keyed endpoint on a public host is
    /// presumed to bill per request — a self-hosted server that happens to
    /// sit behind a key on a public name forgoes the preload, which costs
    /// it the first utterance's wait and nothing more.
    static func shouldPreload(host: String?, apiKey: String?) -> Bool {
        if let host, hostIsPrivate(host) { return true }
        return apiKey == nil || apiKey?.isEmpty == true
    }

    /// Whether a host names this machine or one on its own network.
    static func hostIsPrivate(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".localhost") {
            return true
        }
        // IPv6: loopback, unique local (fc00::/7), link local (fe80::/10).
        if name.contains(":") {
            let bare = name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return bare == "::1" || bare.hasPrefix("fc") || bare.hasPrefix("fd")
                || bare.hasPrefix("fe8") || bare.hasPrefix("fe9")
                || bare.hasPrefix("fea") || bare.hasPrefix("feb")
        }
        // IPv4: loopback, 10/8, 172.16/12, 192.168/16, 169.254/16. All four
        // labels must be numbers — a name such as api.10.0.0.1.example.com
        // has four that are, and is not an address.
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        guard labels.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let second) where (16...31).contains(second): return true
        default: return false
        }
    }

    /// One /chat/completions round trip, shared by translate and
    /// translateEphemeral. Validates the response (an empty translation is a
    /// failure) but never touches the history.
    ///
    /// Streamed when a partial-text consumer is given, whole otherwise. The
    /// server's work is the same either way; what changes is when the first
    /// characters can be shown. Measured on the setup above, a translation
    /// took 1.4–1.7s at the median (2.5–3.4s at p90), of which 0.6–0.8s is
    /// prompt evaluation before the first token — so a streamed answer is on
    /// the panel roughly a second before a whole one would be.
    private func performChat(
        messages: [[String: String]],
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let endpoint else {
            markDead()
            throw OpenAICompatError.badURL
        }
        let includeEffort = shouldSendReasoningEffort()
        let streamed = onPartial != nil && shouldSendStream()

        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 2000,
            "messages": messages,
        ]
        if includeEffort {
            body["reasoning_effort"] = "none"
        }
        if streamed {
            body["stream"] = true
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // The status line arrives before any of the body on both paths, so
        // the reasoning_effort fallback below reads the same whether the
        // answer is going to be streamed or not.
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAICompatError.badResponse }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 400 { break }
            }
            let detail = String(decoding: data, as: UTF8.self)
            // Fallback for servers that reject reasoning_effort (retry once).
            //
            // 422 as well as 400: the parameter now goes to every endpoint, and
            // FastAPI-based servers — vLLM among them — answer an unknown field
            // with 422 rather than 400. Refused there and not caught here, the
            // request fails, and so does every request after it, since the next
            // one carries the same parameter.
            //
            // Still only when the body names the parameter. A 422 means the
            // request was malformed, and most of the ways that can happen have
            // nothing to do with this field; retrying those without it would
            // hide the real complaint behind a second identical failure.
            if includeEffort,
               Self.refuses(field: "reasoning_effort", status: http.statusCode, body: detail) {
                debugLog("endpoint refused reasoning_effort (HTTP \(http.statusCode)); retrying without it")
                disableReasoningEffort()
                return try await performChat(messages: messages, onPartial: onPartial)
            }
            // The same for `stream`: an endpoint that has the ordinary
            // completion but not the streamed one would otherwise fail
            // every translation the same way, and the lane would give up
            // after three.
            if streamed,
               Self.refuses(field: "stream", status: http.statusCode, body: detail) {
                debugLog("endpoint refused streaming (HTTP \(http.statusCode)); translating without it from here on")
                disableStream()
                return try await performChat(messages: messages, onPartial: onPartial)
            }
            throw OpenAICompatError.httpError(http.statusCode, detail)
        }

        // Read by what came back, not by what was asked for: an endpoint
        // that does not stream may ignore `stream` and answer with the
        // whole completion as JSON, and read as an event stream that body
        // has no events in it — every translation would fail and the lane
        // would shut itself down after three.
        let content: String
        if let onPartial, Self.isEventStream(contentType: http.value(forHTTPHeaderField: "Content-Type")) {
            content = try await Self.collectStreamedAnswer(lines: bytes.lines, onPartial: onPartial)
        } else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            content = try Self.answerText(fromCompletion: data)
        }
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw OpenAICompatError.emptyResponse }
        return result
    }

    /// Whether a response body is a server-sent event stream. The media
    /// type may carry parameters (`text/event-stream; charset=utf-8`).
    static func isEventStream(contentType: String?) -> Bool {
        guard let contentType else { return false }
        return contentType.lowercased()
            .split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces) == "text/event-stream"
    }

    /// The assistant's text from a whole (non-streamed) chat completion.
    static func answerText(fromCompletion data: Data) throws -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw OpenAICompatError.badResponse
        }
        return text
    }

    /// Assembles a streamed answer from the lines of its event stream,
    /// handing the text so far to `onPartial` as it grows.
    ///
    /// The answer counts only once the server has said it is complete —
    /// the `[DONE]` sentinel, or a chunk carrying a finish reason. A stream
    /// that simply ends before either (a proxy or the server closing the
    /// connection mid-answer) is a failed request: what arrived is the front
    /// of a translation, and taken for the whole it would be recorded in
    /// the history and shown as settled, with no retry to replace it.
    ///
    /// Either signal ends the reading then and there. A server that marks
    /// the finish but keeps the connection open would otherwise hold a
    /// complete answer back until the timeout, and whatever follows the
    /// finish (a usage chunk, the sentinel) has nothing more to add.
    static func collectStreamedAnswer<Lines: AsyncSequence>(
        lines: Lines, onPartial: @Sendable (String) -> Void
    ) async throws -> String where Lines.Element == String {
        var accumulated = ""
        var completed = false
        events: for try await line in lines {
            guard let event = streamEvent(fromSSELine: line) else { continue }
            switch event {
            case .done:
                completed = true
                break events
            case .error(let message):
                throw OpenAICompatError.streamError(message)
            case .delta(let piece, let finished):
                if !piece.isEmpty {
                    accumulated += piece
                    onPartial(accumulated)
                }
                if finished {
                    completed = true
                    break events
                }
            }
        }
        guard completed else { throw OpenAICompatError.streamTruncated }
        return accumulated
    }

    /// One server-sent event of a streamed completion.
    enum StreamEvent: Equatable {
        /// More of the answer, and whether this chunk carries a finish
        /// reason. Empty pieces are reported as such, not dropped: a
        /// role-only first chunk is one, and it is not a malformed line;
        /// the last chunk is often another, and its finish reason is what
        /// says the answer is whole.
        case delta(String, finished: Bool)
        /// The `[DONE]` sentinel.
        case done
        /// An error object in place of a chunk, which servers send when
        /// generation fails after the 200 has gone out.
        case error(String)
    }

    /// Reads one line of a text/event-stream body, or nil for a line that
    /// carries no event: blank separators, comments, and any field other
    /// than `data` (an `event:` or `id:` line has nothing for us).
    ///
    /// The `data:` prefix is matched with or without the space after the
    /// colon — the specification allows both — and a chunk that does not
    /// parse is nil rather than an error, so one odd line from a server
    /// cannot fail an answer that is otherwise arriving.
    static func streamEvent(fromSSELine line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] {
            if let error = error as? [String: Any], let message = error["message"] as? String {
                return .error(message)
            }
            return .error(String(describing: error))
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let delta = choice["delta"] as? [String: Any] else {
            return nil
        }
        let finished = (choice["finish_reason"] as? String).map { !$0.isEmpty } ?? false
        return .delta(delta["content"] as? String ?? "", finished: finished)
    }

    func shutdown() {
        markDead()
    }
}
