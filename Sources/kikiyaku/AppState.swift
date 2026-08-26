import Foundation
import Observation

struct Utterance: Identifiable, Sendable {
    let id: UUID
    /// Canonical start time of the utterance's audio on the session-wide clock
    /// (the channel's hostTime epoch plus the recognizer's audio time range) —
    /// not the moment the finalize arrived. With two channels the recognition
    /// delays differ, so arrival order is not speech order; this is.
    let time: Date
    /// Capture channel that produced the utterance ("mic" / "system").
    let channel: String
    /// BCP-47 code of the recognized language (in bidirectional mode, the
    /// adopted language; otherwise language 1).
    let language: String
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

/// Where an utterance stands on the way to its translation.
enum TranslationState {
    /// A translation is genuinely on its way.
    case pending
    case completed
    /// Recognized too poorly to be worth translating.
    case skipped
    /// Attempted and given up on.
    case failed
    /// This session does not translate at all.
    case none
}

extension Utterance {
    /// Judged against the session too, because the utterance alone cannot say
    /// it: a missing translation means "one is coming" only while the session
    /// is translating. Read from `translation == nil` alone — as four separate
    /// places in the UI once did, each with its own set of extra conditions —
    /// a transcription-only session, a skipped utterance and a failed one all
    /// masquerade as work in progress.
    func translationState(translating: Bool) -> TranslationState {
        if translation != nil { return .completed }
        if translationSkipped { return .skipped }
        if finalTranslationFailed { return .failed }
        return translating ? .pending : .none
    }
}

/// Where a session is in its life. Only `.idle` may be reconfigured: a
/// startup has already taken its settings, so a change made during one would
/// show in the settings window while the session ran on the values it
/// captured.
enum SessionPhase {
    case idle
    /// Permissions, model downloads, capture and analyzer startup.
    case starting
    case running
}

/// Key of one live-text slot: a capture channel × recognized language.
struct LiveKey: Hashable, Sendable {
    let channel: String
    let language: String
}

/// One slot's in-progress text plus where its audio range ends on the
/// channel's timeline (0 = unknown). The end drives the staleness judgment
/// between the pair's two racing drains — MainActor serializes their posts,
/// but not in audio order.
struct LiveText: Sendable {
    var text: String
    var audioEnd: TimeInterval
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    /// The session's phase, in one observable value. Two independent flags
    /// (running here, starting on the engine) could disagree, and the one on
    /// the engine was invisible to SwiftUI — which left the settings window
    /// showing editable controls through a startup that can run as long as a
    /// speech-model download.
    var phase: SessionPhase = .idle

    /// A session is under way and producing utterances.
    var isRunning: Bool { phase == .running }
    var status = L("status.idle")
    var utterances: [Utterance] = []
    var volatileText = ""
    /// Latest in-progress text per capture channel × recognized language
    /// (classic mode: one language; bidirectional: up to 2×2). The classic
    /// panel's volatileText is composed with system-first ownership: the
    /// remote side's speech is information the user cannot know, so it
    /// preempts the mic's text the moment it is non-empty; the mic takes the
    /// slot back only while the system channel is silent. Recognition
    /// continues on both channels regardless — ownership affects display
    /// only, never the history. The bidirectional panels read the entries
    /// directly (per language, one live slot per channel).
    private(set) var liveTexts: [LiveKey: LiveText] = [:]
    /// Per-channel watermark on the channel's audio timeline: everything up
    /// to this point has been finalized (adopted). A volatile whose audio
    /// lies entirely at or before it is a late arrival from the other
    /// language's drain for an utterance that already ended — displaying it
    /// would resurrect stale text over a finalized row.
    private var finalizedThrough: [String: TimeInterval] = [:]
    /// The UI shows two language panels instead of the classic one.
    /// Initialized from the configured mode so the layout is visible before
    /// the first start; while idle, settings changes re-sync it immediately
    /// (AppDelegate.applyConfiguredLayout), and a session start pins it to
    /// the running session's configuration.
    var bidirectionalSession = Preferences.bidirectionalConfigured
    /// BCP-47 codes of the language pair the panels bind to
    /// ([language 1, language 2]). Kept in sync the same way.
    var pairLanguageIDs = [Preferences.sourceLocaleID, Preferences.targetLocaleID]
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
    /// Whether the history rows show their source text. Mirrors Preferences; immediate.
    var sourceTextVisible = Preferences.sourceTextVisible
    /// Whether the live region shows the in-progress recognition text. Mirrors Preferences; immediate.
    var liveSourceTextVisible = Preferences.liveSourceTextVisible
    /// Whether new utterances appear on top. Mirrors Preferences; applies to the panel immediately.
    var newestOnTop = Preferences.newestOnTop
    /// Number of lines in the live region. Mirrors Preferences; applies to the panel immediately.
    var liveLines = Preferences.liveLines
    /// Opacity of the panel background. Text stays fully opaque; only the background is translucent.
    var panelOpacity = Preferences.panelOpacity

    /// Publishes one slot's in-progress recognition text and recomposes the
    /// classic panel's live text under the system-first ownership rule.
    /// audioEnd = end of the text's audio range on the channel's timeline
    /// (0 / unknown = always accepted). A volatile whose audio lies entirely
    /// at or before the channel's finalized watermark is dropped: it is a
    /// late arrival from the pair's other-language drain for an utterance
    /// that already finalized, and displaying it would resurrect stale text
    /// (with its spinner) over the finished row.
    func setLive(_ text: String, channel: String, language: String, audioEnd: TimeInterval) {
        if !text.isEmpty, audioEnd > 0, audioEnd <= (finalizedThrough[channel] ?? 0) {
            return
        }
        liveTexts[LiveKey(channel: channel, language: language)] = LiveText(
            text: text, audioEnd: audioEnd)
        recomposeVolatile()
    }

    /// Clears one slot (that recognizer's utterance ended without an adopted
    /// row: an empty final, or a below-threshold finalize in bidirectional
    /// mode).
    func clearLiveSlot(channel: String, language: String) {
        liveTexts[LiveKey(channel: channel, language: language)] = nil
        recomposeVolatile()
    }

    /// Clears all live text (session start/stop).
    func clearLive() {
        liveTexts = [:]
        finalizedThrough = [:]
        volatileText = ""
    }

    /// The live slots one bidirectional panel shows: one per channel with any
    /// in-progress recognition (system first — the remote side's speech above
    /// one's own voice). `text` is this language's volatile when it has one;
    /// nil when only the pair's other language is producing text on that
    /// channel — the panel then shows a spinner-only slot, so speech in
    /// progress is visible on both panels even while one recognizer stays
    /// quiet.
    func liveSlots(language: String) -> [(channel: String, text: String?)] {
        ["system", "mic"].compactMap { channel in
            let anyActive = liveTexts.contains {
                $0.key.channel == channel && !$0.value.text.isEmpty
            }
            guard anyActive else { return nil }
            let own = liveTexts[LiveKey(channel: channel, language: language)]?.text
            return (channel, (own?.isEmpty ?? true) ? nil : own)
        }
    }

    private func recomposeVolatile() {
        // System first; within a channel, take the first non-empty entry in
        // stable language order (classic mode has one language per channel, so
        // the language tiebreak only matters for the bidirectional session,
        // where the classic panel is not the one on display).
        for channel in ["system", "mic"] {
            let entries = liveTexts
                .filter { $0.key.channel == channel && !$0.value.text.isEmpty }
                .sorted { $0.key.language < $1.key.language }
            if let first = entries.first {
                volatileText = first.value.text
                return
            }
        }
        volatileText = ""
    }

    /// Called for an empty final result: the utterance boundary passed without
    /// a row to append. An empty final still ends the utterance — clear the
    /// channel's in-progress display (leaving the volatile text would keep
    /// showing a retracted recognition with a spinner). Only the channel that
    /// owns the provisional pipeline also clears the provisional text and
    /// advances the generation (so an in-flight provisional result for the
    /// ended utterance cannot attach to the next one) — another channel's
    /// finalize must not tear down a provisional it does not own.
    func discardPendingUtterance(channel: String, language: String, ownsProvisional: Bool) {
        clearLiveSlot(channel: channel, language: language)
        if ownsProvisional {
            provisionalText = ""
            provisionalGeneration += 1
        }
    }

    /// audioEnd = end of the finalized utterance's audio range on its
    /// channel's timeline; it advances the channel's finalized watermark.
    func appendFinal(_ utterance: Utterance, ownsProvisional: Bool, audioEnd: TimeInterval) {
        var utterance = utterance
        // Carry the on-screen provisional translation into the history row so
        // the text being read doesn't vanish at finalize; the final translation
        // replaces it when it arrives. Skipped utterances keep their skip label
        // (their recognition — and thus the provisional — is suspect). Only the
        // provisional-owning channel may carry or clear it: a mic finalize
        // grabbing the system channel's provisional would attach it to the
        // wrong utterance.
        if ownsProvisional {
            if !provisionalText.isEmpty, utterance.translation == nil, !utterance.translationSkipped {
                utterance.provisionalTranslation = provisionalText
            }
            provisionalText = ""
            provisionalGeneration += 1
        }
        insertByTime(utterance)
        // The utterance ended: advance the channel's finalized watermark and
        // drop every slot whose audio the finalize covered — including the
        // pair's other recognizer's garbled reading of the same audio, which
        // rarely finalizes at the same moment (left alone, its text and the
        // bare spinner slot would outlive the finalized row). A volatile of a
        // newer utterance (the other drain racing ahead) survives; slots with
        // an unknown range (audioEnd 0) are cleared like before.
        let watermark = max(finalizedThrough[utterance.channel] ?? 0, audioEnd)
        finalizedThrough[utterance.channel] = watermark
        for (key, value) in liveTexts where key.channel == utterance.channel {
            if value.audioEnd <= watermark {
                liveTexts[key] = nil
            }
        }
        recomposeVolatile()
    }

    /// Inserts in canonical startedAt order. Arrivals are nearly in time order
    /// (two channels' recognition delays differ by at most a few seconds), so
    /// scan back from the end.
    private func insertByTime(_ utterance: Utterance) {
        var index = utterances.endIndex
        while index > utterances.startIndex && utterances[index - 1].time > utterance.time {
            index -= 1
        }
        utterances.insert(utterance, at: index)
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
