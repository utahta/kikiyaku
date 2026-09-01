import Foundation
import Testing

@testable import kikiyaku

// The provisional-translation trigger, tested through its public face:
// what update(text:now:) returns as the volatile text evolves. Time is a
// parameter, so the 3-second fallback is tested without waiting.
struct SentenceTrackerTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func tracker() -> SentenceTracker {
        SentenceTracker(locale: Locale(identifier: "ja-JP"))
    }

    @Test func aLoneClosedSentenceIsStillTrailing() {
        let t = tracker()
        #expect(t.update(text: "一文です。", now: start) == nil)
    }

    @Test func aBoundaryFiresWhenTheNextSentenceBegins() {
        let t = tracker()
        _ = t.update(text: "一文です。", now: start)
        guard case .boundary(let closed)? = t.update(text: "一文です。次の", now: start) else {
            Issue.record("expected .boundary"); return
        }
        #expect(closed.contains("一文です。"))
        #expect(!closed.contains("次の"))
    }

    @Test func theFallbackFiresAfterTheIntervalWithoutABoundary() {
        let t = tracker()
        #expect(t.update(text: "区切りのないまま", now: start) == nil)
        guard case .fallback(let text)? =
            t.update(text: "区切りのないまま続く", now: start.addingTimeInterval(3)) else {
            Issue.record("expected .fallback"); return
        }
        #expect(text.contains("区切りのないまま続く"))
    }

    /// The fallback needs the text to have changed — re-translating the same
    /// words refreshes nothing.
    @Test func theFallbackDoesNotRefireOnUnchangedText() {
        let t = tracker()
        _ = t.update(text: "同じ文", now: start)
        _ = t.update(text: "同じ文", now: start.addingTimeInterval(3))
        #expect(t.update(text: "同じ文", now: start.addingTimeInterval(6)) == nil)
    }

    /// ASR retracted the period: the provisional translation on display
    /// describes a split that no longer exists.
    @Test func aRetractedBoundaryClears() {
        let t = tracker()
        _ = t.update(text: "一文です。", now: start)
        _ = t.update(text: "一文です。次の", now: start)
        guard case .clear? = t.update(text: "一文です", now: start) else {
            Issue.record("expected .clear"); return
        }
    }

    @Test func fullyRetractedTextClears() {
        let t = tracker()
        _ = t.update(text: "何か", now: start)
        guard case .clear? = t.update(text: "", now: start) else {
            Issue.record("expected .clear"); return
        }
        // Nothing was showing, so nothing to clear.
        #expect(t.update(text: "", now: start) == nil)
    }
}
