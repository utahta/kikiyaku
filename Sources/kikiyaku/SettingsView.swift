import AppKit
import SwiftUI

/// The explanation for one setting, behind a small "?" that shows it while the
/// pointer rests on it. Written out in full under every control, these
/// paragraphs were most of the settings window's height and pushed the
/// controls themselves apart; the text is worth reading once and then never
/// again, which is exactly what a hover reveal is for.
struct HelpTip: View {
    let text: String
    /// The same reveal serves warnings, which differ only in how they look and
    /// in what a screen reader calls them.
    var systemImage = "questionmark.circle"
    var style = AnyShapeStyle(.secondary)
    var accessibilityName = L("settings.help")
    /// Shown while the pointer rests on the icon.
    @State private var hovering = false
    /// Held open by activating the icon — the route for anyone driving the
    /// settings from the keyboard, who has no pointer to rest anywhere.
    @State private var pinned = false

    init(
        _ text: String,
        systemImage: String = "questionmark.circle",
        style: AnyShapeStyle = AnyShapeStyle(.secondary),
        accessibilityName: String = L("settings.help")
    ) {
        self.text = text
        self.systemImage = systemImage
        self.style = style
        self.accessibilityName = accessibilityName
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { hovering || pinned },
            // The popover also closes itself (Escape, a click outside); clear
            // both sources so it cannot come straight back.
            set: { isPresented in
                if !isPresented {
                    hovering = false
                    pinned = false
                }
            }
        )
    }

    var body: some View {
        // A button, not a bare image: the explanations moved in here wholesale,
        // so they have to be reachable with Full Keyboard Access — an Image
        // takes no focus and answers no Return.
        Button {
            pinned.toggle()
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(style)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Presented below the icon, so it never sits under the pointer —
        // covering the icon would end the hover and flicker the popover.
        .popover(isPresented: presented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 340, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel(accessibilityName)
        .accessibilityHint(text)
    }
}

/// A setting's label with its explanation one hover away. The icon rides in
/// the form's label column, so the whole column of them lines up however wide
/// the controls beside them are.
struct HelpLabel: View {
    let title: String
    let help: String

    init(_ title: String, help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            HelpTip(help)
        }
    }
}

struct SettingsView: View {
    /// The session settings live in the selected profile. This screen shows
    /// them and switches between profiles; changing them is the editor's job
    /// (ProfileEditorSheet), so there is exactly one place they are edited
    /// and nothing here to fall out of step with it. What stays in @State
    /// below is the display settings — global, not part of any profile.
    private var store: SessionProfileStore { .shared }
    private var selected: SessionProfile { store.selected }

    @State private var editor: ProfileEditorContext?

    @State private var directoryPath = TranscriptStore.directory.path
    @State private var confidenceThreshold = Preferences.confidenceThreshold
    @State private var fontSize = Preferences.fontSize
    @State private var sourceFontSize = Preferences.sourceFontSize
    @State private var sourceTextVisible = Preferences.sourceTextVisible
    @State private var liveSourceTextVisible = Preferences.liveSourceTextVisible
    @State private var newestOnTop = Preferences.newestOnTop
    @State private var liveLines = Preferences.liveLines
    @State private var claudePath = Preferences.claudePath.isEmpty
        ? (ClaudeBinary.detect() ?? "")
        : Preferences.claudePath
    @State private var resolvedClaudePath: String? = ClaudeBinary.resolve()
    @State private var promptTemplate = Preferences.claudePromptOverride ?? ClaudeSession.defaultPromptTemplate
    @State private var autoStopMinutes = Preferences.autoStopMinutes
    @State private var uiLanguage = Preferences.uiLanguage
    @State private var panelOpacity = Preferences.panelOpacity

    /// Whether the selected mode translates at all — the modes with translation
    /// off leave the whole backend configuration inert, so its rows are not
    /// shown and its remaining controls dim.
    private var translationActive: Bool {
        selected.mode.translates
    }

    /// The settings that define a session — what it recognizes, in which
    /// languages, and what it does with the result — are fixed while one is
    /// running. They could never take effect before the next start anyway, and
    /// changing them now clears the panel to match the new configuration,
    /// which is not something to do underneath a session in progress. The
    /// display settings below stay live, since watching the panel change is
    /// the point of them.
    private var sessionLocked: Bool {
        AppState.shared.phase != .idle
    }

    static func modeLabel(_ mode: SessionMode) -> String {
        switch mode {
        case .translate: L("settings.mode.translate")
        case .bidirectional: L("settings.mode.bidirectional")
        case .transcribe: L("settings.mode.transcribe")
        case .bilingual: L("settings.mode.bilingual")
        }
    }

    static func claudeModelLabel(_ id: String) -> String {
        switch id {
        case "claude-sonnet-5": L("settings.model.sonnet")
        case "claude-opus-5": L("settings.model.opus")
        case "claude-haiku-4-5-20251001": L("settings.model.haiku")
        default: id
        }
    }

    // MARK: - Summary card

    /// One line of the summary card: an icon standing in for a label, then
    /// the value. The icon column is fixed so the values line up.
    private func summaryRow(_ symbol: String, _ value: String) -> some View {
        GridRow {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(value)
        }
    }

    private var modeSymbol: String {
        switch selected.mode {
        case .translate: "arrow.right"
        case .bidirectional: "arrow.left.arrow.right"
        case .transcribe, .bilingual: "text.quote"
        }
    }

    private var audioSourceSymbol: String {
        switch selected.audioSource {
        case "mic": "mic"
        case "both": "mic.and.signal.meter"
        default: "speaker.wave.2"
        }
    }

    /// The short names — the Picker's carry a parenthetical explanation that
    /// helps when choosing and only takes room when summarizing.
    private var audioSourceLabel: String {
        switch selected.audioSource {
        case "mic": L("settings.audioSource.mic.short")
        case "both": L("settings.audioSource.both.short")
        default: L("settings.audioSource.system.short")
        }
    }

    /// "English (en-US)": the language's name and the stored code, without
    /// the region spelled out — the code already carries it, and the Picker's
    /// "English (United States) (en-US)" wrapped the line.
    private func shortLanguageLabel(_ id: String) -> String {
        let language = Locale(identifier: id).language
        let name = language.languageCode.flatMap {
            Preferences.displayLocale.localizedString(forLanguageCode: $0.identifier)
        } ?? id
        return "\(name) (\(id))"
    }

    /// The pair as the mode reads it: an arrow for a direction, a double arrow
    /// for both, a slash where neither language leads. Transcription-only
    /// names just the language it recognizes.
    private var languagesSummary: String {
        let source = shortLanguageLabel(selected.sourceLocaleID)
        let target = shortLanguageLabel(selected.targetLocaleID)
        return switch selected.mode {
        case .transcribe: source
        case .translate: LF("settings.summary.languages.translate", source, target)
        case .bidirectional: LF("settings.summary.languages.pair", source, target)
        case .bilingual: LF("settings.summary.languages.bilingual", source, target)
        }
    }

    /// The backend and — for the one that has it — the provisional translation
    /// switch. The model and the endpoint get lines of their own.
    private var backendSummary: String {
        if selected.backend == "claude" {
            return L("settings.backend.claude.short")
        }
        let provisional = selected.provisionalTranslation
            ? L("settings.summary.provisionalOn")
            : L("settings.summary.provisionalOff")
        return "\(L("settings.backend.openai.short")) · \(provisional)"
    }

    private var modelSummary: String {
        if selected.backend == "claude" {
            return Self.claudeModelLabel(selected.claudeModel)
        }
        return selected.openAIModel.isEmpty ? "—" : selected.openAIModel
    }

    // MARK: - Profile actions

    /// The selected profile's own standing: what it lacks to start with, or
    /// a language it names that the recognizer does not know. Shown beside
    /// the profile control, since Edit… right there is where either gets
    /// fixed. The missing setup comes first — it is what the record button
    /// will refuse on.
    private var selectedProfileProblem: ProfileError? {
        if let problem = selected.setupProblem {
            return problem
        }
        if case .unsupported(let error) = store.switchability(of: store.selectedID) {
            return error
        }
        return nil
    }

    /// Takes `any Error` because a closure handed to SwiftUI loses the typed
    /// throw; nothing but a ProfileError ever arrives.
    private func showProfileError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = L("profiles.error.title")
        alert.informativeText = (error as? ProfileError)?.message ?? error.localizedDescription
        alert.runModal()
    }

    private func deleteProfile() {
        let alert = NSAlert()
        alert.messageText = LF("settings.profiles.deleteTitle", selected.name)
        alert.informativeText = L("settings.profiles.deleteMessage")
        alert.addButton(withTitle: L("settings.profiles.deleteButton"))
        alert.addButton(withTitle: L("settings.cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.delete(store.selectedID)
        } catch {
            showProfileError(error)
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            Form {
                Picker(L("settings.language"), selection: $uiLanguage) {
                    Text(L("settings.language.system")).tag("system")
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
                .onChange(of: uiLanguage) {
                    Preferences.uiLanguage = uiLanguage
                }
                HStack {
                    Text(L("settings.languageRestartCaption"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button(L("settings.relaunch")) {
                        AppDelegate.relaunch()
                    }
                    .controlSize(.small)
                }

                Divider()

                // Say why the profile controls are greyed out, rather than
                // leaving the reader to work out that a session is the reason.
                if sessionLocked {
                    Text(L("settings.sessionLockedCaption"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // A Menu of Buttons rather than a Picker: a Picker's items
                // ignore .disabled on macOS, and an entry that cannot be
                // switched to has to read as unavailable at the moment it is
                // looked at — inside the open menu. An unsupported profile is
                // not one of those — it is offered, so that selecting it and
                // pressing Edit… is how its languages get corrected.
                LabeledContent {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(store.profiles) { profile in
                                Button {
                                    do {
                                        try store.select(profile.id)
                                    } catch {
                                        showProfileError(error)
                                    }
                                } label: {
                                    if profile.id == store.selectedID {
                                        Label(profile.name, systemImage: "checkmark")
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                                .disabled({
                                    if case .blocked = store.switchability(of: profile.id) { return true }
                                    return false
                                }())
                            }
                            Divider()
                            Button(L("settings.profiles.delete")) { deleteProfile() }
                                .disabled(store.profiles.count < 2)
                        } label: {
                            Text(selected.name)
                        }
                        .fixedSize()
                        // Opened from the button's action, so that the key is
                        // read from the Keychain exactly once per press (see
                        // ProfileEditorContext).
                        Button(L("settings.profiles.edit")) { editor = .edit(selected) }
                            .controlSize(.small)
                        Button(L("settings.profiles.new")) { editor = .new() }
                            .controlSize(.small)
                        if let problem = selectedProfileProblem {
                            HelpTip(
                                problem.message,
                                systemImage: "exclamationmark.triangle.fill",
                                style: AnyShapeStyle(.orange),
                                accessibilityName: L("settings.warning"))
                        }
                    }
                } label: { HelpLabel(L("settings.profiles"), help: L("settings.profilesCaption")) }
                .disabled(sessionLocked)

                // What the selected profile holds, as a boxed summary rather
                // than form rows: read-only by design, and looking it. Rows of
                // the form would read as settings that cannot be operated —
                // a different statement — and labels beside values in the
                // same type made the two hard to tell apart. One value per
                // line, each led by an icon in place of a label: the icon
                // says what the line is without having to be read.
                //
                // The card sits in the form's value column, under the control
                // it describes, which keeps the label column intact but caps
                // the width at about 300pt. The lines are cut to fit: the
                // backend and the model get a line each, and the endpoint —
                // the one value long enough to crowd the rest — goes last and
                // small.
                GroupBox {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                        summaryRow(modeSymbol, Self.modeLabel(selected.mode))
                        summaryRow(audioSourceSymbol, audioSourceLabel)
                        summaryRow("globe", languagesSummary)
                        if translationActive {
                            summaryRow("server.rack", backendSummary)
                            summaryRow("cpu", modelSummary)
                            if selected.backend == "openai", !selected.openAIBaseURL.isEmpty {
                                GridRow {
                                    Color.clear.frame(width: 16, height: 1)
                                    Text(selected.openAIBaseURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                // The CLI's location is a fact about this machine, not about
                // a profile, so it stays out of the editor. Shown under the
                // same condition its value is used: a profile that keeps
                // "claude" stored while transcribing only has no use for it.
                if translationActive, selected.backend == "claude" {
                    LabeledContent {
                        HStack {
                            TextField("", text: $claudePath, prompt: Text(L("settings.claudePathPlaceholder")))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .autocorrectionDisabled()
                            Button(L("settings.claudePathDetect")) {
                                claudePath = ClaudeBinary.detect() ?? ""
                            }
                            .controlSize(.small)
                            .disabled(ClaudeBinary.detect() == nil)
                        }
                    } label: { HelpLabel(L("settings.claudePath"), help: L("settings.claudePathCaption")) }
                    .disabled(sessionLocked)
                    .onChange(of: claudePath) {
                        // A value equal to the detection result is not stored ("auto-follow":
                        // it keeps tracking even if the install location changes later).
                        // Only a manually entered different path is stored as an explicit
                        // override.
                        Preferences.claudePath = claudePath == ClaudeBinary.detect() ? "" : claudePath
                        resolvedClaudePath = ClaudeBinary.resolve()
                    }
                    Text(resolvedClaudePath.map { LF("settings.claudePathDetected", $0) } ?? L("settings.claudePathMissing"))
                        .font(.caption)
                        .foregroundStyle(resolvedClaudePath == nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                }

                Divider()

                LabeledContent {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $promptTemplate)
                            .font(.system(size: 11))
                            .frame(height: 100)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        Button(L("settings.resetDefault")) {
                            promptTemplate = ClaudeSession.defaultPromptTemplate
                        }
                        .disabled(promptTemplate == ClaudeSession.defaultPromptTemplate)
                    }
                } label: { HelpLabel(L("settings.systemPrompt"), help: L("settings.promptCaption")) }
                .disabled(!translationActive || sessionLocked)  // the prompt is shared by both backends
                .onChange(of: promptTemplate) {
                    Preferences.claudePromptOverride =
                        promptTemplate == ClaudeSession.defaultPromptTemplate ? nil : promptTemplate
                }

                Divider()

                Toggle(isOn: $newestOnTop) { HelpLabel(L("settings.newestOnTop"), help: L("settings.newestOnTopCaption")) }
                    .onChange(of: newestOnTop) {
                        Preferences.newestOnTop = newestOnTop
                        AppState.shared.newestOnTop = newestOnTop
                    }

                LabeledContent(L("settings.liveLines")) {
                    Stepper(value: $liveLines, in: 1...8) {
                        Text(LF("settings.liveLinesValue", liveLines))
                            .monospacedDigit()
                    }
                    .disabled(!newestOnTop)
                }
                .onChange(of: liveLines) {
                    Preferences.liveLines = liveLines
                    AppState.shared.liveLines = liveLines
                }

                LabeledContent {
                    HStack {
                        Slider(value: $fontSize, in: 10...32, step: 1)
                            .frame(width: 200)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: { HelpLabel(L("settings.fontSize"), help: L("settings.fontSizeCaption")) }
                .onChange(of: fontSize) {
                    Preferences.fontSize = fontSize
                    AppState.shared.fontSize = fontSize
                }

                Toggle(isOn: $liveSourceTextVisible) { HelpLabel(L("settings.liveSourceText"), help: L("settings.liveSourceTextCaption")) }
                    .onChange(of: liveSourceTextVisible) {
                        Preferences.liveSourceTextVisible = liveSourceTextVisible
                        AppState.shared.liveSourceTextVisible = liveSourceTextVisible
                    }
                Toggle(isOn: $sourceTextVisible) { HelpLabel(L("settings.sourceText"), help: L("settings.sourceTextCaption")) }
                    .onChange(of: sourceTextVisible) {
                        Preferences.sourceTextVisible = sourceTextVisible
                        AppState.shared.sourceTextVisible = sourceTextVisible
                    }
                LabeledContent(L("settings.sourceFontSize")) {
                    HStack {
                        Slider(value: $sourceFontSize, in: 10...32, step: 1)
                            .frame(width: 200)
                        Text("\(Int(sourceFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                // The size applies to both source lines, live and history.
                .disabled(!sourceTextVisible && !liveSourceTextVisible)
                .onChange(of: sourceFontSize) {
                    Preferences.sourceFontSize = sourceFontSize
                    AppState.shared.sourceFontSize = sourceFontSize
                }

                LabeledContent {
                    HStack {
                        Slider(value: $panelOpacity, in: 0.3...1.0, step: 0.05)
                            .frame(width: 200)
                        Text("\(Int(panelOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: { HelpLabel(L("settings.opacity"), help: L("settings.opacityCaption")) }
                .onChange(of: panelOpacity) {
                    Preferences.panelOpacity = panelOpacity
                    AppState.shared.panelOpacity = panelOpacity
                }

                Divider()

                LabeledContent {
                    HStack {
                        Slider(value: $confidenceThreshold, in: 0...0.9, step: 0.05)
                            .frame(width: 200)
                        Text(confidenceThreshold == 0 ? L("settings.off") : String(format: "%.2f", confidenceThreshold))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: { HelpLabel(L("settings.threshold"), help: L("settings.thresholdCaption")) }
                .onChange(of: confidenceThreshold) {
                    Preferences.confidenceThreshold = confidenceThreshold
                }
                // "Off" cannot disable the language judgment the bidirectional
                // modes run on, so say which value takes its place instead of
                // letting the slider read Off while something else applies.
                if selected.mode.isBidirectional, confidenceThreshold == 0 {
                    Text(LF("settings.thresholdBidirectionalFloor",
                            String(format: "%.2f", Preferences.defaultConfidenceThreshold)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                LabeledContent {
                    Stepper(value: $autoStopMinutes, in: 0...120, step: 5) {
                        Text(autoStopMinutes == 0 ? L("settings.off") : LF("settings.autoStopValue", autoStopMinutes))
                            .monospacedDigit()
                    }
                } label: { HelpLabel(L("settings.autoStop"), help: L("settings.autoStopCaption")) }
                .onChange(of: autoStopMinutes) {
                    Preferences.autoStopMinutes = autoStopMinutes
                }

                Divider()

                LabeledContent {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(directoryPath)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Button(L("settings.change")) { chooseDirectory() }
                            Button(L("settings.resetDefault")) {
                                TranscriptStore.setDirectory(nil)
                                directoryPath = TranscriptStore.directory.path
                            }
                            .disabled(directoryPath == TranscriptStore.defaultDirectory.path)
                        }
                    }
                } label: { HelpLabel(L("settings.saveDir"), help: L("settings.saveDirCaption")) }
            }
            .padding(20)
            // Wide enough for the profile summary's value column to hold a
            // model name and a language pair without wrapping.
            .frame(width: 560)
        }
        .sheet(item: $editor) { context in
            ProfileEditorSheet(context: context) { editor = nil }
        }
        // The record button asks for the editor from outside this window.
        // Both hooks are needed: .task for a window created by the request,
        // .onChange for the reused one (the window is kept, so .task runs
        // once). Either way the flag goes back down, or the next request
        // would not register as a change.
        .task { openEditorIfRequested() }
        .onChange(of: AppState.shared.pendingProfileEdit) { openEditorIfRequested() }
    }

    private func openEditorIfRequested() {
        guard AppState.shared.pendingProfileEdit else { return }
        AppState.shared.pendingProfileEdit = false
        // A sheet already open keeps its draft; the request is satisfied.
        if editor == nil {
            editor = .edit(selected)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = TranscriptStore.directory
        panel.prompt = L("settings.choosePrompt")
        panel.message = L("settings.chooseMessage")
        if panel.runModal() == .OK, let url = panel.url {
            TranscriptStore.setDirectory(url)
            directoryPath = url.path
        }
    }
}
