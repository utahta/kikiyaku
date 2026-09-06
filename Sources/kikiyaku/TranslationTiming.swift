import Foundation

/// Task-local identity joins lane and HTTP timings without changing translator inputs.
struct TranslationTiming: Sendable {
    enum Kind: String, Sendable {
        case final, provisional, preload
    }

    enum Event: String {
        case queued, started, completed, failed, cancelled, dropped
        case httpStart = "http_start"
        case firstText = "first_text"
        case httpEnd = "http_end"
        case httpRetry = "http_retry"
        case httpFailed = "http_failed"
        case httpCancelled = "http_cancelled"
    }

    @TaskLocal static var current: TranslationTiming?

    let id: UUID
    let kind: Kind
    let attempt: Int

    func log(
        _ event: Event, httpAttempt: Int = 0, historyPairs: Int = -1,
        streamed: Bool = false, status: Int = 0
    ) {
        debugLog(message(
            event, httpAttempt: httpAttempt, historyPairs: historyPairs,
            streamed: streamed, status: status,
            uptime: ProcessInfo.processInfo.systemUptime))
    }

    // Uptime keeps elapsed measurements independent of wall-clock adjustments.
    func message(
        _ event: Event, httpAttempt: Int = 0, historyPairs: Int = -1,
        streamed: Bool = false, status: Int = 0, uptime: TimeInterval
    ) -> String {
        let timestamp = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), uptime)
        return "llm_timing id=\(id.uuidString) kind=\(kind.rawValue) attempt=\(attempt) "
            + "http_attempt=\(httpAttempt) event=\(event.rawValue) uptime_s=\(timestamp) "
            + "history_pairs=\(historyPairs) streamed=\(streamed ? 1 : 0) status=\(status)"
    }
}
