import Foundation
import Observation

struct Utterance: Identifiable, Sendable {
    let id: UUID
    let time: Date
    let source: String
    var translation: String?
    /// Provisional translation carried over from the live area when the
    /// utterance finalized. Shown (in the pale style) until the final
    /// translation replaces it. Transient — never saved to the JSONL.
    var provisionalTranslation: String? = nil
    /// The final translation failed permanently (retries exhausted). The UI
    /// stops the spinner and shows either the carried-over provisional
    /// translation or a failure label; the saved JSONL records this flag
    /// structurally instead of a localized marker string in `translation`.
    var finalTranslationFailed = false
    /// Which engine produced the displayed translation ("claude" etc.).
    /// Recorded with future engine additions in mind.
    var translationEngine: String?
    /// Mean recognition confidence (0–1, weighted by character count).
    /// nil when the attribute was unavailable.
    let confidence: Double?
    /// The translation was skipped because confidence fell below the threshold
    /// (most likely a misrecognition of a different language).
    var translationSkipped = false

    /// Whether the displayed translation came from an LLM (Claude etc.).
    /// Drives the slide-in effect at the moment the translation arrives.
    var isLLMTranslation: Bool {
        translationEngine != nil
    }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var isRunning = false
    var status = L("status.idle")
    var utterances: [Utterance] = []
    var volatileText = ""
    /// Provisional translation of the in-progress utterance (sentence-boundary
    /// triggered). Displayed in a pale style below the live text; cleared when
    /// the utterance finalizes (the final translation takes over).
    var provisionalText = ""
    /// Identifies the in-progress utterance. Bumped on finalize so provisional
    /// results still in flight for the previous utterance are discarded
    /// instead of applied.
    private(set) var provisionalGeneration = 0
    /// Single source of truth for "the LLM translation lane is live". Set on
    /// successful start (when a backend is configured), dropped when the lane
    /// disables itself after consecutive failures. Read by the UI (pending "…"
    /// display) and by the confidence-skip judgment in the drain.
    var translationReady = false
    /// Font size of translations. Mirrors Preferences; applies to the panel immediately.
    var fontSize = Preferences.fontSize
    /// Font size of the recognized source text. Mirrors Preferences; immediate.
    var sourceFontSize = Preferences.sourceFontSize
    /// Whether the recognized source text is shown. Mirrors Preferences; immediate.
    var sourceTextVisible = Preferences.sourceTextVisible
    /// Whether new utterances appear on top. Mirrors Preferences; applies to the panel immediately.
    var newestOnTop = Preferences.newestOnTop
    /// Number of lines in the live region. Mirrors Preferences; applies to the panel immediately.
    var liveLines = Preferences.liveLines
    /// Opacity of the panel background. Text stays fully opaque; only the background is translucent.
    var panelOpacity = Preferences.panelOpacity

    /// Called for an empty final result: the utterance boundary passed without
    /// a row to append. An empty final still ends the utterance — clear the
    /// in-progress display (volatile and provisional text alike; leaving the
    /// volatile text would keep showing a retracted recognition with a spinner)
    /// and advance the generation so a provisional result still in flight for
    /// the ended utterance cannot be applied to the next one.
    func discardPendingUtterance() {
        volatileText = ""
        provisionalText = ""
        provisionalGeneration += 1
    }

    func appendFinal(_ utterance: Utterance) {
        var utterance = utterance
        // Carry the on-screen provisional translation into the history row so
        // the text being read doesn't vanish at finalize; the final translation
        // replaces it when it arrives. Skipped utterances keep their skip label
        // (their recognition — and thus the provisional — is suspect).
        if !provisionalText.isEmpty, utterance.translation == nil, !utterance.translationSkipped {
            utterance.provisionalTranslation = provisionalText
        }
        utterances.append(utterance)
        volatileText = ""
        provisionalText = ""
        provisionalGeneration += 1
    }

    /// Called when an LLM (Claude etc.) translation arrives.
    func setLLMTranslation(id: UUID, text: String, engine: String) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[index].translation = text
        utterances[index].translationEngine = engine
    }

    /// Called when LLM translation failed even after retries. Marks the row as
    /// permanently failed — the UI derives the failure label (or keeps a
    /// carried-over provisional translation) from the flag. The localized
    /// failure text is never stored in `translation`: it would end up in the
    /// JSONL as data, and rows with a provisional would be recorded
    /// differently from rows without one.
    func markLLMTranslationFailed(id: UUID) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        guard utterances[index].translation == nil else { return }
        utterances[index].finalTranslationFailed = true
    }
}
