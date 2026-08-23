import Foundation
import NaturalLanguage

/// One provisional translation request. `generation` identifies the in-progress
/// utterance it belongs to; `sequence` is the revision number within the
/// session. A result is applied only when both still match the latest issued
/// values — the generation guards against the utterance having finalized, the
/// sequence against a newer revision having been requested while this one was
/// in flight (superseded results must be discarded, not briefly displayed).
struct ProvisionalRequest: Sendable {
    let generation: Int
    let sequence: Int
    let text: String
    let isFallback: Bool
}

/// Thread-safe handle to the LLM lane's current session, so the provisional
/// lane can issue ephemeral requests against the same session (sharing its
/// conversation context) while the lane recreates sessions as needed.
final class LLMSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any LLMTranslator)?

    func set(_ newSession: (any LLMTranslator)?) {
        lock.lock()
        session = newSession
        lock.unlock()
    }

    func get() -> (any LLMTranslator)? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}

/// Thread-safe handle to the provisional request currently on the wire, so the
/// engine can abort it the moment its result is known to be unwanted (the
/// utterance finalized, or the boundaries were retracted). Left running, the
/// doomed request keeps occupying the LLM server while the final translation —
/// the one the user is actually waiting for — competes with it for compute.
final class ProvisionalWorkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var work: Task<String, Error>?

    func set(_ newWork: Task<String, Error>?) {
        lock.lock()
        work = newWork
        lock.unlock()
    }

    func cancelCurrent() {
        lock.lock()
        let current = work
        lock.unlock()
        current?.cancel()
    }
}

/// Tracks sentence boundaries in the volatile transcription text and decides
/// when to request a provisional translation.
///
/// Model (per the provisional-translation spec): on every volatile update the
/// full text is re-split with NLTokenizer — multilingual boundary rules are
/// delegated entirely to it. The result is compared as an ordered [String]
/// (normalized only by collapsing whitespace; punctuation and casing changes
/// are meaningful revisions and stay visible). Every sentence except the last
/// counts as "closed" (a following sentence exists); the last is "trailing"
/// and never translated by the primary trigger. A time fallback fires when the
/// trailing sentence has grown for 3 seconds without a boundary appearing —
/// fallback translations include the trailing text but never promote it to
/// closed (the time cut is not a grammatical cut).
///
/// @unchecked Sendable: only ever touched from the drain task.
final class SentenceTracker: @unchecked Sendable {
    enum Trigger {
        /// The closed prefix grew or one of its sentences was revised
        /// (dirtyFrom < closed count). Payload: the closed sentences joined.
        case boundary(String)
        /// The trailing sentence stayed open past the time threshold.
        /// Payload: the whole recognized text so far, trailing included.
        case fallback(String)
        /// A revision removed every sentence boundary (e.g. ASR retracted a
        /// period): the provisional translation on display describes a split
        /// that no longer exists and must be cleared, not left standing.
        case clear
    }

    private let language: NLLanguage?
    private var previous: [String] = []
    private var trailingStarted: Date?
    private var lastFallbackText = ""
    private let fallbackInterval: TimeInterval = 3

    init(locale: Locale) {
        if let code = locale.language.languageCode?.identifier {
            self.language = NLLanguage(rawValue: code)
        } else {
            self.language = nil
        }
    }

    /// Called when the utterance ends (ASR finalize). Clears all boundary state.
    func reset() {
        previous = []
        trailingStarted = nil
        lastFallbackText = ""
    }

    /// Feed the latest volatile text; returns a trigger when a provisional
    /// translation should be requested.
    func update(text: String, now: Date) -> Trigger? {
        let sentences = split(text)
        defer { previous = sentences }
        guard !sentences.isEmpty else {
            // The recognizer retracted the in-progress text entirely. That is a
            // state change, not a result to ignore: any provisional translation
            // on display describes text that no longer exists.
            let hadSentences = !previous.isEmpty
            trailingStarted = nil
            lastFallbackText = ""
            return hadSentences ? .clear : nil
        }

        let closedCount = sentences.count - 1
        let previousClosedCount = max(0, previous.count - 1)

        // First index at which the normalized sentence array diverges from the
        // previous revision. Everything from here on is re-evaluated — later
        // sentences depend on earlier ones for context, so a revision in
        // sentence N invalidates the translations of N+1... as well (the v1
        // whole-prefix translation satisfies that automatically).
        var dirtyFrom = 0
        while dirtyFrom < min(sentences.count, previous.count),
              sentences[dirtyFrom] == previous[dirtyFrom] {
            dirtyFrom += 1
        }

        // A new trailing sentence began (or the text just appeared): restart
        // the fallback timer.
        if sentences.count != previous.count || trailingStarted == nil {
            trailingStarted = now
        }

        if closedCount > 0, closedCount != previousClosedCount || dirtyFrom < closedCount {
            return .boundary(sentences[0..<closedCount].joined(separator: " "))
        }

        // All boundaries vanished in this revision: whatever provisional
        // translation is showing belongs to a split that no longer exists.
        if closedCount == 0, previousClosedCount > 0 {
            return .clear
        }

        // Time fallback: the trailing sentence kept growing without a boundary.
        // Re-arms itself, so a long boundary-less stretch refreshes every
        // interval as long as the text actually changed.
        if let started = trailingStarted,
           now.timeIntervalSince(started) >= fallbackInterval,
           text != lastFallbackText {
            trailingStarted = now
            lastFallbackText = text
            return .fallback(sentences.joined(separator: " "))
        }
        return nil
    }

    private func split(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        if let language {
            tokenizer.setLanguage(language)
        }
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = normalize(String(text[range]))
            if !sentence.isEmpty {
                result.append(sentence)
            }
            return true
        }
        return result
    }

    /// Comparison key normalization: absorb leading/trailing and repeated
    /// whitespace only. Punctuation and casing are NOT normalized — a period
    /// appearing or a capitalization fix is a meaningful revision that must
    /// register as a change.
    private func normalize(_ sentence: String) -> String {
        sentence.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
