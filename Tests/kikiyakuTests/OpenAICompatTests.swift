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
}
