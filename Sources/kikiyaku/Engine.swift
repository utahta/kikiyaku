import AVFoundation
import Foundation
import Speech

enum KikiyakuError: Error, CustomStringConvertible {
    case noCompatibleAudioFormat
    case converterUnavailable
    case microphoneDenied
    case speechRecognitionDenied
    /// A recognition results stream died during startup (before its first
    /// result). Carries the underlying error's message.
    case recognitionStreamFailed(String)
    /// A configured language is not a SpeechTranscriber-supported locale
    /// (BCP-47 id attached). Reachable through display-only rescue entries in
    /// the settings (a stored language the recognizer does not support).
    case languageUnsupported(String)

    var description: String {
        switch self {
        case .noCompatibleAudioFormat: return L("error.noFormat")
        case .converterUnavailable: return L("error.converter")
        case .microphoneDenied: return L("error.micDenied")
        case .speechRecognitionDenied:
            return L("error.speechDenied")
        case .recognitionStreamFailed(let message):
            return message
        case .languageUnsupported(let id):
            return LF("error.languageUnsupported", id)
        }
    }
}

enum ChannelKind: String, Sendable {
    case mic
    case system
}

/// Records the first captured buffer's mach hostTime for one channel — the
/// anchor that maps the channel's private audio timeline (the recognizer's
/// audio time ranges) onto the session-wide clock. Each channel's analyzer
/// counts audio time from its own first buffer, so with two channels the
/// timelines are unrelated until pinned to this common ruler. Written from
/// audio callback threads, read from drain tasks.
final class EpochBox: @unchecked Sendable {
    private let lock = NSLock()
    private var firstHostTime: UInt64?

    func noteBuffer(hostTime: UInt64) {
        guard hostTime != 0 else { return }
        lock.lock()
        if firstHostTime == nil { firstHostTime = hostTime }
        lock.unlock()
    }

    var value: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return firstHostTime
    }
}

/// Carries a drain's results-stream failure to start() with no actor hop.
/// The drain also reports through a MainActor Task, but that report is
/// *queued*: start() runs from the last drain's creation to the commit
/// without suspending, so a queued report cannot run before the commit check
/// (MainActor serialization keeps the report from running concurrently — it
/// equally keeps it from running early). Recorded here synchronously at the
/// moment of failure, every failure that happened before the check is
/// visible to it; a failure after the check is, by definition, a failure of
/// an already-running session. Written from drain tasks, read on the
/// MainActor.
final class StreamFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func record(_ message: String) {
        lock.lock()
        // Keep the first failure: it is the one that explains the rest.
        if self.message == nil { self.message = message }
        lock.unlock()
    }

    func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = message
        message = nil
        return value
    }
}

/// mach hostTime → Date for one session, against a correspondence between the
/// two clocks sampled once at the start.
///
/// The two clocks differ in kind: hostTime is monotonic (audio timing rides on
/// it), while Date is wall time the OS can step forwards or backwards (NTP
/// correction, a manual clock change). Re-sampling the correspondence per
/// utterance would let such a step change the conversion mid-session: audio
/// that came later could convert to an earlier Date, which sorts the utterance
/// into the wrong place in the history and records a wrong time in the JSONL.
/// Anchored once, every utterance of the session converts against the same
/// basis, so relative order and spacing survive whatever the wall clock does.
/// The next session takes a fresh anchor.
struct SessionClock: Sendable {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private let anchorHostTime: UInt64
    private let anchorDate: Date

    init() {
        anchorHostTime = mach_absolute_time()
        anchorDate = Date()
    }

    func date(hostTime: UInt64) -> Date {
        let delta = (Double(hostTime) - Double(anchorHostTime)) * Self.secondsPerTick
        return anchorDate.addingTimeInterval(delta)
    }
}

/// Per-channel pipeline resources: one capture source, one analyzer carrying a
/// transcriber per recognized language (one in classic mode, two in
/// bidirectional mode — verified in Phase A), the input stream between them,
/// and the drain tasks reading each transcriber's results. Fields are set the
/// moment each resource exists — never only after the whole startup succeeded —
/// so a mid-start failure's teardown can stop them.
@MainActor
private final class Channel {
    let kind: ChannelKind
    let epoch = EpochBox()
    var capture: (any AudioCaptureSource)?
    var analyzer: SpeechAnalyzer?
    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    var drainTasks: [Task<Void, Never>] = []

    init(kind: ChannelKind) {
        self.kind = kind
    }
}

/// One finalized utterance queued for the LLM lane. The direction travels with
/// the job because bidirectional mode decides it per utterance (adopted
/// language → the other); classic mode sends the same pair every time.
struct TranslationJob: Sendable {
    let id: UUID
    let text: String
    let sourceID: String
    let targetID: String
}

/// Barrier between channel startup and result processing. Channels start one
/// after another, so an early channel's recognizer can produce results while
/// later channels are still coming up. Each drain subscribes to its results
/// stream immediately (nothing the analyzer delivers is lost) but holds the
/// first result until every channel started and the session state (isRunning,
/// translationReady) is final — processed earlier, a final would be judged
/// against the previous session's state, and an utterance appended during a
/// startup that then fails would vanish unsaved with the failed session.
/// wait() returns false when the startup was aborted: the drain discards
/// everything (an utterance from a session that never started does not exist).
actor StartGate {
    private enum State {
        case pending
        case open
        case aborted
    }

    private var state: State = .pending
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func open() {
        resolve(.open)
    }

    func abort() {
        resolve(.aborted)
    }

    private func resolve(_ outcome: State) {
        guard case .pending = state else { return }
        state = outcome
        let opened = outcome == .open
        for waiter in waiters {
            waiter.resume(returning: opened)
        }
        waiters = []
    }

    func wait() async -> Bool {
        switch state {
        case .open: return true
        case .aborted: return false
        case .pending:
            return await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// Orchestrates the whole pipeline: capture channels → SpeechTranscriber → LLM
/// translation → AppState. Start/stop run serially on the MainActor, while
/// draining recognition results and translating run in independent Tasks.
@MainActor
final class Engine {
    static let shared = Engine()

    // Re-read from preferences on every start() (changes apply from the next start).
    private var sourceLocale = Locale(identifier: "en-US")
    private var targetLocale = Locale(identifier: "ja-JP")

    private var channels: [Channel] = []
    private var claudeTask: Task<Void, Never>?
    private var claudeFeed: AsyncStream<TranslationJob>.Continuation?
    private var provisionalTask: Task<Void, Never>?
    private var provisionalFeed: AsyncStream<ProvisionalRequest>.Continuation?
    private var provisionalWork: ProvisionalWorkBox?
    /// Latest issued provisional revision. A result is applied only while it is
    /// still the newest revision; bumping this invalidates whatever is in
    /// flight (used by requests, clears, and boundary retractions alike).
    private(set) var provisionalSequence = 0
    private var autoStopTask: Task<Void, Never>?
    private var lastActivity = Date()

    /// Called whenever a recognition result (volatile or final) arrives;
    /// resets the silence timer.
    func noteActivity() {
        lastActivity = Date()
    }

    /// Gate holding every drain's first result until the whole startup
    /// succeeded (see StartGate). Kept for teardown to abort, releasing
    /// gate-parked drains on the failure path.
    private var startGate: StartGate?

    /// This session's drains' results-stream failures (see StreamFailureBox).
    /// A fresh box per start, so a failure from a previous session's drain
    /// can never fail the next startup.
    private var streamFailures: StreamFailureBox?

    /// Audio span of one adopted utterance on its channel's timeline.
    /// A nil confidence means the recognizer reported none — unknown, which
    /// is not the same as certain, so such a span neither drops another nor
    /// is dropped by one.
    private struct AdoptedSpan {
        let language: String
        let start: Double
        let end: Double
        let confidence: Double?
    }

    /// Spans adopted so far, per channel — the dedup's memory of what audio
    /// already produced a row. Pruned to the recent past.
    private var adoptedSpans: [String: [AdoptedSpan]] = [:]

    /// Whether this session already reported missing confidence attributes.
    private var reportedMissingConfidence = false

    /// A bidirectional session's finalize arrived without a confidence
    /// attribute, so its language could not be judged and the drain discarded
    /// it. Say so once: the condition is environmental (all finalizes or
    /// none), and left unsaid the user would watch live text run under a
    /// normal "listening" status while no utterance ever lands.
    func noteMissingConfidence() {
        guard !reportedMissingConfidence else { return }
        reportedMissingConfidence = true
        NSLog("kikiyaku: finalize carried no transcriptionConfidence; cannot judge language, discarding")
        AppState.shared.status += L("status.missingConfidenceSuffix")
    }

    /// Partial dedup for the bidirectional modes: records this finalize's
    /// audio span, or refuses it as a duplicate of an already-adopted
    /// utterance. Returns false when the caller should discard the finalize
    /// entirely (no row, no translation).
    ///
    /// Both languages recognize the same audio, so a wrong-language reading
    /// that clears the confidence floor produces a second row — measured at
    /// roughly one in every few utterances, and its hallucinated translation
    /// (a confident-looking rendering of garbage) is the real damage. The two
    /// transcribers of one channel share that channel's audio timeline, so an
    /// overlapping span identifies the same speech exactly, with no semantic
    /// guessing.
    ///
    /// Deliberately one-directional and non-retracting (spec escalation step
    /// ①): only a *later* finalize that is *less* confident than the row
    /// already covering that audio is dropped. Retracting an adopted row in
    /// favour of a more confident latecomer was considered and rejected —
    /// measured confidence picks the right language in 5 of 6 duplicate
    /// pairs, and in the sixth it would have deleted the correct row. Nothing
    /// already shown or translated is ever taken back.
    ///
    /// The earlier worry that the wrong-language side often finalizes first
    /// (leaving nothing to compare against) did not survive measurement: a
    /// wrong-language reading only reaches a high confidence by lumping
    /// several utterances together, which makes it arrive late; when it
    /// finalizes early it scores 0.10–0.27 and the floor already rejects it.
    ///
    /// Known limitation: two people talking over each other in the two
    /// languages on one channel is indistinguishable from this, so the less
    /// confident of the two is dropped. Both are usually garbled anyway.
    func adoptSpan(
        channel: String,
        language: String,
        start: Double,
        end: Double,
        confidence: Double?,
        characters: Int
    ) -> Bool {
        var spans = adoptedSpans[channel] ?? []
        // Bound the memory: an utterance an entire minute back can no longer
        // overlap what is being finalized now.
        spans.removeAll { $0.end < start - 60 }
        defer { adoptedSpans[channel] = spans }
        let duration = end - start
        // Without a usable range there is nothing to compare; adopt (and skip
        // recording, so a bogus span cannot swallow later utterances).
        guard duration > 0 else { return true }
        for span in spans where span.language != language {
            let overlap = min(span.end, end) - max(span.start, start)
            guard overlap > 0 else { continue }
            // Half of the shorter span: a lumped wrong-language finalize can
            // be several times longer than the row it duplicates, so
            // measuring against the new span alone would miss it.
            let shorter = min(span.end - span.start, duration)
            guard shorter > 0, overlap >= shorter * 0.5 else { continue }
            // Two real measurements are required. Treating a missing
            // confidence as certainty would let a recognition nobody scored
            // outrank a genuinely confident one and delete a correct caption.
            guard let adoptedConfidence = span.confidence,
                  let newConfidence = confidence else { continue }
            // Only a clear confidence gap decides. Near-ties carry no signal
            // about which language was really spoken, and dropping on one
            // would discard real content on a coin flip. In the measured
            // duplicate pairs the gap was never below 0.28, so this margin
            // does not weaken any observed case. Compared in thousandths
            // (the scale meanConfidence rounds to) because the binary
            // representation of a 0.100 gap lands just under it.
            let gap = (adoptedConfidence * 1000).rounded() - (newConfidence * 1000).rounded()
            guard gap >= 100 else { continue }
            // Instrument for the residual rate, with no meeting content in
            // the system log: log show --predicate 'process == "kikiyaku"'.
            NSLog("kikiyaku: dedup dropped %@ finalize (conf %.2f, %d chars) over adopted %@ (conf %.2f)",
                  language, newConfidence, characters, span.language, adoptedConfidence)
            return false
        }
        spans.append(AdoptedSpan(
            language: language, start: start, end: end, confidence: confidence))
        return true
    }

    /// The last stop failed to save, so the transcript only exists in memory.
    /// While set, clearing the history (starting the next session) and quitting
    /// the app are blocked.
    private(set) var hasUnsavedTranscript = false

    func start() async {
        let state = AppState.shared
        // start() suspends at several awaits before the session commits, so a
        // "running" test alone cannot prevent re-entry (mashing the button).
        // The phase moves to .starting synchronously, before the first await,
        // and it lives on AppState so the settings window can see it too.
        guard state.phase == .idle else { return }
        state.phase = .starting
        defer {
            // Only when the startup neither committed nor already gave up.
            if state.phase == .starting { state.phase = .idle }
        }
        let failures = StreamFailureBox()
        streamFailures = failures

        // If the previous save failed, retry it before clearing the history.
        // If it still fails, abort the start to protect the data.
        if hasUnsavedTranscript {
            do {
                _ = try TranscriptStore.save(state.utterances)
                hasUnsavedTranscript = false
            } catch {
                state.status = LF("status.startAbortedUnsaved", error.localizedDescription)
                return
            }
        }

        state.status = L("status.preparing")
        // Snapshot the whole session configuration here, before the first
        // await. The settings window stays usable while a start is in flight —
        // and a start can wait on permission dialogs and a speech-model
        // download — so reading preferences at several points would let a
        // change made in that window mix old and new values. For the mode that
        // meant starting in a combination no menu entry offers (switching
        // one-direction translation → bilingual transcription mid-start would
        // pair the old "one direction" with the new "no translation" and run
        // as plain transcription); for the backend it meant a session built
        // from two different profiles. Everything below reads this snapshot
        // only — changed settings apply from the next start, as documented.
        sourceLocale = Preferences.sourceLocale
        targetLocale = Preferences.targetLocale
        let mode = Preferences.sessionMode
        let audioSource = Preferences.audioSource
        let backend = Preferences.translationBackend
        let openAIBaseURL = Preferences.openAIBaseURL
        let openAIModel = Preferences.openAIModel
        let claudeModel = Preferences.claudeModel
        // Resolving the binary reads the claudePath preference too, so it
        // belongs in the snapshot: resolved after the awaits, a path edited
        // mid-start would pair a new executable with this snapshot's model
        // and prompt. Only for the backend that uses it (a few stat() calls).
        let claudeBinary = backend == "claude" ? ClaudeBinary.resolve() : nil
        let promptTemplate = Preferences.claudePromptOverride ?? ClaudeSession.defaultPromptTemplate
        let provisionalPreference = Preferences.provisionalTranslationEnabled
        // One hostTime→Date basis for the whole session (see SessionClock),
        // taken before any capture so every buffer's hostTime maps against it.
        let clock = SessionClock()
        // "Same language, no translation needed" cannot be decided by language code
        // alone: zh-CN (Simplified) and zh-TW (Traditional) share the code zh but
        // need script conversion, so compare including the script (region is
        // ignored: en-US → en-GB still needs no translation).
        let sameLanguage = Preferences.languageScriptKey(sourceLocale)
            == Preferences.languageScriptKey(targetLocale)
        // Bidirectional needs two distinct languages. With an identical pair it
        // is meaningless, so fall back to the classic flow — the same spirit as
        // the existing same-language guard (which runs recognition alone).
        let bidirectional = mode.isBidirectional && !sameLanguage
        let translationEnabled = mode.translates
        let channelKinds: [ChannelKind] = switch audioSource {
        case "system": [.system]
        case "both": [.system, .mic]
        default: [.mic]
        }
        do {
            // The microphone permission is only needed when a mic channel is
            // selected. The system-audio source uses the separate
            // system-audio-recording permission, which the OS prompts for when
            // the tap is created.
            if channelKinds.contains(.mic) {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw KikiyakuError.microphoneDenied
                }
            }

            // Microphone and speech recognition are separate permissions. Request
            // explicitly when undetermined so the dialog reliably appears, and abort
            // with a clear error when denied.
            try await ensureSpeechRecognitionPermission()

            // Languages recognized on every channel: both languages of the pair
            // in bidirectional mode, language 1 alone otherwise. Assets are
            // ensured up front — one download covers all channels.
            let recognizedLocales = bidirectional ? [sourceLocale, targetLocale] : [sourceLocale]
            // Refuse a language the recognizer does not support, with a clear
            // message. A stored value can be a display-only rescue entry from
            // the settings screen (saved before the candidate lists were
            // unified, or written via defaults) — in bidirectional mode
            // language 2 becomes a recognition target and would otherwise
            // fail as an opaque asset/analyzer error. A silent one-direction
            // fallback is deliberately not done: it would contradict the
            // selected mode.
            let supportedIDs = Set(
                await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
            for locale in recognizedLocales {
                let id = locale.identifier(.bcp47)
                guard supportedIDs.contains(id) else {
                    throw KikiyakuError.languageUnsupported(id)
                }
            }
            for locale in recognizedLocales {
                try await ensureSpeechAsset(locale: locale)
            }

            // Translation is LLM-only. Same-language pairs need no translation,
            // so run recognition alone.
            var llmFactory: (@Sendable () throws -> any LLMTranslator)?
            var llmName = ""
            if translationEnabled && !sameLanguage {
                // The prompt is direction-free (the per-message <u> tag
                // attributes carry the direction), so the template is used
                // verbatim — no placeholder substitution.
                let prompt = promptTemplate
                if backend == "openai" {
                    // Use only the key bound to this endpoint host (prevents the
                    // OpenAI key from being sent to a different host such as a
                    // local server). Read here rather than with the snapshot
                    // above: it is a Keychain lookup, and keeping it off the
                    // pre-permission path leaves the unlock prompt where it
                    // has always been.
                    let baseURL = openAIBaseURL
                    let model = openAIModel
                    let key = OpenAICompatSession.apiKey(forBaseURL: baseURL)
                    llmName = "openai"
                    llmFactory = { OpenAICompatSession(baseURL: baseURL, apiKey: key, model: model, systemPrompt: prompt) }
                } else if let binary = claudeBinary {
                    let model = claudeModel
                    llmName = "claude"
                    llmFactory = { try ClaudeSession(binary: binary, model: model, systemPrompt: prompt) }
                }
            }
            let useLLM = llmFactory != nil
            // Provisional (per-sentence) translation: only with the
            // OpenAI-compatible backend — the pipe-based Claude CLI session is
            // strictly serial and a provisional request would block finals.
            // Disabled in bidirectional mode (finals only, per the spec): the
            // racing volatiles have no settled reader for the boundary
            // trigger, rewritten captions confuse shared-screen viewers, and
            // the extra requests would crowd the final-translation lane.
            let provisionalEnabled = useLLM
                && !bidirectional
                && backend == "openai"
                && provisionalPreference
            let sessionBox: LLMSessionBox? = provisionalEnabled ? LLMSessionBox() : nil
            let tracker: SentenceTracker? = provisionalEnabled ? SentenceTracker(locale: sourceLocale) : nil
            if let sessionBox, let llmFactory {
                // Create the first session before any lane starts. Created
                // inside the lane task, session setup races the recognition
                // drain — audio buffered during analyzer warm-up can deliver
                // the first sentence boundary immediately, and the provisional
                // consumer would find an empty box and silently drop that
                // request (per-request sessions are cheap to build here).
                sessionBox.set(try? llmFactory())
            }

            // Lanes come up before any channel starts draining, so the first
            // finalize always finds the translation feed in place.
            if let llmFactory {
                startLLMTranslator(engineName: llmName, makeSession: llmFactory, sessionBox: sessionBox)
            }
            if let sessionBox {
                startProvisionalLane(
                    box: sessionBox,
                    sourceID: sourceLocale.identifier(.bcp47),
                    targetID: targetLocale.identifier(.bcp47))
            }

            // The provisional pipeline follows one channel only: the system
            // channel when present (the remote side's speech — the information
            // the user cannot know), else the mic. Two volatile streams through
            // one sentence tracker would corrupt its boundary detection.
            let provisionalOwner: ChannelKind = channelKinds.contains(.system) ? .system : .mic
            let gate = StartGate()
            startGate = gate
            // Channel startup runs in phases across ALL channels, not one
            // channel at a time: started serially per channel, the mic
            // capture would only come into existence after the system
            // channel's analyzer warm-up (~1.5s), and anything spoken into
            // the mic in that window would be unrecoverable.
            //
            // Phase 1: build every channel's resources (registered as they
            // are created, so a failure anywhere is fully torn down).
            var pending: [PendingChannel] = []
            for kind in channelKinds {
                pending.append(try await buildChannel(kind: kind, locales: recognizedLocales))
            }
            // Phase 2: start every capture. From here each channel's audio
            // buffers into its input stream, so no channel loses speech to
            // any analyzer warm-up. Core Audio setup (tap / aggregate
            // creation, AudioDeviceStart) is blocking IPC with coreaudiod,
            // and the first system-audio start can additionally block on the
            // TCC permission dialog — run it off the MainActor so the UI
            // stays responsive.
            for entry in pending {
                let capture = entry.capture
                try await Task.detached { try capture.start() }.value
            }
            // Phase 3: warm up and start every analyzer (the audio buffered
            // since phase 2 is processed once started), then attach the
            // drains — parked on the gate until the session state is final.
            let pairIDs = recognizedLocales.map { $0.identifier(.bcp47) }
            for entry in pending {
                try await entry.analyzer.prepareToAnalyze(in: entry.format)
                try await entry.analyzer.start(inputSequence: entry.inputSequence)
                let channelTracker = entry.channel.kind == provisionalOwner ? tracker : nil
                for (index, transcriber) in entry.transcribers.enumerated() {
                    // In bidirectional mode each drain translates into the
                    // pair's other language; in classic mode into the
                    // configured target.
                    let targetID = bidirectional
                        ? pairIDs[(index + 1) % pairIDs.count]
                        : targetLocale.identifier(.bcp47)
                    entry.channel.drainTasks.append(makeDrain(
                        transcriber: transcriber,
                        kind: entry.channel.kind,
                        languageID: pairIDs[index],
                        targetID: targetID,
                        epoch: entry.channel.epoch,
                        clock: clock,
                        tracker: channelTracker,
                        bidirectional: bidirectional,
                        gate: gate,
                        failures: failures))
                }
            }

            // A recognition stream may have died during the phases above —
            // erroring before its first result, it never reached the gate,
            // and its failure handler cannot stop a session that is not
            // running yet. Fail the whole startup instead of committing a
            // session with a dead channel behind a success status. The box is
            // read synchronously (not through the drains' queued MainActor
            // report, which could not have run yet — see StreamFailureBox), so
            // every failure up to this instant is caught here and anything
            // later is a failure of the session committed just below.
            if let failure = failures.take() {
                throw KikiyakuError.recognitionStreamFailed(failure)
            }
            // The startup can no longer fail — only now consume the previous
            // session's display. Cleared any earlier, a failed start would
            // wipe the on-screen history (and re-bind the panel layout) for
            // nothing; the gate has kept every new result parked, so nothing
            // needed the clear before this point. clearLive() also resets the
            // per-channel finalized watermarks, which must happen before the
            // gate opens (the new session's audio timeline restarts at zero —
            // an old watermark would swallow all of its volatiles).
            // One session = one saved file, so clear the history on every start.
            state.utterances.removeAll()
            state.clearLive()
            // The dedup's memory is per session: the audio timeline restarts
            // at zero, so a previous session's spans would match this one's
            // opening utterances. Safe here — the gate still holds every
            // drain, so nothing has been adopted yet.
            adoptedSpans = [:]
            reportedMissingConfidence = false
            // Pin the panel layout (classic single panel vs. two language
            // panels) to this session's configuration. While idle the layout
            // follows the settings live (AppDelegate.applyConfiguredLayout);
            // from here to the stop it belongs to the running session.
            state.bidirectionalSession = bidirectional
            state.pairLanguageIDs = recognizedLocales.map { $0.identifier(.bcp47) }
            state.phase = .running
            // Publish "translation ready" to the UI only after the whole startup
            // succeeded. Setting it earlier would leave a forever-pending "…" in
            // the UI when the mic or analyzer fails to start.
            state.translationReady = useLLM
            // Bring the second (language 2) panel up for a bidirectional
            // session; retire it when a classic session takes over. Starting a
            // session is explicit enough to override a panel closed during the
            // last one — this layout is being set up afresh.
            if bidirectional {
                AppDelegate.restoreSecondPanel()
            } else {
                AppDelegate.hideSecondPanel()
            }
            lastActivity = Date()
            startAutoStopWatch()
            let sourceLabel: String = switch audioSource {
            case "system": L("source.system")
            case "both": L("source.both")
            default: L("source.mic")
            }
            if useLLM {
                state.status = bidirectional
                    ? LF("status.recognizingBidirectional", sourceLabel, shortName(sourceLocale), shortName(targetLocale))
                    : LF("status.recognizing", sourceLabel, shortName(sourceLocale), shortName(targetLocale))
            } else if bidirectional && !translationEnabled {
                // Bidirectional with translation off = bilingual transcription.
                state.status = LF("status.recognizingBilingual", sourceLabel, shortName(sourceLocale), shortName(targetLocale))
            } else if sameLanguage || !translationEnabled {
                state.status = LF("status.recognizingNoTranslation", sourceLabel, shortName(sourceLocale))
            } else {
                // Reached only when the claude backend's CLI cannot be found
                // (the openai backend constructs its session even when
                // misconfigured, and failures surface at runtime through the
                // retry/stop machinery).
                state.status = L("status.recognizingClaudeMissing")
            }
            // The session state above is final — release the drains' parked
            // results (results that arrived while later channels were still
            // starting are processed only now, judged against this session's
            // state, never the previous one's).
            await gate.open()
        } catch {
            await teardown()
            state.translationReady = false
            state.status = LF("status.startFailed", String(describing: error))
            // No session came into being; hand the panel layout back to the
            // live settings (the start had pinned it to the failed session's
            // configuration). The starting flag must drop first — the layout
            // sync stands down while it is set (the defer would clear it
            // again, harmlessly).
            state.phase = .idle
            AppDelegate.applyConfiguredLayout()
        }
    }

    /// The stop currently in progress. Re-entrant stop() calls (mashed stop button,
    /// quit and auto-stop coinciding) await this and join it. Prevents double
    /// teardown / double save while guaranteeing callers always return to a
    /// "stopped and saved" state.
    private var stopTask: Task<Void, Never>?

    func stop() async {
        if let existing = stopTask {
            await existing.value
            return
        }
        let state = AppState.shared
        guard state.isRunning else {
            // Recovery path after a failed save: even when already stopped, retry
            // just the save if an unsaved transcript remains. This lets the natural
            // "fix the save directory and stop/quit again" gesture rescue the data.
            if hasUnsavedTranscript {
                do {
                    if let url = try TranscriptStore.save(state.utterances) {
                        state.status = LF("status.saved", url.lastPathComponent)
                    }
                    hasUnsavedTranscript = false
                } catch {
                    state.status = LF("status.saveRetryFailed", error.localizedDescription)
                }
            }
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop() async {
        let state = AppState.shared
        // teardown waits for the translation queue to drain, so every utterance
        // has its translation by this point.
        await teardown()
        state.phase = .idle
        state.clearLive()
        state.provisionalText = ""
        do {
            if let url = try TranscriptStore.save(state.utterances) {
                state.status = LF("status.stopSaved", url.lastPathComponent)
            } else {
                state.status = L("status.stop")
            }
            hasUnsavedTranscript = false
        } catch {
            hasUnsavedTranscript = true
            state.status = LF("status.stopSaveFailed", error.localizedDescription)
        }
        // A session that adopted nothing leaves no display to preserve —
        // re-sync the panel layout with the settings (changes made while the
        // session ran were deferred). With history present, the guard inside
        // keeps the finished session's layout, as before.
        AppDelegate.applyConfiguredLayout()
    }

    /// Silence watchdog against forgetting to stop. Every 30 seconds, check the
    /// time since the last activity and auto-stop once it exceeds the configured
    /// minutes. The stop runs in a separate Task so it does not strangle itself
    /// (teardown cancels this task).
    private func startAutoStopWatch() {
        autoStopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let minutes = Preferences.autoStopMinutes
                guard minutes > 0, AppState.shared.isRunning else { continue }
                if Date().timeIntervalSince(self.lastActivity) >= Double(minutes) * 60 {
                    Task { @MainActor in
                        await Engine.shared.stop()
                        AppState.shared.status += LF("status.autoStopSuffix", minutes)
                    }
                    return
                }
            }
        }
    }

    /// One channel's built-but-not-yet-started pipeline, carried between the
    /// startup phases (build all → start all captures → start all analyzers).
    private struct PendingChannel {
        let channel: Channel
        let capture: any AudioCaptureSource
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
        let inputSequence: AsyncStream<AnalyzerInput>
        let transcribers: [SpeechTranscriber]
    }

    /// Builds one capture channel's resources without starting anything: the
    /// transcribers (one per recognized language), their analyzer, the input
    /// stream between capture and analyzer, and the capture source itself.
    /// Resources are registered on the engine (the channels array and the
    /// channel's fields) the moment they exist — a later step throwing must
    /// leave nothing the catch path's teardown cannot stop. Starting happens
    /// in phases across all channels (see start()).
    private func buildChannel(kind: ChannelKind, locales: [Locale]) async throws -> PendingChannel {
        let channel = Channel(kind: kind)
        channels.append(channel)

        let transcribers = locales.map { locale in
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.transcriptionConfidence]
            )
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers)
        else {
            throw KikiyakuError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: transcribers)
        let (inputSeq, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        channel.inputContinuation = inputCont
        channel.analyzer = analyzer

        let epoch = channel.epoch
        let capture: any AudioCaptureSource
        if kind == .system {
            let systemSource = SystemAudioSource(analyzerFormat: format) { input, hostTime in
                epoch.noteBuffer(hostTime: hostTime)
                inputCont.yield(input)
            }
            // The aggregate goes silently dead when the default output device
            // changes; stop cleanly instead of appearing to run while
            // capturing nothing.
            systemSource.onDeviceInvalidated = {
                Task { @MainActor in
                    await Engine.shared.stop()
                    AppState.shared.status += L("status.outputDeviceChangedSuffix")
                }
            }
            capture = systemSource
        } else {
            capture = try MicSource(analyzerFormat: format) { input, hostTime in
                epoch.noteBuffer(hostTime: hostTime)
                inputCont.yield(input)
            }
        }
        channel.capture = capture
        return PendingChannel(
            channel: channel,
            capture: capture,
            analyzer: analyzer,
            format: format,
            inputSequence: inputSeq,
            transcribers: transcribers
        )
    }

    /// Multi-channel teardown, run as a phase barrier: each phase completes on
    /// every channel before the next begins.
    private func teardown() async {
        autoStopTask?.cancel()
        autoStopTask = nil
        // Release drains parked on the start gate (failure path — a no-op
        // after a successful start, which opened the gate). Left parked, the
        // drain awaits below would never return.
        if let startGate {
            await startGate.abort()
        }
        startGate = nil
        // 1. Stop every capture before finalizing anything: stopping channels
        //    one whole pipeline at a time would leave the later channels
        //    recognizing while the first finalizes, letting speech from after
        //    the stop leak into the transcript.
        for channel in channels {
            channel.capture?.stop()
            channel.capture = nil
        }
        // 2. End all input streams.
        for channel in channels {
            channel.inputContinuation?.finish()
            channel.inputContinuation = nil
        }
        // 3. Kill the provisional lane before draining anything else: its
        //    output is worthless once we are stopping, an in-flight request
        //    could hold the stop for up to its 60s timeout (URLSession's async
        //    APIs are cancellation-aware, so cancel() returns promptly), and on
        //    a serial local LLM server it would delay the final translations
        //    that the transcript actually keeps. (No-op in bidirectional mode —
        //    the provisional lane never starts there.)
        provisionalFeed?.finish()
        provisionalFeed = nil
        provisionalTask?.cancel()
        if let provisionalTask {
            await provisionalTask.value
        }
        provisionalTask = nil
        provisionalWork = nil
        // 4. Finalize all analyzers in parallel. Closing the input stream alone
        //    sometimes does not close results (observed on macOS 26.6), so call
        //    finalization explicitly — and when it fails while results stays
        //    open, the drain await below would never return and
        //    stop/save/quit/relaunch all wedge. Give up on that channel's
        //    trailing audio, force-finish to close the stream, and cancel its
        //    readers for good measure.
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                guard let analyzer = channel.analyzer else { continue }
                let drains = channel.drainTasks
                group.addTask {
                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                    } catch {
                        NSLog("kikiyaku: finalize failed, cancelling analyzer: %@",
                              String(describing: error))
                        await analyzer.cancelAndFinishNow()
                        for drain in drains {
                            drain.cancel()
                        }
                    }
                }
            }
        }
        // 5. Wait for every drain (adoption judgment included — v1 adoption is
        //    stateless, so drain completion is the flush; a future dedup wait
        //    window would add its candidate flush here).
        for channel in channels {
            for drain in channel.drainTasks {
                await drain.value
            }
            channel.drainTasks = []
            channel.analyzer = nil
        }
        channels = []
        adoptedSpans = [:]
        // 6. End the LLM feed and wait for the translation queue, preserving
        //    the invariant that every utterance has its translation by the time
        //    the transcript is saved (step 7, in performStop).
        claudeFeed?.finish()
        claudeFeed = nil
        if let claudeTask {
            await claudeTask.value
        }
        claudeTask = nil
    }

    // MARK: - Recognition

    /// One drain per transcriber: reads its results, publishes volatiles to the
    /// channel's live slot, and turns finals into history rows. In
    /// bidirectional mode two drains per channel race over the same audio and
    /// each finalize is judged independently (adoption below); `tracker` is
    /// non-nil only on the provisional-owning channel's single drain (classic
    /// mode), and the provisional bookkeeping runs only there.
    private func makeDrain(
        transcriber: SpeechTranscriber,
        kind: ChannelKind,
        languageID: String,
        targetID: String,
        epoch: EpochBox,
        clock: SessionClock,
        tracker: SentenceTracker?,
        bidirectional: Bool,
        gate: StartGate,
        failures: StreamFailureBox
    ) -> Task<Void, Never> {
        let kindRaw = kind.rawValue
        return Task.detached { [weak self] in
            var sessionConfirmed = false
            do {
                for try await result in transcriber.results {
                    // Park the first result until every channel started and
                    // the session state is final (see StartGate). An aborted
                    // start discards everything.
                    if !sessionConfirmed {
                        guard await gate.wait() else { return }
                        sessionConfirmed = true
                    }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        // The utterance ended; clear the sentence-boundary state
                        // (even for empty finals, which never reach appendFinal).
                        tracker?.reset()
                        let ownsProvisional = tracker != nil
                        guard !text.isEmpty else {
                            // An utterance boundary still passed: clear this
                            // channel's live display, and (on the owning drain)
                            // the provisional display plus its generation so an
                            // in-flight provisional result for the ended
                            // utterance cannot attach to the next one.
                            await MainActor.run {
                                AppState.shared.discardPendingUtterance(
                                    channel: kindRaw, language: languageID,
                                    ownsProvisional: ownsProvisional)
                                if ownsProvisional {
                                    Engine.shared.cancelInFlightProvisional()
                                }
                            }
                            continue
                        }
                        let confidence = meanConfidence(result.text)
                        // Read per result (the setting applies immediately),
                        // through the floor rule: the bidirectional modes
                        // cannot run without a language judgment, so "off"
                        // falls back to the default there.
                        let threshold = Preferences.confidenceFloor(bidirectional: bidirectional)
                        // The finalized audio's span on the channel timeline.
                        // The end doubles as the live watermark and the start
                        // as the canonical time base (0 = unknown, kept out of
                        // both the staleness math and the dedup).
                        let rangeStart = result.range.start.seconds
                        let rangeEnd = result.range.end.seconds
                        let audioStart = rangeStart.isFinite ? max(0, rangeStart) : 0
                        let audioEnd = rangeEnd.isFinite ? max(0, rangeEnd) : 0
                        // Canonical start time on the session clock: the
                        // channel's hostTime epoch plus the recognizer's audio
                        // time range. Finalize-arrival Date() would interleave
                        // two channels by recognition delay, not by speech.
                        let startedAt: Date
                        if let epochHost = epoch.value {
                            startedAt = clock.date(hostTime: epochHost)
                                .addingTimeInterval(audioStart)
                        } else {
                            startedAt = Date()
                        }
                        if bidirectional {
                            // Independent adoption: judge this finalize alone
                            // against the confidence floor — no pairing with or
                            // waiting for the other language's transcriber. A
                            // rejection is almost always this recognizer forcing
                            // the pair's other language through itself; drop it
                            // silently (no "skipped" row — public captions stay
                            // clean) and just release the live slot.
                            // A result the recognizer did not score cannot be
                            // adopted here either. The floor *is* the language
                            // judgment in these modes, so passing "unknown"
                            // through as certainty (what one-direction mode
                            // does, where nothing competes) would adopt every
                            // unscored reading of the wrong language — and the
                            // dedup could not clean up afterwards, since it
                            // decides on a confidence gap there is none of.
                            // Never observed in practice (0 of 380 finalizes
                            // across the saved sessions and the Phase A
                            // probe), and it would be an all-or-nothing
                            // property of the environment rather than an
                            // occasional miss, so the discard reports itself
                            // instead of leaving empty panels under a
                            // healthy-looking "listening" status.
                            guard let confidence, confidence >= threshold else {
                                await MainActor.run {
                                    AppState.shared.clearLiveSlot(channel: kindRaw, language: languageID)
                                    Engine.shared.noteActivity()
                                    if confidence == nil {
                                        Engine.shared.noteMissingConfidence()
                                    }
                                }
                                continue
                            }
                        }
                        let adopted = await MainActor.run { () -> Utterance? in
                            // Partial dedup (bidirectional modes): both
                            // languages race over the same audio, and a
                            // wrong-language reading that clears the floor
                            // produces a second row for speech already
                            // adopted. Judged here, in the same MainActor hop
                            // as the append, so the two drains cannot both
                            // pass the check for the same audio.
                            if bidirectional,
                               !Engine.shared.adoptSpan(
                                   channel: kindRaw, language: languageID,
                                   start: audioStart, end: audioEnd,
                                   confidence: confidence,
                                   characters: text.count) {
                                AppState.shared.clearLiveSlot(
                                    channel: kindRaw, language: languageID)
                                Engine.shared.noteActivity()
                                return nil
                            }
                            // Classic mode only: low-confidence utterances are
                            // most likely a different language (e.g. chatter in
                            // the room) forced through the recognizer, so keep
                            // them out of translation. Mark them as skipped only
                            // while translation is actually live — judged
                            // against the current lane state (translationReady,
                            // which drops when the lane disables itself after
                            // consecutive failures), not a value captured at
                            // start. In a session without live translation,
                            // "translation skipped (low confidence)" would
                            // misstate what happened (in the UI and the JSONL).
                            // (In bidirectional mode the floor already rejected
                            // above, so skip is always false here.)
                            // An unscored result is deliberately not punished
                            // here: no other recognizer competes for this
                            // audio, so "unknown" is treated as good enough to
                            // translate rather than costing the user the
                            // utterance. The bidirectional modes, where the
                            // score decides which language was spoken, make
                            // the opposite choice above.
                            let skip = !bidirectional
                                && AppState.shared.translationReady
                                && threshold > 0
                                && (confidence ?? 1.0) < threshold
                            let utterance = Utterance(
                                id: UUID(),
                                time: startedAt,
                                channel: kindRaw,
                                language: languageID,
                                source: text,
                                translation: nil,
                                confidence: confidence,
                                translationSkipped: skip
                            )
                            AppState.shared.appendFinal(
                                utterance, ownsProvisional: ownsProvisional, audioEnd: audioEnd)
                            Engine.shared.noteActivity()
                            // The utterance ended: abort any provisional still
                            // on the wire so it stops competing with the final
                            // translation that is queued right after this.
                            if ownsProvisional {
                                Engine.shared.cancelInFlightProvisional()
                            }
                            return utterance
                        }
                        guard let utterance = adopted else { continue }
                        if !utterance.translationSkipped {
                            await self?.feedTranslation(TranslationJob(
                                id: utterance.id, text: text,
                                sourceID: languageID, targetID: targetID))
                        }
                    } else {
                        // Publish the volatile text and read the state the
                        // provisional trigger needs in the same MainActor hop.
                        // The audio range end lets the display drop this
                        // volatile if the other drain's finalize already
                        // covered its audio (arrival order across the two
                        // drains is not audio order).
                        let rangeEnd = result.range.end.seconds
                        let audioEnd = rangeEnd.isFinite ? max(0, rangeEnd) : 0
                        let generation = await MainActor.run { () -> Int in
                            AppState.shared.setLive(
                                text, channel: kindRaw, language: languageID, audioEnd: audioEnd)
                            Engine.shared.noteActivity()
                            guard tracker != nil else { return -1 }
                            return AppState.shared.translationReady
                                ? AppState.shared.provisionalGeneration : -1
                        }
                        if generation >= 0, let tracker,
                           let trigger = tracker.update(text: text, now: Date()) {
                            switch trigger {
                            case .boundary(let closed):
                                await self?.requestProvisional(
                                    generation: generation, text: closed, isFallback: false)
                            case .fallback(let all):
                                await self?.requestProvisional(
                                    generation: generation, text: all, isFallback: true)
                            case .clear:
                                await self?.clearProvisional(generation: generation)
                            }
                        }
                    }
                }
            } catch {
                // Cancellation from teardown's force-finish path is the normal case
                // (a stop is already in progress), so do not pile on another stop.
                if error is CancellationError { return }
                let message = error.localizedDescription
                // Record synchronously first: a start still in flight reads
                // the box directly, and could not see a queued report in
                // time (see StreamFailureBox).
                failures.record(message)
                Task { @MainActor in
                    Engine.shared.handleRecognitionStreamFailure(message)
                }
            }
        }
    }

    /// Acts on a drain's results-stream failure, once the report reaches the
    /// MainActor. Only a running session is stopped here: with no session
    /// running, the failure belongs to a startup — which owns it through the
    /// synchronously recorded box (it either already failed the startup, or
    /// is about to read the box before committing) — or to a session that has
    /// already stopped, where stop() would do nothing anyway. For a running
    /// session, leaving the captures and isRunning alive with a dead
    /// recognition stream would show "running" while nothing appears, so stop
    /// the whole engine and complete the save (in a separate Task, because
    /// stop awaits the very drain that reported this).
    func handleRecognitionStreamFailure(_ message: String) {
        guard AppState.shared.isRunning else { return }
        Task { @MainActor in
            await Engine.shared.stop()
            AppState.shared.status += LF("status.recognitionErrorSuffix", message)
        }
    }

    private func feedTranslation(_ job: TranslationJob) {
        claudeFeed?.yield(job)
    }

    // MARK: - Translation

    /// Starts the LLM translation lane (engine-agnostic). Feeds utterances serially
    /// into a persistent session and swaps the displayed row when the translation
    /// comes back. Adding a future engine only requires an LLMTranslator conformance
    /// and a call passing its factory.
    ///
    /// Failure handling:
    ///   - To avoid losing an utterance to a transient fault, the same utterance is
    ///     attempted up to 2 times (recreating a pipe-based session in between).
    ///   - An utterance that still fails is marked via markLLMTranslationFailed
    ///     (prevents rows waiting on "…" forever).
    ///   - After 3 consecutive failed utterances, give up for this session and drop
    ///     translationReady so the UI reports it correctly (transcription-only from
    ///     then on).
    private func startLLMTranslator(
        engineName: String,
        makeSession: @escaping @Sendable () throws -> any LLMTranslator,
        sessionBox: LLMSessionBox? = nil
    ) {
        let (feed, continuation) = AsyncStream<TranslationJob>.makeStream()
        claudeFeed = continuation
        claudeTask = Task.detached {
            // The provisional lane shares this lane's session (context and all)
            // through the box. The engine pre-creates it before any lane starts
            // (see start()) so the provisional consumer never races session
            // setup; adopt that instance here.
            var session: (any LLMTranslator)? = sessionBox?.get()
            var consecutiveFailures = 0
            var turns = 0
            var disabled = false
            for await job in feed {
                if disabled { continue }
                var delivered = false
                for _ in 0..<2 {
                    do {
                        // Recreate the session every N turns so context growth in a
                        // long meeting does not inflate latency and cost. Per-request
                        // implementations are exempt: they cap their own history, and
                        // recreating them would throw away the meeting context.
                        let needsRefresh = session?.isPerRequest == false && turns >= 100
                        if session == nil || session?.isAlive != true || needsRefresh {
                            session?.shutdown()
                            session = try makeSession()
                            turns = 0
                            sessionBox?.set(session)
                        }
                        guard let active = session else { break }
                        let result = try await active.translate(
                            job.text, sourceID: job.sourceID, targetID: job.targetID)
                        turns += 1
                        if result.isEmpty {
                            // Treat an empty response as a failure too. A pipe-based
                            // session may be unhealthy, so rebuild it before the
                            // normal retry.
                            if !active.isPerRequest {
                                session?.shutdown()
                                session = nil
                            }
                            continue
                        }
                        await MainActor.run {
                            AppState.shared.setLLMTranslation(id: job.id, text: result, engine: engineName)
                        }
                        delivered = true
                        break
                    } catch {
                        // Log the reason to the unified log
                        // (log show --predicate 'process == "kikiyaku"').
                        NSLog("kikiyaku: %@ translate failed: %@", engineName, String(describing: error))
                        // Discard pipe-based sessions: the response correspondence
                        // may be corrupted. Keep per-request sessions: the failed
                        // request was never recorded in history, and discarding the
                        // session over a transient network error or 5xx would also
                        // discard the meeting context — and with it, translation
                        // quality.
                        if session?.isPerRequest != true {
                            session?.shutdown()
                            session = nil
                        }
                    }
                }
                if delivered {
                    consecutiveFailures = 0
                    continue
                }
                consecutiveFailures += 1
                await MainActor.run {
                    AppState.shared.markLLMTranslationFailed(id: job.id)
                }
                if consecutiveFailures >= 3 {
                    disabled = true
                    await MainActor.run {
                        AppState.shared.status = LF("status.llmStoppedNone", engineName)
                        AppState.shared.translationReady = false
                        // Take the provisional pipeline down with the lane: a
                        // stale provisional would otherwise stay on display
                        // with a spinner promising a translation that will
                        // never come.
                        Engine.shared.invalidateProvisional()
                    }
                }
            }
            sessionBox?.set(nil)
            session?.shutdown()
        }
    }

    private func requestProvisional(generation: Int, text: String, isFallback: Bool) {
        provisionalSequence += 1
        // Doubles as the field instrument for the spec's open question (how
        // often the tokenizer sees boundaries in volatile text vs. the time
        // fallback carrying the load): log show --predicate 'process == "kikiyaku"'.
        NSLog("kikiyaku: provisional trigger %@ (%d chars)",
              isFallback ? "fallback" : "boundary", text.count)
        provisionalFeed?.yield(ProvisionalRequest(
            generation: generation, sequence: provisionalSequence,
            text: text, isFallback: isFallback))
    }

    /// Shuts the provisional pipeline's pending output down: clears the display
    /// and invalidates whatever request is in flight. Called when the LLM lane
    /// disables itself — leaving a stale provisional up would keep the slot
    /// and its spinner alive with no translation ever coming.
    func invalidateProvisional() {
        provisionalSequence += 1
        AppState.shared.provisionalText = ""
        cancelInFlightProvisional()
    }

    /// Aborts the provisional request currently on the wire, if any. Called the
    /// moment its result becomes unwanted — the utterance finalized, or its
    /// boundaries were retracted — so the doomed request stops occupying the
    /// LLM server while the final translation runs (on a serial or busy local
    /// server it would otherwise delay the translation the user is waiting for).
    func cancelInFlightProvisional() {
        provisionalWork?.cancelCurrent()
    }

    /// A revision retracted every sentence boundary: clear the provisional
    /// display and invalidate whatever request is in flight — its text
    /// describes a split that no longer exists.
    private func clearProvisional(generation: Int) {
        provisionalSequence += 1
        cancelInFlightProvisional()
        guard AppState.shared.provisionalGeneration == generation else { return }
        AppState.shared.provisionalText = ""
    }

    /// Provisional translation lane. Consumes boundary/fallback triggers with a
    /// latest-wins policy: the stream buffers only the newest pending request,
    /// so triggers arriving while a translation is in flight coalesce and only
    /// the most recent text is translated next. Results are applied only while
    /// their utterance is still in progress (generation check) — a result
    /// landing after finalize is discarded, never shown over the final
    /// translation. Failures are logged and dropped: the next trigger
    /// supersedes them, and the main lane owns the error accounting
    /// (3-strike disable etc.).
    private func startProvisionalLane(box: LLMSessionBox, sourceID: String, targetID: String) {
        let workBox = ProvisionalWorkBox()
        provisionalWork = workBox
        let (feed, continuation) = AsyncStream<ProvisionalRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        provisionalFeed = continuation
        provisionalTask = Task.detached {
            for await request in feed {
                guard let session = box.get() else { continue }
                // Pre-flight check: a buffered request may already be stale —
                // the utterance finalized or a newer revision superseded it
                // while the previous one was on the wire. The post-response
                // guard below prevents wrong display, but only checking BEFORE
                // sending prevents a doomed request from occupying the server
                // ahead of the final translation the user is waiting for.
                let stillWanted = await MainActor.run {
                    AppState.shared.provisionalGeneration == request.generation
                        && Engine.shared.provisionalSequence == request.sequence
                        && AppState.shared.translationReady
                }
                guard stillWanted else { continue }
                // Run the request as a handle the engine can abort mid-flight
                // (finalize / boundary retraction), bridging the lane's own
                // cancellation (teardown) into it so stop still kills it too.
                let work = Task {
                    try await session.translateEphemeral(
                        request.text, sourceID: sourceID, targetID: targetID)
                }
                workBox.set(work)
                defer { workBox.set(nil) }
                // Close the race between the pre-flight check and the
                // registration above: a finalize landing in that window called
                // cancelCurrent() while nothing was registered yet. Re-verify
                // now that the handle is in place, and cancel it ourselves if
                // the request went stale in the gap. (A sticky "cancel the next
                // registration" flag would be wrong instead — it could shoot
                // down the next utterance's perfectly valid first request.)
                let stillCurrent = await MainActor.run {
                    AppState.shared.provisionalGeneration == request.generation
                        && Engine.shared.provisionalSequence == request.sequence
                }
                if !stillCurrent {
                    work.cancel()
                }
                do {
                    let result = try await withTaskCancellationHandler {
                        try await work.value
                    } onCancel: {
                        work.cancel()
                    }
                    await MainActor.run {
                        let state = AppState.shared
                        guard state.provisionalGeneration == request.generation,
                              Engine.shared.provisionalSequence == request.sequence,
                              state.translationReady else { return }
                        state.provisionalText = result
                    }
                } catch {
                    // Cancelling an in-flight HTTP request surfaces as
                    // URLError(.cancelled), not necessarily CancellationError —
                    // both are the intended abort, not a failure to log.
                    let isCancellation = error is CancellationError
                        || (error as? URLError)?.code == .cancelled
                    if isCancellation {
                        // Lane teardown ends the loop; a per-request abort
                        // (the utterance finalized while this was on the wire)
                        // just moves on to the next trigger.
                        if Task.isCancelled { return }
                        continue
                    }
                    NSLog("kikiyaku: provisional translate failed: %@", String(describing: error))
                }
            }
        }
    }

    // MARK: - Permissions

    private func ensureSpeechRecognitionPermission() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                // The requestAuthorization callback runs on a background queue
                // (TCC's XPC reply queue). Without @Sendable to drop the inferred
                // MainActor isolation, the runtime isolation check crashes.
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
            guard status == .authorized else { throw KikiyakuError.speechRecognitionDenied }
        default:
            throw KikiyakuError.speechRecognitionDenied
        }
    }

    // MARK: - Models

    private func ensureSpeechAsset(locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let wanted = locale.identifier(.bcp47)
        if installed.contains(where: { $0.identifier(.bcp47) == wanted }) { return }
        AppState.shared.status = L("status.downloadingModel")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }


    private func shortName(_ locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier else { return locale.identifier }
        return Preferences.displayLocale.localizedString(forLanguageCode: code) ?? locale.identifier
    }

}

/// Mean confidence of an utterance (weighted by character count, rounded to 3
/// decimal places). CJK splits runs into single characters, so weight by character
/// count rather than run count.
private func meanConfidence(_ text: AttributedString) -> Double? {
    var weightedSum = 0.0
    var weight = 0
    for run in text.runs {
        guard let confidence = run.transcriptionConfidence else { continue }
        let count = text[run.range].characters.count
        weightedSum += confidence * Double(count)
        weight += count
    }
    guard weight > 0 else { return nil }
    return ((weightedSum / Double(weight)) * 1000).rounded() / 1000
}
