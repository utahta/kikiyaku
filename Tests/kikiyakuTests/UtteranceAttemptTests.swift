import Foundation
import Testing

@testable import kikiyaku

/// Streamed partial text reaches the row as separate main-actor tasks, in no
/// guaranteed order against the cleanup of a failed attempt or the pieces
/// of the next one. The attempt number is what keeps a stale piece out.
struct UtteranceAttemptTests {
    private func utterance() -> Utterance {
        Utterance(
            id: UUID(), time: Date(), channel: "system", language: "en-US",
            source: "hello", confidence: nil)
    }

    @Test func theCurrentAttemptsPiecesAreShown() {
        var row = utterance()
        let attempt = row.beginTranslationAttempt()
        row.applyPartialTranslation("こん", attempt: attempt, sequence: 1)
        row.applyPartialTranslation("こんにちは", attempt: attempt, sequence: 2)
        #expect(row.partialTranslation == "こんにちは")
    }

    /// Pieces of one attempt are not ordered against each other either;
    /// each is the answer so far, so an earlier one landing late must not
    /// put a shorter text back.
    @Test func anEarlierPieceLandingLateIsRefused() {
        var row = utterance()
        let attempt = row.beginTranslationAttempt()
        row.applyPartialTranslation("こんにちは", attempt: attempt, sequence: 2)
        row.applyPartialTranslation("こん", attempt: attempt, sequence: 1)
        #expect(row.partialTranslation == "こんにちは")
        row.applyPartialTranslation("こんにちは。", attempt: attempt, sequence: 3)
        #expect(row.partialTranslation == "こんにちは。")
    }

    /// Positions start over with each attempt.
    @Test func positionsRestartWithTheAttempt() {
        var row = utterance()
        let first = row.beginTranslationAttempt()
        row.applyPartialTranslation("一二三", attempt: first, sequence: 3)
        row.endTranslationAttempt()
        let second = row.beginTranslationAttempt()
        row.applyPartialTranslation("二", attempt: second, sequence: 1)
        #expect(row.partialTranslation == "二")
    }

    /// A piece of a failed attempt that runs after the cleanup does not
    /// repopulate the row.
    @Test func aLatePieceOfAnEndedAttemptIsRefused() {
        var row = utterance()
        let first = row.beginTranslationAttempt()
        row.applyPartialTranslation("こん", attempt: first, sequence: 1)
        row.endTranslationAttempt()
        #expect(row.partialTranslation == nil)
        row.applyPartialTranslation("こんにちは", attempt: first, sequence: 2)
        #expect(row.partialTranslation == nil)
    }

    /// Nor does it overwrite the attempt that replaced it.
    @Test func aLatePieceCannotOverwriteTheNextAttempt() {
        var row = utterance()
        let first = row.beginTranslationAttempt()
        row.endTranslationAttempt()
        let second = row.beginTranslationAttempt()
        row.applyPartialTranslation("二", attempt: second, sequence: 1)
        row.applyPartialTranslation("一", attempt: first, sequence: 1)
        #expect(row.partialTranslation == "二")
    }

    /// Ending the attempt leaves the provisional carried over at finalize
    /// in place for the panel to fall back on.
    @Test func endingAnAttemptLeavesTheProvisional() {
        var row = utterance()
        row.provisionalTranslation = "仮"
        let attempt = row.beginTranslationAttempt()
        row.applyPartialTranslation("本", attempt: attempt, sequence: 1)
        row.endTranslationAttempt()
        #expect(row.partialTranslation == nil)
        #expect(row.provisionalTranslation == "仮")
    }

    /// A settled row takes no partial text, and an empty piece never puts a
    /// row into the interim style.
    @Test func settledRowsAndEmptyPiecesAreIgnored() {
        var row = utterance()
        let attempt = row.beginTranslationAttempt()
        row.applyPartialTranslation("", attempt: attempt, sequence: 1)
        #expect(row.partialTranslation == nil)
        row.translation = "確定"
        row.applyPartialTranslation("遅れ", attempt: attempt, sequence: 2)
        #expect(row.partialTranslation == nil)
    }
}
