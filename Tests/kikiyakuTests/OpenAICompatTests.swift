import Foundation
import Testing

@testable import kikiyaku

// The endpoint normalization, the per-endpoint key identity, the Ollama name
// matching, and the two history calculations — every one has a rule that was
// worked out the hard way.
struct OpenAICompatTests {
    // MARK: endpointURL

    @Test func endpointGetsTheStandardPathAppended() {
        #expect(OpenAICompatSession.endpointURL(baseURL: "http://localhost:11434")?.absoluteString
            == "http://localhost:11434/v1/chat/completions")
    }

    @Test func aV1SuffixIsNotDoubled() {
        #expect(OpenAICompatSession.endpointURL(baseURL: "https://api.openai.com/v1")?.absoluteString
            == "https://api.openai.com/v1/chat/completions")
    }

    @Test func aFullEndpointIsUsedAsIs() {
        let full = "http://localhost:1234/v1/chat/completions"
        #expect(OpenAICompatSession.endpointURL(baseURL: full)?.absoluteString == full)
    }

    @Test func trailingSlashesDoNotChangeTheResult() {
        #expect(OpenAICompatSession.endpointURL(baseURL: "http://localhost:11434/")
            == OpenAICompatSession.endpointURL(baseURL: "http://localhost:11434"))
    }

    @Test func hostlessInputIsRefused() {
        #expect(OpenAICompatSession.endpointURL(baseURL: "") == nil)
        #expect(OpenAICompatSession.endpointURL(baseURL: "   ") == nil)
    }

    // MARK: keychainOriginKey

    /// Keys are stored per origin — scheme, host, port — so a key follows the
    /// endpoint whatever path variant is typed, and never crosses to another
    /// server.
    @Test func theOriginIgnoresThePath() {
        #expect(OpenAICompatSession.keychainOriginKey(forBaseURL: "https://api.openai.com")
            == OpenAICompatSession.keychainOriginKey(forBaseURL: "https://api.openai.com/v1"))
    }

    @Test func portsAndSchemesSeparateOrigins() {
        #expect(OpenAICompatSession.keychainOriginKey(forBaseURL: "http://localhost:1234")
            != OpenAICompatSession.keychainOriginKey(forBaseURL: "http://localhost:11434"))
        #expect(OpenAICompatSession.keychainOriginKey(forBaseURL: "http://api.openai.com")
            != OpenAICompatSession.keychainOriginKey(forBaseURL: "https://api.openai.com"))
    }

    // MARK: namesTheSameOllamaModel

    @Test func aMissingTagMeansLatest() {
        #expect(OpenAICompatSession.namesTheSameOllamaModel("gemma4", "gemma4:latest"))
        #expect(OpenAICompatSession.namesTheSameOllamaModel("gemma4:latest", "gemma4"))
        #expect(OpenAICompatSession.namesTheSameOllamaModel("gemma4:26b", "gemma4:26b"))
    }

    @Test func twoExplicitTagsMustMatch() {
        #expect(!OpenAICompatSession.namesTheSameOllamaModel("gemma4:26b", "gemma4:latest"))
        #expect(!OpenAICompatSession.namesTheSameOllamaModel(nil, "gemma4"))
    }

    /// A registry-qualified name carries a port whose colon is not a tag.
    @Test func aRegistryPortIsNotATag() {
        #expect(OpenAICompatSession.namesTheSameOllamaModel(
            "localhost:5000/team/model", "localhost:5000/team/model:latest"))
        #expect(!OpenAICompatSession.namesTheSameOllamaModel(
            "localhost:5000/team/model:26b", "localhost:5000/team/model:latest"))
    }

    // MARK: history

    private func exchanges(_ n: Int) -> [[String: String]] {
        (0..<n).flatMap { i in
            [["role": "user", "content": "u\(i)"], ["role": "assistant", "content": "a\(i)"]]
        }
    }

    /// Dropped in one batch, in pairs, so the kept prefix stays stable for the
    /// prompt cache and never starts with a stranded assistant message.
    @Test func historyIsTrimmedInPairsByHalfTheCap() {
        let trimmed = OpenAICompatSession.trimmedHistory(exchanges(60), cap: 60)
        #expect(trimmed.count == 60)  // 120 - (30 * 2)
        #expect(trimmed.first?["role"] == "user")
        #expect(trimmed.first?["content"] == "u30")
    }

    @Test func belowTheCapNothingIsDropped() {
        let history = exchanges(59)
        #expect(OpenAICompatSession.trimmedHistory(history, cap: 60).count == history.count)
    }

    @Test func anOddCapStillDropsWholePairs() {
        let trimmed = OpenAICompatSession.trimmedHistory(exchanges(39), cap: 39)
        #expect(trimmed.count == 78 - 38)  // (39 / 2) * 2 = 38 messages dropped
        #expect(trimmed.first?["role"] == "user")
    }

    // MARK: historyCap(forContextLength:)

    @Test func theCapFollowsTheReportedContext() {
        #expect(OpenAICompatSession.historyCap(forContextLength: 8192) == 64)
        #expect(OpenAICompatSession.historyCap(forContextLength: 2048) == 20)   // floor
        #expect(OpenAICompatSession.historyCap(forContextLength: 262_144) == 120)  // ceiling
    }

    // MARK: shouldPreload(host:apiKey:)

    /// A machine within reach is preloaded whether or not it wants a key.
    @Test func privateHostsArePreloaded() {
        for host in ["localhost", "127.0.0.1", "10.0.0.5", "172.16.0.1", "172.31.255.255",
                     "192.168.1.20", "169.254.1.1", "::1", "fd12::1", "fe80::1", "studio.local"] {
            #expect(OpenAICompatSession.hostIsPrivate(host), "\(host)")
            #expect(OpenAICompatSession.shouldPreload(host: host, apiKey: "sk-x"), "\(host)")
        }
    }

    /// A keyed public endpoint is presumed metered and left alone; one
    /// without a key is taken for self-hosted.
    @Test func publicHostsArePreloadedOnlyWithoutAKey() {
        for host in ["api.openai.com", "8.8.8.8", "172.32.0.1", "172.15.0.1", "2001:db8::1",
                     "llm.example.com", "api.10.0.0.1.example.com", "10.0.0.1.nip.io", "10.0.0"] {
            #expect(!OpenAICompatSession.hostIsPrivate(host), "\(host)")
            #expect(!OpenAICompatSession.shouldPreload(host: host, apiKey: "sk-x"), "\(host)")
            #expect(OpenAICompatSession.shouldPreload(host: host, apiKey: nil), "\(host)")
        }
    }

    // MARK: preloadBody(model:systemPrompt:includeEffort:)

    /// One token, the system prompt in front, and the reasoning parameter
    /// only while the session still sends it.
    @Test func thePreloadAsksForOneTokenBehindTheSystemPrompt() {
        let body = OpenAICompatSession.preloadBody(model: "m", systemPrompt: "sys", includeEffort: true)
        #expect(body["model"] as? String == "m")
        #expect(body["max_completion_tokens"] as? Int == 1)
        #expect(body["reasoning_effort"] as? String == "none")
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.first == ["role": "system", "content": "sys"])
        #expect(messages?.count == 2)

        let plain = OpenAICompatSession.preloadBody(model: "m", systemPrompt: "sys", includeEffort: false)
        #expect(plain["reasoning_effort"] == nil)
    }

    // MARK: refuses(field:status:body:)

    /// Only a 400 or 422 that names the field is a refusal of it; a 500,
    /// or a 400 about something else, is not retried without it.
    @Test func aRefusalNamesTheFieldInAClientError() {
        #expect(OpenAICompatSession.refuses(field: "stream", status: 400, body: #"{"error":"stream is not supported"}"#))
        #expect(OpenAICompatSession.refuses(field: "reasoning_effort", status: 422, body: "extra field reasoning_effort"))
        #expect(!OpenAICompatSession.refuses(field: "stream", status: 500, body: "stream failed"))
        #expect(!OpenAICompatSession.refuses(field: "stream", status: 400, body: "model not found"))
    }

    // MARK: isEventStream(contentType:) / answerText(fromCompletion:)

    @Test func onlyAnEventStreamIsReadAsOne() {
        #expect(OpenAICompatSession.isEventStream(contentType: "text/event-stream"))
        #expect(OpenAICompatSession.isEventStream(contentType: "Text/Event-Stream; charset=utf-8"))
        #expect(!OpenAICompatSession.isEventStream(contentType: "application/json"))
        #expect(!OpenAICompatSession.isEventStream(contentType: nil))
    }

    /// A server that ignores `stream` answers with the whole completion, and
    /// that is read as one rather than as an empty event stream.
    @Test func aWholeCompletionYieldsItsMessage() throws {
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"訳文"}}]}"#.utf8)
        #expect(try OpenAICompatSession.answerText(fromCompletion: body) == "訳文")
        #expect(throws: OpenAICompatError.self) {
            try OpenAICompatSession.answerText(fromCompletion: Data("data: {}".utf8))
        }
    }

    // MARK: streamEvent(fromSSELine:)

    private func event(_ line: String) -> OpenAICompatSession.StreamEvent? {
        OpenAICompatSession.streamEvent(fromSSELine: line)
    }

    @Test func aChunkYieldsItsContentDelta() {
        let line = #"data: {"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"訳"},"finish_reason":null}]}"#
        #expect(event(line) == .delta("訳", finished: false))
    }

    /// The first chunk of many servers carries only the role; the last only
    /// a finish reason. Neither has content, and neither is malformed.
    @Test func chunksWithoutContentAreEmptyDeltas() {
        #expect(event(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == .delta("", finished: false))
        #expect(event(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == .delta("", finished: true))
    }

    /// A null finish reason is the usual "not yet"; a chunk can carry
    /// content and the finish reason together.
    @Test func theFinishReasonIsReadBesideTheContent() {
        #expect(event(#"data: {"choices":[{"delta":{"content":"。"},"finish_reason":null}]}"#) == .delta("。", finished: false))
        #expect(event(#"data: {"choices":[{"delta":{"content":"。"},"finish_reason":"stop"}]}"#) == .delta("。", finished: true))
    }

    @Test func theSentinelEndsTheStream() {
        #expect(event("data: [DONE]") == .done)
        #expect(event("data:[DONE]") == .done)
    }

    @Test func linesThatCarryNoEventAreSkipped() {
        #expect(event("") == nil)
        #expect(event(": keep-alive") == nil)
        #expect(event("event: message") == nil)
        #expect(event("data: not json") == nil)
    }

    @Test func anErrorObjectIsReported() {
        #expect(event(#"data: {"error":{"message":"context overflow","type":"server_error"}}"#)
            == .error("context overflow"))
    }

    // MARK: collectStreamedAnswer(lines:onPartial:)

    private func chunk(_ content: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return #"data: {"choices":[{"delta":{"content":"\#(content)"},"finish_reason":\#(reason)}]}"#
    }

    private func collect(_ lines: [String]) async throws -> (answer: String, partials: [String]) {
        let seen = PartialLog()
        let answer = try await OpenAICompatSession.collectStreamedAnswer(
            lines: AsyncStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            },
            onPartial: { seen.append($0) })
        return (answer, seen.entries)
    }

    /// The partial text grows with every piece; the sentinel ends the answer.
    @Test func piecesAccumulateUntilTheSentinel() async throws {
        let (answer, partials) = try await collect([chunk("訳"), "", chunk("文"), "", "data: [DONE]"])
        #expect(answer == "訳文")
        #expect(partials == ["訳", "訳文"])
    }

    /// A finish reason completes the answer too — some servers send no
    /// sentinel — and content-free chunks add no partial.
    @Test func aFinishReasonCompletesTheAnswer() async throws {
        let (answer, partials) = try await collect([
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            chunk("訳文"), chunk("", finish: "stop"),
        ])
        #expect(answer == "訳文")
        #expect(partials == ["訳文"])
    }

    /// The finish reason ends the reading there: what follows it — a usage
    /// chunk, the sentinel, or a connection the server keeps open — is not
    /// waited for.
    @Test func nothingAfterTheFinishReasonIsRead() async throws {
        let (answer, partials) = try await collect([
            chunk("訳文", finish: "stop"), chunk("余分"), "data: [DONE]",
        ])
        #expect(answer == "訳文")
        #expect(partials == ["訳文"])
    }

    /// A stream that ends before either signal is a failed request, not a
    /// short translation: the front of an answer must never be recorded as
    /// the whole of it.
    @Test func aStreamThatEndsEarlyIsAFailure() async {
        await #expect(throws: OpenAICompatError.self) {
            try await collect([chunk("訳")])
        }
        await #expect(throws: OpenAICompatError.self) {
            try await collect([])
        }
    }

    @Test func anErrorChunkFailsTheAnswer() async {
        await #expect(throws: OpenAICompatError.self) {
            try await collect([chunk("訳"), #"data: {"error":{"message":"boom"}}"#])
        }
    }
}

/// Collects partial callbacks from a stream under test. The callback is
/// @Sendable, so the log is locked rather than captured as a plain array.
private final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }
    func append(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        log.append(entry)
    }
}
