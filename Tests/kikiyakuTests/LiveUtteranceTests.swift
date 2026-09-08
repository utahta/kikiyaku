import Foundation
import Testing

@testable import kikiyaku

@MainActor
struct LiveUtteranceTests {
    private func state() -> AppState {
        let state = AppState()
        state.phase = .running
        state.translationReady = true
        state.utterances = [
            Utterance(
                id: UUID(), time: Date(), channel: "system", language: "en-US",
                source: "hello", confidence: nil)
        ]
        return state
    }

    @Test func finalTranslationStaysLiveUntilNewRecognitionBegins() {
        let state = state()
        let id = state.utterances[0].id
        #expect(state.lingeringLiveUtterance?.id == id)
        let attempt = state.beginLLMTranslationAttempt(id: id)!
        state.setLLMTranslationPartial(id: id, attempt: attempt, sequence: 1, text: "こん")
        #expect(state.lingeringLiveUtterance?.partialTranslation == "こん")

        state.setLLMTranslation(id: id, text: "こんにちは", engine: "openai")
        #expect(state.lingeringLiveUtterance?.id == id)
        #expect(state.lingeringLiveUtterance?.translation == "こんにちは")
        #expect(state.volatileText.isEmpty)
        #expect(state.utterances.count == 1)
        #expect(state.utterances[0].source == "hello")
        #expect(state.utterances[0].translation == "こんにちは")
        state.setLive("next", channel: "system", language: "en-US", audioEnd: 16)
        #expect(state.lingeringLiveUtterance == nil)
        #expect(state.utterances[0].translation == "こんにちは")
    }

    @Test func completingOlderTranslationPreservesNewRecognition() {
        let state = state()
        state.setLive("next", channel: "system", language: "en-US", audioEnd: 0)
        state.provisionalText = "次"
        #expect(state.lingeringLiveUtterance == nil)

        state.setLLMTranslation(id: state.utterances[0].id, text: "こんにちは", engine: "openai")
        #expect(state.lingeringLiveUtterance == nil)
        #expect(state.volatileText == "next")
        #expect(state.provisionalText == "次")
    }

    @Test func completingOlderTranslationPreservesNewPendingUtterance() {
        let state = state()
        let olderID = state.utterances[0].id
        let next = Utterance(
            id: UUID(), time: Date(), channel: "system", language: "en-US",
            source: "next", confidence: nil)
        state.utterances.append(next)
        state.setLLMTranslation(id: olderID, text: "こんにちは", engine: "openai")
        #expect(state.lingeringLiveUtterance?.id == next.id)
    }

    @Test func terminalStatesRemainWithoutPendingTranslation() {
        let state = state()
        state.utterances[0].translationSkipped = true
        #expect(state.lingeringLiveUtterance?.translationState(translating: true) == .skipped)
        state.utterances[0].translationSkipped = false
        state.utterances[0].finalTranslationFailed = true
        #expect(state.lingeringLiveUtterance?.translationState(translating: true) == .failed)
        state.utterances[0].finalTranslationFailed = false
        state.translationReady = false
        #expect(state.lingeringLiveUtterance?.translationState(translating: false) == TranslationState.none)
        #expect(state.volatileText.isEmpty)
    }

    @Test func stoppedAndEmptySessionsDoNotLinger() {
        let state = state()
        state.phase = .idle
        #expect(state.lingeringLiveUtterance == nil)
        state.phase = .running
        state.utterances = []
        #expect(state.lingeringLiveUtterance == nil)
    }

    @Test(arguments: [false, true])
    func aShorterFinalRangeClearsItsRecognizersLiveText(ownsProvisional: Bool) {
        let state = state()
        let row = state.utterances.removeLast()
        state.setLive("interim recognition", channel: "system", language: "en-US",
                      audioEnd: 15.4983125)
        if ownsProvisional { state.provisionalText = "仮訳" }

        state.appendFinal(row, ownsProvisional: ownsProvisional, audioEnd: 14.58)
        #expect(state.volatileText.isEmpty)
        #expect(state.liveTexts.isEmpty)
        #expect(state.provisionalText.isEmpty)
        #expect(state.lingeringLiveUtterance?.id == row.id)
        #expect(state.lingeringLiveUtterance?.source == row.source)

        state.setLLMTranslation(id: row.id, text: "こんにちは", engine: "openai")
        #expect(state.lingeringLiveUtterance?.translation == "こんにちは")
        #expect(state.volatileText.isEmpty)
        #expect(state.utterances.last?.translation == "こんにちは")
    }

    @Test func newRecognitionAfterFinalizationSurvivesTranslationCompletion() {
        let state = state()
        let row = state.utterances.removeLast()
        state.setLive("interim", channel: "system", language: "en-US", audioEnd: 15.4983125)
        state.appendFinal(row, ownsProvisional: false, audioEnd: 14.58)
        state.setLive("next", channel: "system", language: "en-US", audioEnd: 16)
        state.provisionalText = "次"

        state.setLLMTranslation(id: row.id, text: "こんにちは", engine: "openai")
        #expect(state.volatileText == "next")
        #expect(state.provisionalText == "次")
        #expect(state.lingeringLiveUtterance == nil)
    }

    @Test(arguments: [14.58, 15.4983125])
    func otherRecognizersStillUseTheFinalizedRange(otherAudioEnd: Double) {
        let state = state()
        let row = state.utterances.removeLast()
        let otherKey = LiveKey(channel: "system", language: "ja-JP")
        let micKey = LiveKey(channel: "mic", language: "en-US")
        state.setLive("interim", channel: "system", language: "en-US", audioEnd: 15.4983125)
        state.setLive("別の認識", channel: otherKey.channel, language: otherKey.language,
                      audioEnd: otherAudioEnd)
        state.setLive("mic", channel: micKey.channel, language: micKey.language, audioEnd: 1)

        state.appendFinal(row, ownsProvisional: false, audioEnd: 14.58)
        #expect(state.liveTexts[LiveKey(channel: "system", language: "en-US")] == nil)
        #expect((state.liveTexts[otherKey] != nil) == (otherAudioEnd > 14.58))
        #expect(state.liveTexts[micKey]?.text == "mic")
    }
}
