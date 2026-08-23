import AVFoundation
import Foundation
import Speech

enum KikiyakuError: Error, CustomStringConvertible {
    case noCompatibleAudioFormat
    case converterUnavailable
    case microphoneDenied
    case speechRecognitionDenied

    var description: String {
        switch self {
        case .noCompatibleAudioFormat: return L("error.noFormat")
        case .converterUnavailable: return L("error.converter")
        case .microphoneDenied: return L("error.micDenied")
        case .speechRecognitionDenied:
            return L("error.speechDenied")
        }
    }
}

/// Orchestrates the whole pipeline: microphone → SpeechTranscriber → LLM
/// translation → AppState. Start/stop run serially on the MainActor, while
/// draining recognition results and translating run in independent Tasks.
@MainActor
final class Engine {
    static let shared = Engine()

    // Re-read from preferences on every start() (changes apply from the next start).
    private var sourceLocale = Locale(identifier: "en-US")
    private var targetLocale = Locale(identifier: "ja-JP")

    private var capture: (any AudioCaptureSource)?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var drainTask: Task<Void, Never>?
    private var claudeTask: Task<Void, Never>?
    private var claudeFeed: AsyncStream<(UUID, String)>.Continuation?
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

    /// start() suspends at several awaits before isRunning is set, so isRunning
    /// alone cannot prevent re-entry (mashing the start button). Guard double
    /// starts with a flag set synchronously before the first await.
    private var isStarting = false

    /// The last stop failed to save, so the transcript only exists in memory.
    /// While set, clearing the history (starting the next session) and quitting
    /// the app are blocked.
    private(set) var hasUnsavedTranscript = false

    func start() async {
        let state = AppState.shared
        guard !state.isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

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
        sourceLocale = Preferences.sourceLocale
        targetLocale = Preferences.targetLocale
        // "Same language, no translation needed" cannot be decided by language code
        // alone: zh-CN (Simplified) and zh-TW (Traditional) share the code zh but
        // need script conversion, so compare including the script (region is
        // ignored: en-US → en-GB still needs no translation).
        let sameLanguage = languageScriptKey(sourceLocale) == languageScriptKey(targetLocale)
        let audioSource = Preferences.audioSource
        do {
            // The microphone permission is only needed for the mic source. The
            // system-audio source uses the separate system-audio-recording
            // permission, which the OS prompts for when the tap is created.
            if audioSource == "mic" {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw KikiyakuError.microphoneDenied
                }
            }

            // Microphone and speech recognition are separate permissions. Request
            // explicitly when undetermined so the dialog reliably appears, and abort
            // with a clear error when denied.
            try await ensureSpeechRecognitionPermission()

            let transcriber = SpeechTranscriber(
                locale: sourceLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.transcriptionConfidence]
            )
            try await ensureSpeechAsset(transcriber: transcriber)

            // Translation is LLM-only. Same-language pairs need no translation,
            // so run recognition alone.
            let translationEnabled = Preferences.translationEnabled
            let backend = Preferences.translationBackend
            var llmFactory: (@Sendable () throws -> any LLMTranslator)?
            var llmName = ""
            if translationEnabled && !sameLanguage {
                let template = Preferences.claudePromptOverride ?? ClaudeSession.defaultPromptTemplate
                let prompt = ClaudeSession.systemPrompt(
                    template: template,
                    sourceName: fullName(sourceLocale),
                    targetName: fullName(targetLocale)
                )
                if backend == "openai" {
                    let baseURL = Preferences.openAIBaseURL
                    let model = Preferences.openAIModel
                    // Use only the key bound to this endpoint host (prevents the
                    // OpenAI key from being sent to a different host such as a
                    // local server).
                    let key = OpenAICompatSession.apiKey(forBaseURL: baseURL)
                    llmName = "openai"
                    llmFactory = { OpenAICompatSession(baseURL: baseURL, apiKey: key, model: model, systemPrompt: prompt) }
                } else if let binary = ClaudeBinary.resolve() {
                    let model = Preferences.claudeModel
                    llmName = "claude"
                    llmFactory = { try ClaudeSession(binary: binary, model: model, systemPrompt: prompt) }
                }
            }
            let useLLM = llmFactory != nil
            // Provisional (per-sentence) translation: only with the
            // OpenAI-compatible backend — the pipe-based Claude CLI session is
            // strictly serial and a provisional request would block finals.
            let provisionalEnabled = useLLM
                && backend == "openai"
                && Preferences.provisionalTranslationEnabled
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

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw KikiyakuError.noCompatibleAudioFormat
            }
            let (inputSeq, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
            // Register resources with the engine the moment they exist — not only
            // after the whole startup succeeds — so the catch path's teardown()
            // can stop them. Registering late meant an analyzer prepare/start
            // failure leaked a running capture (mic tap, or system tap +
            // aggregate + IOProc) and an input stream that kept buffering audio.
            self.inputContinuation = inputCont
            self.analyzer = analyzer

            // Start capture first, then warm up the analyzer. In the opposite order,
            // the first utterance spoken while the model prepares (~1.5s) is lost.
            let capture: any AudioCaptureSource
            if audioSource == "system" {
                let systemSource = SystemAudioSource(analyzerFormat: format) { input in
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
                capture = try MicSource(analyzerFormat: format) { input in
                    inputCont.yield(input)
                }
            }
            self.capture = capture
            // Core Audio setup (tap / aggregate creation, AudioDeviceStart) is
            // blocking IPC with coreaudiod, and the first system-audio start can
            // additionally block on the TCC permission dialog. Run it off the
            // MainActor so the UI stays responsive.
            try await Task.detached { try capture.start() }.value

            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputSeq)

            // One session = one saved file, so clear the history on every start.
            state.utterances.removeAll()
            state.volatileText = ""

            if let llmFactory {
                startLLMTranslator(engineName: llmName, makeSession: llmFactory, sessionBox: sessionBox)
            }
            if let sessionBox {
                startProvisionalLane(box: sessionBox)
            }
            startDrain(transcriber: transcriber, tracker: tracker)

            state.isRunning = true
            // Publish "translation ready" to the UI only after the whole startup
            // succeeded. Setting it earlier would leave a forever-pending "…" in
            // the UI when the mic or analyzer fails to start.
            state.translationReady = useLLM
            lastActivity = Date()
            startAutoStopWatch()
            let sourceLabel = L(audioSource == "system" ? "source.system" : "source.mic")
            if useLLM {
                state.status = LF("status.recognizing", sourceLabel, shortName(sourceLocale), shortName(targetLocale))
            } else if sameLanguage || !translationEnabled {
                state.status = LF("status.recognizingNoTranslation", sourceLabel, shortName(sourceLocale))
            } else {
                // Reached only when the claude backend's CLI cannot be found
                // (the openai backend constructs its session even when
                // misconfigured, and failures surface at runtime through the
                // retry/stop machinery).
                state.status = L("status.recognizingClaudeMissing")
            }
        } catch {
            await teardown()
            state.translationReady = false
            state.status = LF("status.startFailed", String(describing: error))
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
        state.isRunning = false
        state.volatileText = ""
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

    private func teardown() async {
        autoStopTask?.cancel()
        autoStopTask = nil
        capture?.stop()
        capture = nil
        inputContinuation?.finish()
        inputContinuation = nil
        // Kill the provisional lane before draining anything else: its output
        // is worthless once we are stopping, an in-flight request could hold
        // the stop for up to its 60s timeout (URLSession's async APIs are
        // cancellation-aware, so cancel() returns promptly), and on a serial
        // local LLM server it would delay the final translations that the
        // transcript actually keeps.
        provisionalFeed?.finish()
        provisionalFeed = nil
        provisionalTask?.cancel()
        if let provisionalTask {
            await provisionalTask.value
        }
        provisionalTask = nil
        provisionalWork = nil
        // Closing the input stream alone sometimes does not close results
        // (observed on macOS 26.6), so call finalization explicitly.
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                // If finalization fails while results stays open, the drainTask
                // await below never returns and stop/save/quit/relaunch all wedge.
                // Give up on the trailing audio, force-finish to close the stream,
                // and cancel the reader for good measure.
                NSLog("kikiyaku: finalize failed, cancelling analyzer: %@", String(describing: error))
                await analyzer.cancelAndFinishNow()
                drainTask?.cancel()
            }
        }
        analyzer = nil
        if let drainTask {
            await drainTask.value
        }
        drainTask = nil
        claudeFeed?.finish()
        claudeFeed = nil
        if let claudeTask {
            await claudeTask.value
        }
        claudeTask = nil
    }

    // MARK: - Recognition

    private func startDrain(transcriber: SpeechTranscriber, tracker: SentenceTracker?) {
        drainTask = Task.detached { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        // The utterance ended; clear the sentence-boundary state
                        // (even for empty finals, which never reach appendFinal).
                        tracker?.reset()
                        guard !text.isEmpty else {
                            // An utterance boundary still passed: clear the
                            // provisional display and advance the generation so
                            // an in-flight provisional result for the ended
                            // utterance cannot attach to the next one.
                            await MainActor.run {
                                AppState.shared.discardPendingUtterance()
                                Engine.shared.cancelInFlightProvisional()
                            }
                            continue
                        }
                        let confidence = meanConfidence(result.text)
                        let threshold = Preferences.confidenceThreshold
                        let utterance = await MainActor.run { () -> Utterance in
                            // Low-confidence utterances are most likely a different
                            // language (e.g. chatter in the room) forced through the
                            // recognizer, so keep them out of translation. Mark them
                            // as skipped only while translation is actually live —
                            // judged against the current lane state (translationReady,
                            // which drops when the lane disables itself after
                            // consecutive failures), not a value captured at start.
                            // In a session without live translation, "translation
                            // skipped (low confidence)" would misstate what happened
                            // (in the UI and the JSONL).
                            let skip = AppState.shared.translationReady
                                && threshold > 0
                                && (confidence ?? 1.0) < threshold
                            let utterance = Utterance(
                                id: UUID(),
                                time: Date(),
                                source: text,
                                translation: nil,
                                confidence: confidence,
                                translationSkipped: skip
                            )
                            AppState.shared.appendFinal(utterance)
                            Engine.shared.noteActivity()
                            // The utterance ended: abort any provisional still
                            // on the wire so it stops competing with the final
                            // translation that is queued right after this.
                            Engine.shared.cancelInFlightProvisional()
                            return utterance
                        }
                        if !utterance.translationSkipped {
                            await self?.feedTranslation(id: utterance.id, text: text)
                        }
                    } else {
                        // Publish the volatile text and read the state the
                        // provisional trigger needs in the same MainActor hop.
                        let generation = await MainActor.run { () -> Int in
                            AppState.shared.volatileText = text
                            Engine.shared.noteActivity()
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
                // Leaving the capture and isRunning alive with a dead recognition
                // stream would show "running" while nothing appears. Stop the whole
                // engine and complete the save (stop is called in a separate Task,
                // because stop awaits this very drain task).
                let message = error.localizedDescription
                Task { @MainActor in
                    await Engine.shared.stop()
                    AppState.shared.status += LF("status.recognitionErrorSuffix", message)
                }
            }
        }
    }

    private func feedTranslation(id: UUID, text: String) {
        claudeFeed?.yield((id, text))
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
        let (feed, continuation) = AsyncStream<(UUID, String)>.makeStream()
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
            for await (id, text) in feed {
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
                        let result = try await active.translate(text)
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
                            AppState.shared.setLLMTranslation(id: id, text: result, engine: engineName)
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
                    AppState.shared.markLLMTranslationFailed(id: id)
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
    private func startProvisionalLane(box: LLMSessionBox) {
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
                let work = Task { try await session.translateEphemeral(request.text) }
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

    private func ensureSpeechAsset(transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let wanted = sourceLocale.identifier(.bcp47)
        if installed.contains(where: { $0.identifier(.bcp47) == wanted }) { return }
        AppState.shared.status = L("status.downloadingModel")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }


    private func shortName(_ locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier else { return locale.identifier }
        return Preferences.displayLocale.localizedString(forLanguageCode: code) ?? locale.identifier
    }

    /// Full language name including script and region (e.g. "Chinese (Traditional,
    /// Taiwan)"). Used only for the {source}/{target} placeholders in the LLM prompt
    /// (status display uses shortName). The prompt is not UI text, so it does not
    /// follow the UI display language: always use English names to match the default
    /// template (and so the display-language setting cannot change translation
    /// behavior).
    private func fullName(_ locale: Locale) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// "language-script" key (script filled in via likely subtags, region ignored).
    /// Examples: zh-CN → zh-Hans, zh-TW → zh-Hant, en-US / en-GB → en-Latn.
    private func languageScriptKey(_ locale: Locale) -> String {
        let maximal = Locale.Language(identifier: locale.language.maximalIdentifier)
        let code = maximal.languageCode?.identifier ?? locale.identifier
        let script = maximal.script?.identifier ?? ""
        return "\(code)-\(script)"
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
