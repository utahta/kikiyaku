import SwiftUI

/// Which window a PanelView instance lives in. The primary panel is the
/// classic single panel — and doubles as the language-1 panel during a
/// bidirectional session; the secondary window exists only for language 2.
enum PanelRole {
    case primary
    case secondary
}

struct PanelView: View {
    var state: AppState
    var role: PanelRole = .primary

    /// Non-nil while the history belongs to a bidirectional session: the
    /// language this panel renders. nil = classic rendering.
    private var panelLanguage: String? {
        guard state.bidirectionalSession else { return nil }
        let ids = state.pairLanguageIDs
        switch role {
        case .primary: return ids.first
        case .secondary: return ids.count > 1 ? ids[1] : nil
        }
    }

    /// Short display name ("日本語" / "English") for the status-bar badge,
    /// in the UI's display language. When the pair's two languages share a
    /// language code (zh-Hans vs zh-Hant — a valid pair, the adoption logic
    /// is script-aware), the short name would label both panels identically,
    /// so fall back to the full locale name ("中国語（簡体字、中国）").
    private func languageName(_ id: String) -> String {
        let locale = Locale(identifier: id)
        guard let code = locale.language.languageCode?.identifier else { return id }
        let pair = state.pairLanguageIDs
        let codesCollide = pair.count > 1
            && Locale(identifier: pair[0]).language.languageCode
                == Locale(identifier: pair[1]).language.languageCode
        if codesCollide {
            return Preferences.displayLocale.localizedString(forIdentifier: id) ?? id
        }
        return Preferences.displayLocale.localizedString(forLanguageCode: code) ?? id
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let language = panelLanguage {
                    BilingualContent(state: state, language: language)
                } else {
                    HistoryContent(state: state)
                }
            }
            .overlay(alignment: .top) {
                // Over the transcript rather than in the footer: the status
                // line is half a panel wide with the button beside it, and an
                // explanation of why a session stopped is exactly the thing
                // that must not be truncated. Only the primary panel carries
                // it — the same reason the footer's controls live there.
                if role == .primary, let notice = state.notice {
                    NoticeBanner(notice: notice) { state.notice = nil }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.notice)
            Divider()
            footer
                .padding(8)
                .padding(.trailing, 10)  // keep clear of the resize grip in the corner
        }
        .frame(minWidth: 300, minHeight: 240)
        // The whole panel shares one translucent background; text stays opaque.
        .background(Color(nsColor: .windowBackgroundColor).opacity(state.panelOpacity))
        // Visual cue that the borderless panel can still be resized by
        // dragging its edges/corners (the grip itself is not a control — the
        // window's normal resize zone does the work).
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(3)
        }
        // The title bar is invisible but still there; reveal its native close
        // button (hidden with the rest of the chrome) only while the pointer
        // is over the panel. Clicking it hides the panel via windowShouldClose.
        .onHover { inside in
            let window = role == .primary ? AppDelegate.panel : AppDelegate.panel2
            window?.standardWindowButton(.closeButton)?.isHidden = !inside
        }
    }

    /// Start/stop and session state live on the primary panel only; the
    /// language-2 panel is a satellite that just names itself. Two identical
    /// footers side by side asked the reader which one was in charge, and
    /// duplicated the whole status line in a layout where horizontal space is
    /// already split in two.
    @ViewBuilder
    private var footer: some View {
        if role == .secondary {
            HStack(spacing: 8) {
                languageBadge
                Spacer()
            }
            .frame(minHeight: 28)
        } else {
            // The button sits in the true centre: the status on the left and
            // an empty region on the right are both flexible, so they split
            // the remaining width evenly. The status can grow to its half and
            // truncate there, never sliding under the button.
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    languageBadge
                    Circle()
                        .fill(state.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(state.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(state.status)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                startStopButton
                // Balances the status region so the button lands in the exact
                // centre. Height pinned to zero: a Color fills whatever space
                // it is offered in *both* axes, and left unpinned this one
                // claimed a share of the panel's height, padding the footer
                // band out no matter how small its contents were.
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }

    @ViewBuilder
    private var languageBadge: some View {
        // Which language this panel carries — visible while idle too, when the
        // status text alone cannot tell the two bidirectional panels apart.
        if let language = panelLanguage {
            Text(languageName(language))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
        }
    }

    /// One glanceable control: a record dot to start, a stop square to end.
    /// Icons rather than words — the panel is read from across a meeting
    /// room and shared on screen, where "Start" in the operator's UI language
    /// means nothing to half the audience.
    private var startStopButton: some View {
        Button {
            Task { @MainActor in
                if state.isRunning {
                    await Engine.shared.stop()
                } else {
                    // The engine does not check the endpoint or the model
                    // at start — it would run, fail three translations in a
                    // row, and give up. So the profile is checked here, and
                    // a profile that cannot start is taken to its editor
                    // instead. The mirror is read back first: this panel
                    // never activates the app, so a `defaults write` made
                    // in a Terminal has had no other chance to be seen.
                    let store = SessionProfileStore.shared
                    store.importMirrorIntoSelected()
                    if let problem = store.selected.setupProblem {
                        state.notice = PanelNotice(
                            kind: .warning,
                            message: LF("notice.setupNeeded", problem.message))
                        AppDelegate.requestShowSettings(editingProfile: true)
                        return
                    }
                    await Engine.shared.start()
                }
            }
        } label: {
            Image(systemName: state.isRunning ? "stop.circle.fill" : "record.circle")
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.isRunning ? Color.secondary : Color.red)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(state.isRunning ? L("panel.stop") : L("panel.start"))
        .accessibilityLabel(state.isRunning ? L("panel.stop") : L("panel.start"))
    }
}

private extension View {
    /// Conditionally selectable text. While the panel is in tap-to-toggle mode
    /// (source text hidden globally), selectable text would swallow the clicks
    /// meant for the row's source toggle, so selection is disabled there.
    @ViewBuilder
    func selectable(_ enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }

    /// Keeps the newest utterance in view in the bottom-following layout,
    /// without pulling the scroll away from someone who went back to re-read.
    func followsBottom() -> some View {
        modifier(FollowsBottom())
    }

    /// Marks this block as still in motion with a rail along its leading edge.
    /// The gutter it needs is reserved whether or not the rail is showing, so
    /// text never slides sideways as one comes or goes.
    func liveRail(_ active: Bool = true) -> some View {
        padding(.leading, 9)
            .overlay(alignment: .leading) {
                if active {
                    LiveRail()
                }
            }
    }

    /// Fades the scrolling content out at the top and bottom edges instead of
    /// letting rows end on a hard cut. The panel is translucent over a meeting
    /// window, so the fade has to remove the text itself (a gradient painted in
    /// the panel colour would just be a bar over the video).
    func edgeFade(_ length: CGFloat = 16) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: length)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: length)
            }
        )
    }
}

/// The scroll state the follow decision needs, sampled together so the two
/// values always describe the same moment.
private struct ScrollExtent: Equatable {
    /// Height of everything in the scroll view.
    var contentHeight: CGFloat
    /// Height of the visible area.
    var containerHeight: CGFloat
    /// How far the bottom of the content sits below the visible area. Zero
    /// means the newest utterance is on screen.
    var bottomGap: CGFloat
}

/// Sticky-bottom scrolling: as long as the reader is at the newest utterance,
/// arriving text keeps itself in view; the moment they scroll up to re-read
/// something, the following stops and stays stopped until they come back down.
///
/// SwiftUI's own bottom anchor for size changes was doing neither reliably:
/// with it, new utterances simply ran off the bottom edge. This watches the
/// geometry instead and decides from the gap *as it was before* the content
/// grew — measured afterwards, every arrival looks like the reader scrolled
/// up, which is exactly the state that must not trigger a jump.
private struct FollowsBottom: ViewModifier {
    @State private var position = ScrollPosition(edge: .bottom)
    /// A row can land a pixel or two off the exact bottom; treat anything
    /// within a line's slack as "still at the newest utterance".
    private let slack: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollExtent.self) { geometry in
                ScrollExtent(
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    bottomGap: geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                )
            } action: { previous, current in
                // Two ways the newest utterance leaves the bottom of the
                // view: content arriving below it, and the panel being made
                // shorter — dragging the window's edge up would otherwise
                // push what was being read out of sight, with nothing to
                // bring it back until the next utterance.
                let grew = current.contentHeight > previous.contentHeight
                let shrank = current.containerHeight < previous.containerHeight
                guard grew || shrank else { return }
                guard previous.bottomGap <= slack else { return }
                position.scrollTo(edge: .bottom)
            }
    }
}

/// Timestamp of an utterance, in the panel's small dim style. The time is the
/// canonical start of the utterance's audio, so the two bidirectional panels
/// can be read against each other, and a row lines up with the same second in
/// the saved JSONL.
private struct UtteranceTime: View {
    let date: Date
    let fontSize: Double

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed 24-hour clock: a compact, sortable column that stays the same
        // width in every locale.
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Text(Self.formatter.string(from: date))
            .font(.system(size: max(9, fontSize * 0.5)))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}

/// The slow breath the two in-progress marks share. A spinner's several turns
/// per second is the wrong register for this panel: it is translucent, always
/// on top, and often inside a screen share, where the fastest-moving thing in
/// frame pulls every viewer's eye away from the captions it is supposed to
/// serve (and costs the video encoder besides). Nothing here animates over the
/// words themselves — only beside them, or where words have yet to arrive.
private extension View {
    @ViewBuilder
    func breathing(_ animate: Bool, phase: Bool, delay: Double = 0) -> some View {
        opacity(animate ? (phase ? 0.85 : 0.3) : 0.55)
            .animation(
                animate
                    ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(delay)
                    : nil,
                value: phase
            )
    }
}

/// A rail down the leading edge of text that has not settled: recognition
/// still running, or a provisional translation still due to be replaced. It
/// sits outside the text, so the words never move when it appears or goes.
private struct LiveRail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3)
            .breathing(!reduceMotion, phase: phase)
            .onAppear { phase = true }
            .accessibilityHidden(true)
    }
}

/// Stands in for a translation that has not arrived: three short blocks lit in
/// turn from the left, in reading order.
///
/// Each block returns to dim on every pass, which keeps this an activity mark
/// rather than a measure of progress. Blocks that lit up cumulatively and
/// stayed lit would claim to know how far along the request is — which nothing
/// here does — and the reset at the end of each loop would read as a failed
/// attempt starting over.
///
/// It still occupies a line's height, so the row is already the size it will
/// be and the arriving translation fades in instead of shoving everything
/// below it down the panel.
private struct SkeletonLine: View {
    let fontSize: Double
    /// What the placeholder is standing in for, spoken by VoiceOver. Almost
    /// always a translation on its way — but a bilingual panel that is hiding
    /// its live source line is waiting on the recognition of its own language,
    /// where nothing is being translated at all.
    var waitingFor: String = L("panel.translating")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Three keeps the mark about as compact as the spinner it replaced. The
    /// count reads as loading dots only in that idiom's shape — round, wide
    /// blobs — and these are narrow upright ticks.
    private let blocks = 3
    /// How long one segment holds the light. Slower than with more segments:
    /// the pass is short, and at the quicker step the three read as frantic
    /// blinking rather than a light moving across them.
    private let step = 0.3
    /// Unlit segments stay visible: the row of them is the track, and a
    /// segmented bar that vanishes between pulses reads as one blinking dot
    /// wandering about instead.
    private let dim = 0.22
    private let lit = 0.95

    var body: some View {
        let height = max(8, fontSize * 0.72)
        Group {
            if reduceMotion {
                track(height: height) { _ in dim }
            } else {
                // Counted from a fixed epoch rather than from when this view
                // appeared, so every pending row in the panel steps together
                // instead of each drifting on its own phase.
                TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: step)) { context in
                    let tick = Int(context.date.timeIntervalSince1970 / step)
                    // One beat longer than the row of segments: the pass ends
                    // dark before starting over, so the loop reads as a cycle
                    // rather than the light jumping back.
                    let position = tick % (blocks + 1)
                    track(height: height) { $0 == position ? lit : dim }
                        .animation(.easeInOut(duration: step * 0.7), value: position)
                }
            }
        }
        .accessibilityLabel(waitingFor)
    }

    private func track(height: Double, opacity: @escaping (Int) -> Double) -> some View {
        HStack(spacing: height * 0.24) {
            ForEach(0..<blocks, id: \.self) { index in
                // Taller than wide: upright segments read as a bar's ticks,
                // where squares sat closer to a row of dots. Kept below the
                // line height — segments that fill it look like a blacked-out
                // line of text rather than a mark that something is working,
                // and carry a line of text's visual weight in a screen share.
                // The width tracks the height at roughly 1:1.8, or the ticks
                // thin into needles.
                RoundedRectangle(cornerRadius: height * 0.07, style: .continuous)
                    .fill(Color.secondary)
                    .opacity(opacity(index))
                    .frame(width: height * 0.44, height: height * 0.78)
            }
        }
        // The segments are small, but the row still holds a full line: the
        // translation that replaces them should not change its height.
        .frame(height: height)
    }
}

/// Classic diagonal-lines resize grip for the bottom-right corner.
private struct ResizeGrip: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 2))
            path.addLine(to: CGPoint(x: 2, y: 12))
            path.move(to: CGPoint(x: 12, y: 7))
            path.addLine(to: CGPoint(x: 7, y: 12))
            path.move(to: CGPoint(x: 12, y: 11))
            path.addLine(to: CGPoint(x: 11, y: 12))
        }
        .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 14, height: 14)
        .allowsHitTesting(false)
    }
}

/// The main history of translations. The newestOnTop setting switches the
/// ordering direction. Text is centered so the reader's gaze can stay in the
/// middle of the panel; all utterances render at the same size.
private struct HistoryContent: View {
    var state: AppState

    /// Rows whose source text is temporarily revealed by a click while the
    /// global "show source text" setting is off (click again to hide). Lets a
    /// translations-only panel spot-check the original of a suspicious
    /// translation without turning sources on everywhere.
    @State private var revealedSourceIDs: Set<UUID> = []

    /// Clicking the live translation slot reveals the in-progress recognition
    /// text the same way. One sticky toggle (persists across utterances until
    /// clicked again), only meaningful while the global setting is off.
    @State private var liveSourceRevealed = false

    /// Without a live translation lane (translation off, same-language pair,
    /// missing CLI, or the lane disabled itself), no translation ever comes —
    /// the source text is the only content, so force it visible regardless of
    /// the display setting. Otherwise rows would render empty in a
    /// transcription-only session. Also re-enables text selection (the click
    /// toggle has nothing to reveal).
    private var sourceForced: Bool {
        !state.translationReady
    }

    /// After an utterance finalizes and before the next one starts, the
    /// finished utterance stays in the live slot (source on top, translation
    /// below) instead of moving into the history immediately — the momentary
    /// blank between utterances read as a distracting flicker. It moves down
    /// as soon as the next volatile text arrives. Display-only: the utterance
    /// is already in the model/history and the JSONL is unaffected.
    private var lingering: Utterance? {
        state.isRunning && state.volatileText.isEmpty ? state.utterances.last : nil
    }

    private var historyUtterances: [Utterance] {
        lingering != nil ? Array(state.utterances.dropLast()) : state.utterances
    }

    private var liveText: String {
        if !state.volatileText.isEmpty { return state.volatileText }
        return lingering?.source ?? " "
    }

    /// The translation slot shows once an utterance is in progress and a
    /// translation lane is live — even when the provisional feature is
    /// unavailable (Claude backend / toggle off), the spinner-only slot is the
    /// panel's sign of life during recognition with hidden sources, and its
    /// click target for revealing the recognition text. Without it, nothing at
    /// all would render until the utterance finalizes.
    private var provisionalSlotVisible: Bool {
        !state.provisionalText.isEmpty
            || (state.translationReady && !state.volatileText.isEmpty)
    }

    var body: some View {
        if state.newestOnTop {
            newestOnTopLayout
        } else {
            bottomFollowingLayout
        }
    }

    /// The translation line shown under the live text: while recognizing, the
    /// provisional translation (spinner-first); while an utterance lingers,
    /// that utterance's translation state (provisional with spinner → final).
    @ViewBuilder
    private var translationSlot: some View {
        if let lingering {
            if lingering.translation != nil {
                TranslationText(utterance: lingering, fontSize: state.fontSize, selectable: liveSourceSettled)
            } else if lingering.translationSkipped {
                Text(LF("panel.skippedConfidence", lingering.confidence.map { String(format: "%.2f", $0) } ?? "-"))
                    .font(.system(size: max(8, state.fontSize * 0.72)))
                    .foregroundStyle(.tertiary)
            } else {
                // No spinner without a live translation lane — nothing is
                // coming, and a perpetual "translating" would lie. When a
                // provisional stays without a final coming, dim and label it
                // (same treatment as history rows).
                let awaitingFinal =
                    lingering.translationState(translating: state.translationReady) == .pending
                if let interim = lingering.interimTranslation {
                    Text(interim)
                        .font(.system(size: state.fontSize))
                        .multilineTextAlignment(.leading)
                        // Dimmed while the final is still due — with the
                        // spinner gone, the colour is what separates a
                        // provisional from a settled translation.
                        .foregroundStyle(.secondary)
                        .selectable(liveSourceSettled)
                } else if lingering.finalTranslationFailed {
                    Text(L("translation.failed"))
                        .font(.system(size: max(8, state.fontSize * 0.72)))
                        .foregroundStyle(.tertiary)
                } else if awaitingFinal {
                    SkeletonLine(fontSize: state.fontSize)
                }
                if !awaitingFinal, lingering.interimTranslation != nil {
                    Text(L("panel.provisionalKept"))
                        .font(.system(size: max(8, state.fontSize * 0.6)))
                        .foregroundStyle(.tertiary)
                }
            }
        } else if provisionalSlotVisible {
            if state.provisionalText.isEmpty {
                SkeletonLine(fontSize: state.fontSize)
            } else {
                Text(state.provisionalText)
                    .font(.system(size: state.fontSize))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                    .selectable(liveSourceSettled)
            }
        }
    }

    /// The translation slot with the click-to-reveal gesture for the live
    /// recognition text (mirrors the per-row source toggle in the history).
    private var liveSlot: some View {
        translationSlot
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                guard !liveSourceSettled else { return }
                liveSourceRevealed.toggle()
            })
    }

    /// The live region answers to its own setting only. The history's setting
    /// governs the rows below and nothing here: someone who wants the source in
    /// the scrollback but not in the live line must be able to have that.
    private var sourceLineVisible: Bool {
        state.liveSourceTextVisible || liveSourceRevealed || sourceForced
    }

    /// With the live source line already on screen, the click-to-reveal gesture
    /// has nothing to reveal, so the slot's text becomes selectable instead
    /// (the same trade the history rows make).
    private var liveSourceSettled: Bool {
        state.liveSourceTextVisible || sourceForced
    }

    /// The live region, in the same [time | content] shape as a history row:
    /// the in-progress recognition text (or the utterance lingering there
    /// after it finalized) with its translation below.
    private var liveArea: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            liveTime
            liveContent
                .liveRail(liveIsWorking)
        }
    }

    /// Whether anything is still happening in the live region: an utterance
    /// being spoken, or one finalized here and genuinely awaiting its
    /// translation. A finished utterance that will never get one — this
    /// session does not translate, the recognition was too poor to bother, the
    /// translation failed for good — is done, and the rail must not keep
    /// insisting otherwise.
    private var liveIsWorking: Bool {
        if !state.volatileText.isEmpty { return true }
        guard let lingering else { return false }
        return lingering.translationState(translating: state.translationReady) == .pending
    }

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            if sourceLineVisible {
                Text(liveText)
                    .font(.system(size: max(9, state.sourceFontSize)))
                    .foregroundStyle(.secondary)
                    // Dynamic height up to the configured line cap (the fixed
                    // reserved height kept the history from jiggling but left
                    // a visible gap when the text was short).
                    .lineLimit(state.liveLines)
                    // For a growing sentence, keeping the tail (the latest words)
                    // visible matters most, so truncate the head.
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            liveSlot
        }
    }

    /// The live region's time column. A finalized utterance held here has a
    /// time like any history row — it is the same utterance, just not moved
    /// down yet, and skipping it left the newest utterance as the only one
    /// without a timestamp for as long as the room stayed quiet. While an
    /// utterance is still being spoken there is no final time to show, so the
    /// column is merely held open: the text must not jump sideways at the
    /// moment the utterance finalizes.
    @ViewBuilder
    private var liveTime: some View {
        if let lingering {
            UtteranceTime(date: lingering.time, fontSize: state.fontSize)
        } else {
            UtteranceTime(date: .distantPast, fontSize: state.fontSize)
                .hidden()
        }
    }

    /// Newest-on-top layout: the live slot (in-progress or lingering utterance)
    /// at the top with its translation right below, then the finalized history
    /// in newest-first order. No divider between them: live → provisional →
    /// history should read as one stream.
    private var newestOnTopLayout: some View {
        VStack(spacing: 0) {
            liveArea
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(historyUtterances.reversed()) { utterance in
                        historyRow(utterance)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
            }
            .edgeFade()
        }
    }

    /// One history row. With the global source-text setting off, a click
    /// toggles that row's source line (simultaneousGesture so text selection
    /// keeps working alongside the tap).
    private func historyRow(_ utterance: Utterance) -> some View {
        UtteranceRow(
            utterance: utterance,
            showsPending: state.translationReady,
            fontSize: state.fontSize,
            sourceFontSize: state.sourceFontSize,
            sourceVisible: state.sourceTextVisible || sourceForced || revealedSourceIDs.contains(utterance.id),
            selectable: state.sourceTextVisible || sourceForced
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard !state.sourceTextVisible, !sourceForced else { return }
            if revealedSourceIDs.contains(utterance.id) {
                revealedSourceIDs.remove(utterance.id)
            } else {
                revealedSourceIDs.insert(utterance.id)
            }
        })
    }

    /// Bottom-following layout (classic): appends downward and keeps the bottom
    /// edge pinned as the content grows.
    private var bottomFollowingLayout: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(historyUtterances) { utterance in
                    historyRow(utterance)
                }
                // Nothing in progress and nothing lingering leaves only the
                // held-open time column, so skip the row entirely.
                if lingering != nil || !state.volatileText.isEmpty || provisionalSlotVisible {
                    liveArea
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 18)
        }
        .edgeFade()
        // No .alignment role: it would bottom-align the history even when
        // there are only a few rows.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .followsBottom()
    }
}

/// One bidirectional language panel: the full conversation in a single
/// language. Utterances adopted in this language appear as their original
/// text immediately; utterances adopted in the other language appear as
/// their translation into this one, holding the row's canonical (startedAt)
/// position with a spinner until the translation lands. The live slots show
/// this language's in-progress recognition per channel (system first).
/// While the other language is being spoken, the live text here is the
/// recognizer's garbled own-language reading — accepted in the spec: it is
/// transient (cleared at finalize) and instantly recognizable as noise to a
/// reader of this language.
private struct BilingualContent: View {
    var state: AppState
    let language: String

    /// Rows whose original (other-language) text is temporarily revealed by a
    /// click. Only meaningful on translation rows while the global source
    /// setting is off.
    @State private var revealedSourceIDs: Set<UUID> = []

    /// Own-language originals always show. Other-language rows show their
    /// translation, or a spinner while one is still coming; when none will
    /// ever come (bilingual transcription mode, or the translation lane went
    /// down without marking this row failed), the row is omitted rather than
    /// spinning forever. Failed rows stay, labeled, so the reader can see the
    /// gap.
    private var rows: [Utterance] {
        state.utterances.filter { utterance in
            utterance.language == language
                || utterance.translation != nil
                || utterance.finalTranslationFailed
                // No translation is coming for a skipped row (possible when a
                // classic session's history is viewed in this layout after a
                // mode switch) — omit it rather than spin forever.
                || (state.translationReady && !utterance.translationSkipped)
        }
    }

    private var liveEntries: [(channel: String, text: String?)] {
        state.liveSlots(language: language)
    }

    var body: some View {
        if state.newestOnTop {
            VStack(spacing: 0) {
                if !liveEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        liveSlots
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rows.reversed()) { utterance in
                            row(utterance)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 18)
                }
                .edgeFade()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { utterance in
                        row(utterance)
                    }
                    liveSlots
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
            }
            .edgeFade()
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .followsBottom()
        }
    }

    /// One live slot per channel with recognition in progress, marked live by
    /// the rail down its leading edge. The text is this language's in-progress
    /// reading when its recognizer is producing one — main font size (this is
    /// the panel's native reading text), secondary colour as the "still
    /// changing" cue. When only the other language is being spoken there is
    /// nothing to read here yet, so the slot holds a skeleton: this panel is
    /// waiting for a translation of what is being said.
    ///
    /// Except when nothing is being translated — bilingual transcription
    /// recognizes both languages and translates neither, so the other
    /// language's utterance will land in its own panel and never in this one.
    /// A placeholder there would promise something that is not coming, and
    /// announce "translating" to a screen reader while no translation exists.
    @ViewBuilder
    private var liveSlots: some View {
        ForEach(liveEntries, id: \.channel) { entry in
            // With the live source line switched off, the skeleton takes its
            // place — but only where a translation is actually coming. Without
            // one this line is all the slot will ever hold, so it stays on
            // regardless of the setting (what sourceForced does for the
            // classic panel).
            let hidingSource =
                entry.text != nil && !state.liveSourceTextVisible && state.translationReady
            let text = hidingSource ? nil : entry.text
            if text != nil || state.translationReady {
                Group {
                    if let text {
                        Text(text)
                            .font(.system(size: state.fontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(state.liveLines)
                            .truncationMode(.head)
                            .multilineTextAlignment(.leading)
                    } else {
                        SkeletonLine(
                            fontSize: state.fontSize,
                            waitingFor: hidingSource
                                ? L("panel.recognizing") : L("panel.translating"))
                    }
                }
                .liveRail()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ utterance: Utterance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UtteranceTime(date: utterance.time, fontSize: state.fontSize)
            VStack(alignment: .leading, spacing: 3) {
                if utterance.language == language {
                    // The original, in this panel's own language.
                    Text(utterance.source)
                        .font(.system(size: state.fontSize))
                        .selectable(state.sourceTextVisible)
                } else {
                    // The other language's utterance, shown as its translation.
                    // A click reveals the original (mirrors the classic panel's
                    // per-row source toggle).
                    if state.sourceTextVisible || revealedSourceIDs.contains(utterance.id) {
                        Text(utterance.source)
                            .font(.system(size: max(9, state.sourceFontSize)))
                            .foregroundStyle(.secondary)
                            .selectable(state.sourceTextVisible)
                    }
                    if utterance.translation != nil {
                        TranslationText(
                            utterance: utterance,
                            fontSize: state.fontSize,
                            selectable: state.sourceTextVisible)
                    } else if let partial = utterance.partialTranslation {
                        // The final as far as it has streamed in. This
                        // layout has no provisional lane, so a partial is
                        // the only interim text a row can have.
                        Text(partial)
                            .font(.system(size: state.fontSize))
                            .foregroundStyle(.secondary)
                            .selectable(state.sourceTextVisible)
                            .liveRail(true)
                    } else if utterance.finalTranslationFailed {
                        Text(L("translation.failed"))
                            .font(.system(size: max(8, state.fontSize * 0.72)))
                            .foregroundStyle(.tertiary)
                    } else {
                        SkeletonLine(fontSize: state.fontSize)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard !state.sourceTextVisible, utterance.language != language else { return }
            if revealedSourceIDs.contains(utterance.id) {
                revealedSourceIDs.remove(utterance.id)
            } else {
                revealedSourceIDs.insert(utterance.id)
            }
        })
    }
}

/// Displays the translation. LLM translations slide in from the bottom the
/// moment they arrive. Explicit failure markers (translation set without an
/// engine) appear without the effect.
private struct TranslationText: View {
    let utterance: Utterance
    let fontSize: Double
    var selectable = true

    var body: some View {
        Group {
            if let translation = utterance.translation {
                if utterance.isLLMTranslation {
                    Text(translation)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .identity
                        ))
                } else {
                    Text(translation)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
            }
        }
        .font(.system(size: fontSize))
        .multilineTextAlignment(.leading)
        .selectable(selectable)
        .animation(.easeInOut(duration: 0.3), value: utterance.translationEngine)
    }
}

/// One utterance: small source line above, translation below. Timestamps are
/// not displayed — the saved JSONL keeps the full per-utterance times.
private struct UtteranceRow: View {
    let utterance: Utterance
    let showsPending: Bool
    let fontSize: Double
    let sourceFontSize: Double
    let sourceVisible: Bool
    var selectable = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UtteranceTime(date: utterance.time, fontSize: fontSize)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            if sourceVisible {
                Text(utterance.source)
                    .font(.system(size: max(9, sourceFontSize)))
                    .foregroundStyle(utterance.translationSkipped ? .tertiary : .secondary)
                    .selectable(selectable)
            }
            if utterance.translation != nil {
                TranslationText(utterance: utterance, fontSize: fontSize, selectable: selectable)
            } else if let interim = utterance.interimTranslation {
                // The final as far as it has streamed in, else the
                // provisional carried over at finalize. Dimmed either way —
                // it is not the settled wording — and marked live by the
                // rail only while a final is still due. Once none is coming
                // (this row failed, or the lane stopped), the rail goes and
                // a label says so explicitly, since colour alone would leave
                // it looking like a settled translation.
                let awaitingFinal =
                    utterance.translationState(translating: showsPending) == .pending
                Text(interim)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .selectable(selectable)
                    .liveRail(awaitingFinal)
                if !awaitingFinal {
                    Text(L("panel.provisionalKept"))
                        .font(.system(size: max(8, fontSize * 0.6)))
                        .foregroundStyle(.tertiary)
                }
            } else if utterance.translationSkipped {
                Text(LF("panel.skippedConfidence", utterance.confidence.map { String(format: "%.2f", $0) } ?? "-"))
                    .font(.system(size: max(8, fontSize * 0.72)))
                    .foregroundStyle(.tertiary)
            } else if utterance.finalTranslationFailed {
                // Failure label is derived from the flag; the localized text is
                // never stored in the utterance itself.
                Text(L("translation.failed"))
                    .font(.system(size: max(8, fontSize * 0.72)))
                    .foregroundStyle(.tertiary)
            } else if showsPending {
                SkeletonLine(fontSize: fontSize)
            }
        }
    }
}

/// A message shown over the transcript until it is dismissed. Deliberately
/// wraps: the reason a session stopped is usually a sentence, and the whole
/// point of moving it off the status line was to stop cutting it in half.
private struct NoticeBanner: View {
    let notice: PanelNotice
    let onDismiss: () -> Void

    private var tint: Color {
        switch notice.kind {
        case .warning: .orange
        case .info: .secondary
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("panel.dismissNotice"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
