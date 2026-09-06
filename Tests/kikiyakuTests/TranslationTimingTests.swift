import Foundation
import Testing

@testable import kikiyaku

struct TranslationTimingTests {
    @Test func aTimingLineIdentifiesBothRetryLevelsAndTheHistorySnapshot() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let timing = TranslationTiming(id: id, kind: .final, attempt: 2)
        #expect(timing.message(.firstText, httpAttempt: 3, historyPairs: 19,
                               streamed: true, status: 200, uptime: 123.25)
            == "llm_timing id=00000000-0000-0000-0000-000000000001 kind=final attempt=2 "
                + "http_attempt=3 event=first_text uptime_s=123.250000 history_pairs=19 streamed=1 status=200")
    }

    @Test func anUnsentJobDoesNotClaimToHaveAnEmptyHistory() {
        let timing = TranslationTiming(id: UUID(), kind: .provisional, attempt: 0)
        let line = timing.message(.queued, uptime: 1)
        #expect(line.contains("http_attempt=0"))
        #expect(line.contains("history_pairs=-1"))
    }

    @Test func concurrentLanesKeepTheirOwnIdentityAcrossSuspension() async {
        let final = TranslationTiming(id: UUID(), kind: .final, attempt: 1)
        let provisional = TranslationTiming(id: UUID(), kind: .provisional, attempt: 1)
        func read(_ timing: TranslationTiming) async -> UUID? {
            await TranslationTiming.$current.withValue(timing) {
                await Task.yield()
                return TranslationTiming.current?.id
            }
        }
        async let first = read(final)
        async let second = read(provisional)
        let ids = await (first, second)
        #expect(ids.0 == final.id)
        #expect(ids.1 == provisional.id)
        #expect(TranslationTiming.current == nil)
    }
}
