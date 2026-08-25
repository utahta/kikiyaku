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
            if let language = panelLanguage {
                BilingualContent(state: state, language: language)
            } else {
                HistoryContent(state: state)
            }
            Divider()
            HStack(spacing: 8) {
                // Which language this panel carries — visible while idle too,
                // when the status text alone cannot tell the two bidirectional
                // panels apart.
                if let language = panelLanguage {
                    Text(languageName(language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Circle()
                    .fill(state.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(state.status)
                Spacer()
                Button(state.isRunning ? L("panel.stop") : L("panel.start")) {
                    Task { @MainActor in
                        if state.isRunning {
                            await Engine.shared.stop()
                        } else {
                            await Engine.shared.start()
                        }
                    }
                }
                .controlSize(.small)
            }
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
}

/// Spinner marking a translation that is still in motion: shown at the head of
/// provisional translations (which may still change) and in place of a pending
/// row's translation until the final one arrives. The spinner carries the
/// "not final yet" signal, so the text itself keeps the normal color.
private struct PendingSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(.secondary)
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
                TranslationText(utterance: lingering, fontSize: state.fontSize, selectable: state.sourceTextVisible)
            } else if lingering.translationSkipped {
                Text(LF("panel.skippedConfidence", lingering.confidence.map { String(format: "%.2f", $0) } ?? "-"))
                    .font(.system(size: max(8, state.fontSize * 0.72)))
                    .foregroundStyle(.tertiary)
            } else {
                // No spinner without a live translation lane — nothing is
                // coming, and a perpetual "translating" would lie. When a
                // provisional stays without a final coming, dim and label it
                // (same treatment as history rows).
                let awaitingFinal = state.translationReady && !lingering.finalTranslationFailed
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if awaitingFinal {
                        PendingSpinner()
                    }
                    if let provisional = lingering.provisionalTranslation {
                        Text(provisional)
                            .font(.system(size: state.fontSize))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(awaitingFinal ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .selectable(state.sourceTextVisible)
                    } else if lingering.finalTranslationFailed {
                        Text(L("translation.failed"))
                            .font(.system(size: max(8, state.fontSize * 0.72)))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !awaitingFinal, lingering.provisionalTranslation != nil {
                    Text(L("panel.provisionalKept"))
                        .font(.system(size: max(8, state.fontSize * 0.6)))
                        .foregroundStyle(.tertiary)
                }
            }
        } else if provisionalSlotVisible {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PendingSpinner()
                if !state.provisionalText.isEmpty {
                    Text(state.provisionalText)
                        .font(.system(size: state.fontSize))
                        .multilineTextAlignment(.center)
                        .selectable(state.sourceTextVisible)
                }
            }
        }
    }

    /// The translation slot with the click-to-reveal gesture for the live
    /// recognition text (mirrors the per-row source toggle in the history).
    private var liveSlot: some View {
        translationSlot
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                guard !state.sourceTextVisible else { return }
                liveSourceRevealed.toggle()
            })
    }

    /// Newest-on-top layout: the live slot (in-progress or lingering utterance)
    /// at the top with its translation right below, then the finalized history
    /// in newest-first order. No divider between them: live → provisional →
    /// history should read as one stream.
    private var newestOnTopLayout: some View {
        VStack(spacing: 0) {
            if state.sourceTextVisible || liveSourceRevealed || sourceForced {
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
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(10)
            }
            liveSlot
                .padding(.horizontal, 10)
                .padding(.top, state.sourceTextVisible || liveSourceRevealed || sourceForced ? 0 : 10)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(historyUtterances.reversed()) { utterance in
                        historyRow(utterance)
                    }
                }
                .padding(12)
            }
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
            LazyVStack(spacing: 12) {
                ForEach(historyUtterances) { utterance in
                    historyRow(utterance)
                }
                if state.sourceTextVisible || liveSourceRevealed || sourceForced, liveText != " " {
                    Text(liveText)
                        .font(.system(size: max(9, state.sourceFontSize)))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                liveSlot
            }
            .padding(12)
        }
        // Manual scrollTo either fires before long text finishes layout (clipping the
        // last line) or fails to fire when a translation arrives later (the row only
        // grows taller). The anchor approach lets the system keep the bottom pinned as
        // content grows. No .alignment role: it would bottom-align the history even
        // when there are only a few rows.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
                    VStack(spacing: 6) {
                        liveSlots
                    }
                    .padding(10)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(rows.reversed()) { utterance in
                            row(utterance)
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(rows) { utterance in
                        row(utterance)
                    }
                    liveSlots
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }

    /// One live slot per channel with recognition in progress. The leading
    /// spinner marks "speech in progress" (the same "not final yet" sign the
    /// classic panel's pending slots use); the text is this language's
    /// in-progress reading when its recognizer is producing one — main font
    /// size (this is the panel's native reading text), secondary color as the
    /// "still changing" cue. A slot with no text of its own stays as the bare
    /// spinner, so the quiet panel still shows that something is coming.
    @ViewBuilder
    private var liveSlots: some View {
        ForEach(liveEntries, id: \.channel) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PendingSpinner()
                if let text = entry.text {
                    Text(text)
                        .font(.system(size: state.fontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(state.liveLines)
                        .truncationMode(.head)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ utterance: Utterance) -> some View {
        VStack(spacing: 3) {
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
                } else if utterance.finalTranslationFailed {
                    Text(L("translation.failed"))
                        .font(.system(size: max(8, state.fontSize * 0.72)))
                        .foregroundStyle(.tertiary)
                } else {
                    PendingSpinner()
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
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
        .multilineTextAlignment(.center)
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
        VStack(spacing: 3) {
            if sourceVisible {
                Text(utterance.source)
                    .font(.system(size: max(9, sourceFontSize)))
                    .foregroundStyle(utterance.translationSkipped ? .tertiary : .secondary)
                    .selectable(selectable)
            }
            if utterance.translation != nil {
                TranslationText(utterance: utterance, fontSize: fontSize, selectable: selectable)
            } else if let provisional = utterance.provisionalTranslation {
                // Provisional translation carried over at finalize. While the
                // spinner runs, normal text color is right — the spinner itself
                // says "not final yet". Once no final translation is coming
                // (this row failed, or the lane stopped), removing only the
                // spinner would leave the provisional looking exactly like a
                // successful final translation, so dim it and label the state
                // explicitly (a label, not just color, for accessibility).
                let awaitingFinal = showsPending && !utterance.finalTranslationFailed
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if awaitingFinal {
                        PendingSpinner()
                    }
                    Text(provisional)
                        .font(.system(size: fontSize))
                        .foregroundStyle(awaitingFinal ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .selectable(selectable)
                }
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
                PendingSpinner()
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
