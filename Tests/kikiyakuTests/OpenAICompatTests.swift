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

    @Test func reachingTheCapKeepsOnlyTheLastCompleteExchange() {
        let history = exchanges(20)
        #expect(OpenAICompatSession.trimmedHistory(history, cap: 20) == Array(history.suffix(2)))
    }

    @Test func exceedingTheCapKeepsOnlyTheLastCompleteExchange() {
        let history = exchanges(25)
        #expect(OpenAICompatSession.trimmedHistory(history, cap: 20) == Array(history.suffix(2)))
    }

    @Test func belowTheCapNothingIsDropped() {
        for count in [0, 1, 19] {
            let history = exchanges(count)
            #expect(OpenAICompatSession.trimmedHistory(history, cap: 20) == history)
        }
    }

    @Test func anOddCapStillKeepsOnlyTheLastCompleteExchange() {
        let history = exchanges(39)
        #expect(OpenAICompatSession.trimmedHistory(history, cap: 39) == Array(history.suffix(2)))
    }

    @Test func anUnfinishedTrailingUserIsNotKeptAsAnExchange() {
        let complete = exchanges(20)
        let history = complete + [["role": "user", "content": "unfinished"]]
        #expect(OpenAICompatSession.trimmedHistory(history, cap: 20) == Array(complete.suffix(2)))
    }

    @Test func anUnfinishedUserBelowTheCapDoesNotTriggerAReset() {
        let history = exchanges(19) + [["role": "user", "content": "unfinished"]]
        #expect(OpenAICompatSession.trimmedHistory(history, cap: 20) == history)
    }

    @Test func resetsHappenAfterTwentyThenEveryNineteenCompletedExchanges() {
        var history: [[String: String]] = []
        var cuts: [Int] = []
        for turn in 1...60 {
            history += [["role": "user", "content": "u\(turn)"],
                        ["role": "assistant", "content": "a\(turn)"]]
            let trimmed = OpenAICompatSession.trimmedHistory(history, cap: 20)
            if trimmed.count < history.count { cuts.append(turn) }
            history = trimmed
        }
        #expect(cuts == [20, 39, 58])
        #expect(history.first?["content"] == "u58")
        #expect(history.count == 6)
    }

    // MARK: historyCap(forContextLength:)

    @Test func theCapFollowsTheReportedContext() {
        #expect(OpenAICompatSession.historyCap(forContextLength: 8192) == 64)
        #expect(OpenAICompatSession.historyCap(forContextLength: 2048) == 20)   // floor
        #expect(OpenAICompatSession.historyCap(forContextLength: 262_144) == 120)  // ceiling
    }

    @Test func absentOrMalformedHistoryOverridesUseTwenty() {
        #expect(OpenAICompatSession.defaultHistoryCap == 20)
        let values: [Any?] = [nil, "", "invalid", "40.5", 40.5, [40]]
        for value in values {
            #expect(OpenAICompatSession.requestedHistoryCap(from: value) == 20)
        }
    }

    @Test func historyOverridesAcceptIntegersAndIntegerStrings() {
        for value: Any in [40, "40", " 40\n", NSNumber(value: 40)] {
            #expect(OpenAICompatSession.requestedHistoryCap(from: value) == 40)
        }
        #expect(OpenAICompatSession.requestedHistoryCap(from: 21) == 21)
    }

    @Test func historyOverridesAreClampedIndependentlyOfTheDefault() {
        for value in [Int.min, -1, 0, 19] {
            #expect(OpenAICompatSession.requestedHistoryCap(from: value) == 20)
        }
        for value in [120, 121, Int.max] {
            #expect(OpenAICompatSession.requestedHistoryCap(from: value) == 120)
        }
    }

    @Test func unknownContextUsesTheRequestedHistoryCap() {
        for requested in [20, 40, 120] {
            for context: Int? in [nil, 0, -1] {
                #expect(OpenAICompatSession.effectiveHistoryCap(requested: requested, contextLength: context)
                    == requested)
            }
        }
    }

    @Test func aLateContextProbeStillHonorsTheRequestedHistoryCap() {
        for requested in [20, 40] {
            #expect(OpenAICompatSession.effectiveHistoryCap(requested: requested, contextLength: nil)
                == requested)
            #expect(OpenAICompatSession.effectiveHistoryCap(requested: requested, contextLength: 262_144)
                == requested)
        }
    }

    @Test func theContextEstimateCanLowerButNotRaiseTheRequestedCap() {
        #expect(OpenAICompatSession.effectiveHistoryCap(requested: 120, contextLength: 8192) == 64)
        #expect(OpenAICompatSession.effectiveHistoryCap(requested: 40, contextLength: 2048) == 20)
        #expect(OpenAICompatSession.effectiveHistoryCap(requested: 40, contextLength: 1024) == 20)
        #expect(OpenAICompatSession.effectiveHistoryCap(requested: 120, contextLength: Int.max) == 120)
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

    // MARK: request bodies

    @Test func thePreloadAsksForOneTokenBehindTheSystemPrompt() {
        let body = OpenAICompatSession.preloadBody(
            model: "m", systemPrompt: "sys", fields: Set(OpenAICompatSession.ChatField.allCases))
        #expect(body["model"] as? String == "m")
        #expect(body["max_completion_tokens"] as? Int == 1)
        #expect(body["reasoning_effort"] as? String == "none")
        #expect(body["temperature"] as? Int == 0)
        #expect(body["stream"] == nil)
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.first == ["role": "system", "content": "sys"])
        #expect(messages?.last == ["role": "user", "content": "."])
        #expect(messages?.count == 2)

        let plain = OpenAICompatSession.preloadBody(model: "m", systemPrompt: "sys", fields: [])
        #expect(plain["reasoning_effort"] == nil)
        #expect(plain["temperature"] == nil)
        #expect(plain["stream"] == nil)
    }

    @Test func chatBodiesIncludeOnlyTheRequestedOptionalFields() {
        let all = OpenAICompatSession.ChatField.allCases
        let messages = [["role": "system", "content": "sys"], ["role": "user", "content": "hello"]]
        for mask in 0..<8 {
            let fields = Set(all.enumerated().compactMap { index, field in
                mask & (1 << index) != 0 ? field : nil
            })
            let body = OpenAICompatSession.chatBody(
                model: "m", messages: messages, maxCompletionTokens: 2000, fields: fields)
            #expect(body["model"] as? String == "m")
            #expect(body["messages"] as? [[String: String]] == messages)
            #expect(body["max_completion_tokens"] as? Int == 2000)
            #expect(body["reasoning_effort"] as? String == (fields.contains(.reasoningEffort) ? "none" : nil))
            #expect(body["temperature"] as? Int == (fields.contains(.temperature) ? 0 : nil))
            #expect(body["stream"] as? Bool == (fields.contains(.stream) ? true : nil))
        }
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

    @Test func refusalsMatchQuotedNamesAndValidationPaths() {
        for status in [400, 422] {
            for body in ["temperature", "Unsupported parameter: 'temperature'.",
                         #"{"loc":["body","temperature"],"msg":"Extra inputs are not permitted"}"#,
                         "Only the default value of temperature is supported."] {
                #expect(OpenAICompatSession.refuses(field: "temperature", status: status, body: body))
            }
        }
    }

    @Test func similarlyNamedFieldsAreNotRefusals() {
        for field in OpenAICompatSession.ChatField.allCases {
            for name in ["\(field.rawValue)_options", "other_\(field.rawValue)",
                         "\(field.rawValue)2", "up\(field.rawValue)"] {
                #expect(!OpenAICompatSession.refuses(field: field.rawValue, status: 400, body: "Unsupported: \(name)"))
            }
        }
    }

    @Test func aRefusalCanAppearBeyondTheLogExcerpt() {
        let body = String(repeating: "validation detail; ", count: 40) + "Unsupported parameter: temperature"
        #expect(body.utf8.count > 400)
        #expect(OpenAICompatSession.refusedField(
            in: Set(OpenAICompatSession.ChatField.allCases), status: 422, body: body) == .temperature)
    }

    @Test func echoedRequestKeysDoNotIdentifyTheRefusedField() {
        let input = #"{"reasoning_effort": "none", "temperature" : 0, "stream": true}"#
        let all = Set(OpenAICompatSession.ChatField.allCases)
        let unrelated = #"{"detail":[{"loc":["body","max_completion_tokens"],"msg":"Extra inputs are not permitted","input":\#(input)}]}"#
        #expect(OpenAICompatSession.refusedField(in: all, status: 422, body: unrelated) == nil)
        for field in OpenAICompatSession.ChatField.allCases {
            let detail = #"{"detail":[{"loc":["body","\#(field.rawValue)"],"msg":"Extra inputs are not permitted","input":\#(input)}]}"#
            #expect(OpenAICompatSession.refusedField(in: all, status: 422, body: detail) == field)
        }
    }

    @Test func unrelatedErrorsAndUnsentFieldsDoNotTriggerRetries() {
        let all = Set(OpenAICompatSession.ChatField.allCases)
        for status in [200, 401, 403, 404, 429, 500, 503] {
            #expect(OpenAICompatSession.refusedField(in: all, status: status, body: "temperature") == nil)
        }
        #expect(OpenAICompatSession.refusedField(in: all, status: 400, body: "model not found") == nil)
        #expect(OpenAICompatSession.refusedField(in: all, status: 422, body: "stream_options") == nil)
        #expect(OpenAICompatSession.refusedField(
            in: [.reasoningEffort, .temperature], status: 400, body: "stream is unsupported") == nil)
        #expect(OpenAICompatSession.refusedField(in: [], status: 400, body: "temperature") == nil)
    }

    @Test func threeRefusalsAllowAtMostFourRequestsInAnyOrder() throws {
        typealias Field = OpenAICompatSession.ChatField
        let orders: [[Field]] = [
            [.reasoningEffort, .temperature, .stream], [.reasoningEffort, .stream, .temperature],
            [.temperature, .reasoningEffort, .stream], [.temperature, .stream, .reasoningEffort],
            [.stream, .reasoningEffort, .temperature], [.stream, .temperature, .reasoningEffort],
        ]
        for order in orders {
            var fields = Set(Field.allCases)
            var requests = 1
            for rejected in order {
                let field = try #require(OpenAICompatSession.refusedField(
                    in: fields, status: 400, body: "Unsupported parameter: \(rejected.rawValue)"))
                #expect(field == rejected)
                fields.remove(field)
                requests += 1
                let body = OpenAICompatSession.chatBody(model: "m", messages: [], maxCompletionTokens: 2000, fields: fields)
                #expect(body[rejected.rawValue] == nil)
                #expect(OpenAICompatSession.refusedField(in: fields, status: 422, body: rejected.rawValue) == nil)
            }
            #expect(requests == 4)
            #expect(fields.isEmpty)
        }
    }

    @Test func aResponseNamingAllFieldsDisablesThemInAFixedOrder() throws {
        var fields = Set(OpenAICompatSession.ChatField.allCases)
        let detail = "Unsupported: stream, temperature, reasoning_effort"
        for expected in OpenAICompatSession.ChatField.allCases {
            let rejected = try #require(OpenAICompatSession.refusedField(in: fields, status: 422, body: detail))
            #expect(rejected == expected)
            fields.remove(rejected)
        }
        #expect(OpenAICompatSession.refusedField(in: fields, status: 422, body: detail) == nil)
    }

    @Test func preloadRefusalsAllowAtMostThreeRequests() throws {
        typealias Field = OpenAICompatSession.ChatField
        let orders: [[Field]] = [[.reasoningEffort, .temperature], [.temperature, .reasoningEffort]]
        for order in orders {
            var fields: Set<Field> = [.reasoningEffort, .temperature]
            var requests = 1
            for rejected in order {
                let field = try #require(OpenAICompatSession.refusedField(in: fields, status: 422, body: rejected.rawValue))
                fields.remove(field)
                requests += 1
                let body = OpenAICompatSession.preloadBody(model: "m", systemPrompt: "sys", fields: fields)
                #expect(body[rejected.rawValue] == nil)
                #expect(body["stream"] == nil)
            }
            #expect(requests == 3)
            #expect(fields.isEmpty)
        }
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

    @Test(arguments: [false, true])
    func aSuccessfulHTTPCompletionIsPreservedDespiteCancellation(isCancelled: Bool) {
        #expect(OpenAICompatSession.httpCompletionEvent(succeeded: true, isCancelled: isCancelled) == .httpEnd)
    }

    @Test func anUnsuccessfulHTTPCompletionDistinguishesCancellationFromFailure() {
        #expect(OpenAICompatSession.httpCompletionEvent(succeeded: false, isCancelled: true) == .httpCancelled)
        #expect(OpenAICompatSession.httpCompletionEvent(succeeded: false, isCancelled: false) == .httpFailed)
    }

    // MARK: collectStreamedAnswer(lines:onPartial:)

    @Test func firstTextTimingSkipsEmptyChunksAndFiresBeforeTheFirstPartial() async throws {
        let seen = PartialLog()
        let lines = [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            chunk(""), chunk("訳"), chunk("文", finish: "stop"),
        ]
        let answer = try await OpenAICompatSession.collectStreamedAnswer(
            lines: AsyncStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            },
            onPartial: { seen.append($0) },
            onFirstText: { seen.append("first_text") })
        #expect(answer == "訳文")
        #expect(seen.entries == ["first_text", "訳", "訳文"])
    }

    @Test func anEmptyAnswerHasNoFirstTextTiming() async throws {
        let seen = PartialLog()
        _ = try await OpenAICompatSession.collectStreamedAnswer(
            lines: AsyncStream { continuation in
                continuation.yield(chunk("", finish: "stop"))
                continuation.finish()
            },
            onPartial: { seen.append($0) },
            onFirstText: { seen.append("first_text") })
        #expect(seen.entries.isEmpty)
    }

    @Test func aTruncatedStreamStillRecordsTheFirstText() async {
        let seen = PartialLog()
        await #expect(throws: OpenAICompatError.self) {
            try await OpenAICompatSession.collectStreamedAnswer(
                lines: AsyncStream { continuation in
                    continuation.yield(chunk("訳"))
                    continuation.finish()
                },
                onPartial: { seen.append($0) },
                onFirstText: { seen.append("first_text") })
        }
        #expect(seen.entries == ["first_text", "訳"])
    }

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
