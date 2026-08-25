import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var directoryPath = TranscriptStore.directory.path
    @State private var audioSource = Preferences.audioSource
    @State private var sessionMode = Preferences.sessionMode
    @State private var sourceID = Preferences.sourceLocaleID
    @State private var targetID = Preferences.targetLocaleID
    @State private var confidenceThreshold = Preferences.confidenceThreshold
    @State private var fontSize = Preferences.fontSize
    @State private var sourceFontSize = Preferences.sourceFontSize
    @State private var sourceTextVisible = Preferences.sourceTextVisible
    @State private var newestOnTop = Preferences.newestOnTop
    @State private var liveLines = Preferences.liveLines
    /// Whether the selected mode translates at all — the modes with translation
    /// off leave the whole backend configuration inert, so its controls dim.
    private var translationActive: Bool {
        sessionMode.translates
    }
    @State private var backend = Preferences.translationBackend
    @State private var profiles = Preferences.backendProfiles
    @State private var profileEditor: ProfileEditorContext?
    @State private var provisionalEnabled = Preferences.provisionalTranslationEnabled
    @State private var openAIBaseURL = Preferences.openAIBaseURL
    @State private var openAIModel = Preferences.openAIModel
    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false
    @State private var modelFetchError: String?
    /// Only the newest fetch may touch the states above. Bumped by every fetch
    /// and by endpoint changes, so a late response from an old endpoint can
    /// neither install its stale list nor clobber a newer fetch's flags.
    @State private var modelFetchID = 0
    // Keys are stored per endpoint; the field is filled for the displayed URL's
    // endpoint in .task rather than here — a @State initializer runs when the
    // view is constructed (which can be app launch), and touching the keychain
    // then triggers the authorization prompt on every rebuilt dev binary even
    // when the key isn't needed yet.
    @State private var openAIKey = ""
    @State private var claudeModel = Preferences.claudeModel
    @State private var claudePath = Preferences.claudePath.isEmpty
        ? (ClaudeBinary.detect() ?? "")
        : Preferences.claudePath
    @State private var resolvedClaudePath: String? = ClaudeBinary.resolve()
    @State private var promptTemplate = Preferences.claudePromptOverride ?? ClaudeSession.defaultPromptTemplate
    @State private var autoStopMinutes = Preferences.autoStopMinutes
    @State private var uiLanguage = Preferences.uiLanguage
    @State private var panelOpacity = Preferences.panelOpacity
    @State private var sourceOptions: [LanguageOption] = []
    @State private var targetOptions: [LanguageOption] = []
    /// The genuine SpeechTranscriber capability list, captured BEFORE the
    /// display-only rescue entries are appended to sourceOptions (a stored but
    /// unsupported locale gets appended there purely so the Picker can show
    /// it — that is not proof the recognizer supports it).
    @State private var supportedSourceIDs: Set<String> = []

    /// Swapping puts the current target into the recognition slot, so it is
    /// only allowed when that language is a SpeechTranscriber-supported locale
    /// (the target list is broader — translation targets are LLM-arbitrary).
    /// Checked against the raw capability set, NOT sourceOptions: the latter
    /// contains display-only rescue entries for unsupported stored values.
    /// Matching is by option ID; a false negative merely disables the button,
    /// which is the safe direction.
    private var swapPossible: Bool {
        supportedSourceIDs.contains(targetID)
    }

    private var claudeModelOptions: [String] {
        var options = ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001"]
        // Keep the Picker from breaking on an unknown model written directly via defaults.
        if !options.contains(claudeModel) {
            options.append(claudeModel)
        }
        return options
    }

    private func claudeModelLabel(_ id: String) -> String {
        switch id {
        case "claude-sonnet-5": return L("settings.model.sonnet")
        case "claude-opus-5": return L("settings.model.opus")
        case "claude-haiku-4-5-20251001": return L("settings.model.haiku")
        default: return id
        }
    }

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

                Picker(L("settings.audioSource"), selection: $audioSource) {
                    Text(L("settings.audioSource.mic")).tag("mic")
                    Text(L("settings.audioSource.system")).tag("system")
                    Text(L("settings.audioSource.both")).tag("both")
                }
                .onChange(of: audioSource) {
                    Preferences.audioSource = audioSource
                }
                Text(L("settings.audioSourceCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Picker(L("settings.sourceLanguage"), selection: $sourceID) {
                    ForEach(sourceOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .disabled(sourceOptions.isEmpty)
                .onChange(of: sourceID) {
                    Preferences.sourceLocaleID = sourceID
                    AppDelegate.applyConfiguredLayout()
                }
                Picker(L("settings.targetLanguage"), selection: $targetID) {
                    ForEach(targetOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .disabled(targetOptions.isEmpty)
                .onChange(of: targetID) {
                    Preferences.targetLocaleID = targetID
                    AppDelegate.applyConfiguredLayout()
                }
                Button(L("settings.swapLanguages")) {
                    guard swapPossible else { return }
                    let source = sourceID
                    sourceID = targetID
                    targetID = source
                    // The lists are unified now, but a rescue entry (a stored
                    // language the recognizer does not support) can still land
                    // in the language-2 slot; keep the picker from breaking.
                    if !targetOptions.contains(where: { $0.id == targetID }) {
                        targetOptions.append(Preferences.option(id: targetID))
                    }
                }
                .controlSize(.small)
                .disabled(!swapPossible)
                if !swapPossible, !targetOptions.isEmpty {
                    Text(L("settings.swapUnsupportedCaption"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(L("settings.languageCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider()

                Picker(L("settings.mode"), selection: $sessionMode) {
                    Text(L("settings.mode.translate")).tag(SessionMode.translate)
                    Text(L("settings.mode.bidirectional")).tag(SessionMode.bidirectional)
                    Text(L("settings.mode.transcribe")).tag(SessionMode.transcribe)
                    Text(L("settings.mode.bilingual")).tag(SessionMode.bilingual)
                }
                .onChange(of: sessionMode) {
                    Preferences.sessionMode = sessionMode
                    AppDelegate.applyConfiguredLayout()
                }
                Text(L("settings.modeCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                LabeledContent(L("settings.profiles")) {
                    HStack {
                        if !profiles.isEmpty {
                            Menu(L("settings.profiles.apply")) {
                                ForEach(profiles) { profile in
                                    Button(profile.name) { apply(profile) }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                            Menu(L("settings.profiles.edit")) {
                                ForEach(profiles) { profile in
                                    Button(profile.name) {
                                        profileEditor = ProfileEditorContext(
                                            originalName: profile.name, profile: profile)
                                    }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                        Button(L("settings.profiles.add")) {
                            // Prefill with the current settings — the common case
                            // is "save what I have working right now".
                            profileEditor = ProfileEditorContext(
                                originalName: nil,
                                profile: BackendProfile(
                                    name: "",
                                    backend: backend,
                                    openAIBaseURL: openAIBaseURL,
                                    openAIModel: openAIModel,
                                    claudeModel: claudeModel
                                )
                            )
                        }
                        .controlSize(.small)
                    }
                }
                .disabled(!translationActive)
                Text(L("settings.profilesCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)


                Picker(L("settings.backend"), selection: $backend) {
                    Text(L("settings.backend.claude")).tag("claude")
                    Text(L("settings.backend.openai")).tag("openai")
                }
                .disabled(!translationActive)
                .onChange(of: backend) {
                    Preferences.translationBackend = backend
                }

                if backend == "openai" {
                    LabeledContent(L("settings.openaiBaseURL")) {
                        TextField("", text: $openAIBaseURL, prompt: Text(verbatim: "https://api.openai.com"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .autocorrectionDisabled()
                    }
                    .disabled(!translationActive)
                    .onChange(of: openAIBaseURL) {
                        Preferences.openAIBaseURL = openAIBaseURL
                        // Keys are stored per host, so when the endpoint changes,
                        // switch the field to the key saved for that host. The
                        // fetched model list belongs to the old server; drop it.
                        openAIKey = OpenAICompatSession.apiKey(forBaseURL: openAIBaseURL) ?? ""
                        modelFetchID += 1
                        fetchedModels = []
                        modelFetchError = nil
                        fetchingModels = false
                    }
                    LabeledContent(L("settings.openaiModel")) {
                        HStack {
                            TextField("", text: $openAIModel, prompt: Text(verbatim: "gpt-5.5"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)
                                .autocorrectionDisabled()
                            if fetchingModels {
                                ProgressView()
                                    .controlSize(.small)
                            } else if fetchedModels.isEmpty {
                                Button(L("settings.openaiModelsFetch")) { fetchModels() }
                                    .controlSize(.small)
                            } else {
                                Menu(L("settings.openaiModelsPick")) {
                                    ForEach(fetchedModels, id: \.self) { id in
                                        Button(id) { openAIModel = id }
                                    }
                                    Divider()
                                    Button(L("settings.openaiModelsRefresh")) { fetchModels() }
                                }
                                .controlSize(.small)
                                .fixedSize()
                            }
                        }
                    }
                    .disabled(!translationActive)
                    .onChange(of: openAIModel) {
                        Preferences.openAIModel = openAIModel
                    }
                    if let modelFetchError {
                        Text(LF("settings.openaiModelsError", modelFetchError))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent(L("settings.openaiKey")) {
                        SecureField("", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    .disabled(!translationActive)
                    .onChange(of: openAIKey) {
                        OpenAICompatSession.setAPIKey(openAIKey, forBaseURL: openAIBaseURL)
                        // The model list depends on the credentials too (plans
                        // and projects expose different models); invalidate any
                        // fetched or in-flight list the same way a URL change does.
                        modelFetchID += 1
                        fetchedModels = []
                        modelFetchError = nil
                        fetchingModels = false
                    }
                    Text(L("settings.openaiCaption"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Toggle(L("settings.provisional"), isOn: $provisionalEnabled)
                        .disabled(!translationActive)
                        .onChange(of: provisionalEnabled) {
                            Preferences.provisionalTranslationEnabled = provisionalEnabled
                        }
                    Text(L("settings.provisionalCaption"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if backend == "claude" {
                    LabeledContent(L("settings.claudePath")) {
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
                    }
                    .disabled(!translationActive)
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
                    Text(L("settings.claudePathCaption"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Picker(L("settings.claudeModel"), selection: $claudeModel) {
                        ForEach(claudeModelOptions, id: \.self) { id in
                            Text(claudeModelLabel(id)).tag(id)
                        }
                    }
                    .disabled(!translationActive)
                    .onChange(of: claudeModel) {
                        Preferences.claudeModel = claudeModel
                    }
                    Text(L("settings.modelCaption"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                LabeledContent(L("settings.systemPrompt")) {
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
                }
                .disabled(!translationActive)  // the prompt is shared by both backends
                .onChange(of: promptTemplate) {
                    Preferences.claudePromptOverride =
                        promptTemplate == ClaudeSession.defaultPromptTemplate ? nil : promptTemplate
                }
                Text(L("settings.promptCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider()

                Toggle(L("settings.newestOnTop"), isOn: $newestOnTop)
                    .onChange(of: newestOnTop) {
                        Preferences.newestOnTop = newestOnTop
                        AppState.shared.newestOnTop = newestOnTop
                    }
                Text(L("settings.newestOnTopCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

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

                LabeledContent(L("settings.fontSize")) {
                    HStack {
                        Slider(value: $fontSize, in: 10...32, step: 1)
                            .frame(width: 200)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: fontSize) {
                    Preferences.fontSize = fontSize
                    AppState.shared.fontSize = fontSize
                }
                Text(L("settings.fontSizeCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle(L("settings.sourceText"), isOn: $sourceTextVisible)
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
                .disabled(!sourceTextVisible)
                .onChange(of: sourceFontSize) {
                    Preferences.sourceFontSize = sourceFontSize
                    AppState.shared.sourceFontSize = sourceFontSize
                }
                Text(L("settings.sourceTextCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                LabeledContent(L("settings.opacity")) {
                    HStack {
                        Slider(value: $panelOpacity, in: 0.3...1.0, step: 0.05)
                            .frame(width: 200)
                        Text("\(Int(panelOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: panelOpacity) {
                    Preferences.panelOpacity = panelOpacity
                    AppState.shared.panelOpacity = panelOpacity
                }
                Text(L("settings.opacityCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider()

                LabeledContent(L("settings.threshold")) {
                    HStack {
                        Slider(value: $confidenceThreshold, in: 0...0.9, step: 0.05)
                            .frame(width: 200)
                        Text(confidenceThreshold == 0 ? L("settings.off") : String(format: "%.2f", confidenceThreshold))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: confidenceThreshold) {
                    Preferences.confidenceThreshold = confidenceThreshold
                }
                // "Off" cannot disable the language judgment the bidirectional
                // modes run on, so say which value takes its place instead of
                // letting the slider read Off while something else applies.
                if sessionMode.isBidirectional, confidenceThreshold == 0 {
                    Text(LF("settings.thresholdBidirectionalFloor",
                            String(format: "%.2f", Preferences.defaultConfidenceThreshold)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L("settings.thresholdCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider()

                LabeledContent(L("settings.autoStop")) {
                    Stepper(value: $autoStopMinutes, in: 0...120, step: 5) {
                        Text(autoStopMinutes == 0 ? L("settings.off") : LF("settings.autoStopValue", autoStopMinutes))
                            .monospacedDigit()
                    }
                }
                .onChange(of: autoStopMinutes) {
                    Preferences.autoStopMinutes = autoStopMinutes
                }
                Text(L("settings.autoStopCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider()

                LabeledContent(L("settings.saveDir")) {
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
                }
                Text(L("settings.saveDirCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(width: 480)
        }
        .task {
            // Read the stored API key only once the settings actually appear
            // (see the openAIKey declaration). The write-back through onChange
            // re-saves the identical value, which is harmless (same pattern as
            // the endpoint-change reload).
            openAIKey = OpenAICompatSession.apiKey(forBaseURL: Preferences.openAIBaseURL) ?? ""
            // Both pickers share the one unified candidate list (every
            // SpeechTranscriber locale); only the rescue entries differ.
            let options = await Preferences.languageOptions()
            var sources = options
            var targets = options
            // Capture the genuine capability list before the display-only
            // rescue entries below pollute it (the swap guard depends on it).
            supportedSourceIDs = Set(options.map(\.id))
            // If the stored value is missing from the candidates (written directly
            // via defaults, or a target saved back when the list was still
            // Translation-framework-based), add the value itself so the Picker
            // does not break.
            if !sources.contains(where: { $0.id == sourceID }) {
                sources.append(Preferences.option(id: sourceID))
            }
            if !targets.contains(where: { $0.id == targetID }) {
                targets.append(Preferences.option(id: targetID))
            }
            sourceOptions = sources
            targetOptions = targets
        }
        .sheet(item: $profileEditor) { context in
            ProfileEditorSheet(
                context: context,
                onSave: { updated in
                    profiles.removeAll { $0.name == context.originalName || $0.name == updated.name }
                    profiles.append(updated)
                    Preferences.backendProfiles = profiles
                    // The editor may have just rewritten the Keychain key for
                    // the endpoint this screen is currently displaying. Resync,
                    // or the stale field value would be sent by "fetch models"
                    // and — worse — written back over the freshly saved key by
                    // its own onChange on the next edit.
                    if updated.backend == "openai",
                       OpenAICompatSession.keychainOriginKey(forBaseURL: updated.openAIBaseURL)
                           == OpenAICompatSession.keychainOriginKey(forBaseURL: openAIBaseURL) {
                        openAIKey = OpenAICompatSession.apiKey(forBaseURL: openAIBaseURL) ?? ""
                        modelFetchID += 1
                        fetchedModels = []
                        modelFetchError = nil
                        fetchingModels = false
                    }
                    profileEditor = nil
                },
                onDelete: context.originalName == nil ? nil : {
                    profiles.removeAll { $0.name == context.originalName }
                    Preferences.backendProfiles = profiles
                    profileEditor = nil
                },
                onCancel: { profileEditor = nil }
            )
        }
    }

    /// Applies a saved profile. Persistence and side effects run explicitly
    /// here — the onChange handlers on the backend-specific controls cannot be
    /// relied on: when the profile switches the backend, those controls are
    /// not in the view hierarchy yet, never observe the change, and would
    /// leave Preferences stale and the key field holding the previous
    /// endpoint's credential. (When the controls do exist, their onChange
    /// re-runs the same work — idempotent.)
    private func apply(_ profile: BackendProfile) {
        backend = profile.backend
        openAIBaseURL = profile.openAIBaseURL
        openAIModel = profile.openAIModel
        claudeModel = profile.claudeModel

        Preferences.translationBackend = profile.backend
        Preferences.openAIBaseURL = profile.openAIBaseURL
        Preferences.openAIModel = profile.openAIModel
        Preferences.claudeModel = profile.claudeModel
        openAIKey = OpenAICompatSession.apiKey(forBaseURL: profile.openAIBaseURL) ?? ""
        modelFetchID += 1
        fetchedModels = []
        modelFetchError = nil
        fetchingModels = false
    }

    private func fetchModels() {
        modelFetchID += 1
        let requestID = modelFetchID
        fetchingModels = true
        modelFetchError = nil
        let baseURL = openAIBaseURL
        let key = openAIKey.isEmpty ? OpenAICompatSession.apiKey(forBaseURL: baseURL) : openAIKey
        Task { @MainActor in
            do {
                let models = try await OpenAICompatSession.listModels(baseURL: baseURL, apiKey: key)
                // Only the newest request may touch the state: a stale response
                // (endpoint changed, or a newer fetch started) must neither
                // install its list nor reset the newer fetch's loading flag.
                guard requestID == modelFetchID else { return }
                fetchedModels = models
            } catch {
                guard requestID == modelFetchID else { return }
                modelFetchError = String(describing: error)
            }
            fetchingModels = false
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

/// Sheet-editing context: which profile is being edited (nil originalName =
/// adding a new one) and the draft it starts from.
struct ProfileEditorContext: Identifiable {
    let originalName: String?
    var profile: BackendProfile
    var id: String { originalName ?? "__new__" }
}

/// Modal editor for one backend profile. Owns its own draft state so nothing
/// touches the saved profiles (or the live settings) until 保存.
private struct ProfileEditorSheet: View {
    @State private var draft: BackendProfile
    private let isNew: Bool
    private let onSave: (BackendProfile) -> Void
    private let onDelete: (() -> Void)?
    private let onCancel: () -> Void

    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false
    @State private var modelFetchError: String?
    /// Only the newest fetch may touch the states above (same request-ID
    /// pattern as the main settings view): bumped by every fetch and by
    /// endpoint edits, so a late response can neither install a stale list
    /// nor strand the loading spinner.
    @State private var modelFetchID = 0
    // Convenience field only: the key is written to the Keychain for the
    // profile's endpoint on save, never stored inside the profile record
    // (profiles live in UserDefaults, which is plain text).
    @State private var apiKey = ""

    init(
        context: ProfileEditorContext,
        onSave: @escaping (BackendProfile) -> Void,
        onDelete: (() -> Void)?,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: context.profile)
        self.isNew = context.originalName == nil
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("settings.profiles.addTitle") : L("settings.profiles.editTitle"))
                .font(.headline)

            LabeledContent(L("settings.profiles.name")) {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            Picker(L("settings.backend"), selection: $draft.backend) {
                Text(L("settings.backend.claude")).tag("claude")
                Text(L("settings.backend.openai")).tag("openai")
            }
            if draft.backend == "openai" {
                LabeledContent(L("settings.openaiBaseURL")) {
                    TextField("", text: $draft.openAIBaseURL, prompt: Text(verbatim: "https://api.openai.com"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .autocorrectionDisabled()
                }
                LabeledContent(L("settings.openaiModel")) {
                    HStack {
                        TextField("", text: $draft.openAIModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .autocorrectionDisabled()
                        if fetchingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else if fetchedModels.isEmpty {
                            Button(L("settings.openaiModelsFetch")) { fetchModels() }
                                .controlSize(.small)
                        } else {
                            Menu(L("settings.openaiModelsPick")) {
                                ForEach(fetchedModels, id: \.self) { id in
                                    Button(id) { draft.openAIModel = id }
                                }
                                Divider()
                                Button(L("settings.openaiModelsRefresh")) { fetchModels() }
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                }
                if let modelFetchError {
                    Text(LF("settings.openaiModelsError", modelFetchError))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent(L("settings.openaiKey")) {
                    SecureField("", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Text(L("settings.profiles.keyCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                LabeledContent(L("settings.claudeModel")) {
                    TextField("", text: $draft.claudeModel, prompt: Text(verbatim: "claude-sonnet-5"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .autocorrectionDisabled()
                }
            }

            HStack {
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Text(L("settings.profiles.delete"))
                    }
                }
                Spacer()
                Button(L("settings.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L("settings.profiles.save")) {
                    var profile = draft
                    profile.name = profile.name.trimmingCharacters(in: .whitespaces)
                    if profile.backend == "openai" {
                        OpenAICompatSession.setAPIKey(apiKey, forBaseURL: profile.openAIBaseURL)
                    }
                    onSave(profile)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            apiKey = OpenAICompatSession.apiKey(forBaseURL: draft.openAIBaseURL) ?? ""
        }
        .onChange(of: draft.openAIBaseURL) {
            // Keys are per endpoint: editing the URL switches the field to the
            // key stored for the new endpoint. The fetched model list belongs
            // to the old endpoint — invalidate it (and any in-flight fetch)
            // so the fetch button comes back and a late response is dropped.
            apiKey = OpenAICompatSession.apiKey(forBaseURL: draft.openAIBaseURL) ?? ""
            modelFetchID += 1
            fetchedModels = []
            modelFetchError = nil
            fetchingModels = false
        }
        .onChange(of: apiKey) {
            // The model list depends on the credential as much as the endpoint
            // (accounts/projects expose different models): invalidate any
            // fetched or in-flight list when the key changes.
            modelFetchID += 1
            fetchedModels = []
            modelFetchError = nil
            fetchingModels = false
        }
    }

    private func fetchModels() {
        modelFetchID += 1
        let requestID = modelFetchID
        fetchingModels = true
        modelFetchError = nil
        let baseURL = draft.openAIBaseURL
        // Use the key as currently typed in the editor — the Keychain copy is
        // only written on save, so reading it back here would fetch with a
        // missing or outdated credential for a new endpoint or a changed key.
        let key = apiKey
        Task { @MainActor in
            do {
                let models = try await OpenAICompatSession.listModels(baseURL: baseURL, apiKey: key)
                guard requestID == modelFetchID else { return }
                fetchedModels = models
            } catch {
                guard requestID == modelFetchID else { return }
                modelFetchError = String(describing: error)
            }
            fetchingModels = false
        }
    }
}
