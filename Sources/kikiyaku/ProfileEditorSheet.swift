import AppKit
import SwiftUI

/// What the editor was opened for, decided at the moment the button was
/// pressed. Carries the initial key so that reading the Keychain happens once,
/// there: the sheet's own initializer runs again whenever the settings screen
/// re-renders, and a read placed in it would run with it.
struct ProfileEditorContext: Identifiable {
    enum Purpose {
        case new
        case edit
    }

    let purpose: Purpose
    let profile: SessionProfile
    let initialAPIKey: String
    var id: UUID { profile.id }

    /// A blank profile has no endpoint, so there is no key to read — the
    /// Keychain is not consulted until an endpoint is entered or a preset
    /// supplies one.
    static func new() -> ProfileEditorContext {
        ProfileEditorContext(purpose: .new, profile: .blank(), initialAPIKey: "")
    }

    static func edit(_ profile: SessionProfile) -> ProfileEditorContext {
        ProfileEditorContext(
            purpose: .edit,
            profile: profile,
            initialAPIKey: OpenAICompatSession.apiKey(forBaseURL: profile.openAIBaseURL) ?? "")
    }
}

/// A common backend setup, as a fill-in for the editor's backend fields. A
/// preset is applied and then forgotten: the draft does not remember which
/// one it came from, so there is nothing to keep consistent once the URL is
/// edited by hand.
enum BackendPreset: CaseIterable, Identifiable {
    case openAI
    case lmStudio
    case ollama
    case claudeCLI

    var id: Self { self }

    var label: String {
        switch self {
        case .openAI: "OpenAI"
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .claudeCLI: "Claude CLI"
        }
    }

    /// Overwrites the backend, endpoint and model; leaves the name, mode,
    /// languages and audio input alone. The local servers get an empty model:
    /// which models are installed differs from machine to machine, and a
    /// guessed name would be saved as a model that does not exist.
    func apply(to draft: inout SessionProfile) {
        switch self {
        case .openAI:
            draft.backend = "openai"
            draft.openAIBaseURL = "https://api.openai.com"
            draft.openAIModel = "gpt-5.6-terra"
        case .lmStudio:
            draft.backend = "openai"
            draft.openAIBaseURL = "http://localhost:1234"
            draft.openAIModel = ""
        case .ollama:
            draft.backend = "openai"
            draft.openAIBaseURL = "http://localhost:11434"
            draft.openAIModel = ""
        case .claudeCLI:
            draft.backend = "claude"
            draft.claudeModel = "claude-sonnet-5"
        }
    }
}

/// The one place a profile is edited. Works on a draft and touches nothing —
/// not the store, not the Keychain — until Save, which validates the draft,
/// hands it to the store, and only then writes the key. Cancel discards the
/// draft and leaves no trace.
///
/// The sheet is modal to the settings window alone: the menu bar can still
/// switch profiles and the panel can still start a session underneath it.
/// Both are watched here (the Save button goes dark with a caption) and
/// checked again by the store, which refuses rather than ignores.
struct ProfileEditorSheet: View {
    private let purpose: ProfileEditorContext.Purpose
    private let dismiss: () -> Void

    @State private var draft: SessionProfile
    // A convenience field only: written to the Keychain for the draft's
    // endpoint on a successful save, never stored inside the profile record.
    @State private var apiKey: String

    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false
    @State private var modelFetchError: String?
    /// Only the newest fetch may touch the states above. Bumped by every fetch
    /// and by endpoint and key changes, so a late response from an old
    /// endpoint can neither install its stale list nor clobber a newer
    /// fetch's flags.
    @State private var modelFetchID = 0

    /// Language-1 candidates: the recognizer's locales.
    @State private var recognizedSourceOptions: [LanguageOption] = []
    /// Language-2 candidates for the modes that recognize it.
    @State private var recognizedTargetOptions: [LanguageOption] = []
    /// Language-2 candidates for one-direction translation, where the language
    /// is only translated into and can be anything the LLM knows.
    @State private var broadTargetOptions: [LanguageOption] = []
    /// The genuine SpeechTranscriber capability list, as distinct from
    /// sourceOptions with its display-only rescue entry (a stored but
    /// unsupported locale is appended there purely so the Picker can show it —
    /// that is not proof the recognizer supports it).
    @State private var supportedSourceIDs: Set<String> = []
    /// Whether supportedSourceIDs has been filled in yet. Reading the empty
    /// set as "the recognizer supports nothing" would greet the sheet with an
    /// orange warning and two greyed-out modes for as long as the async lookup
    /// takes — a claim about the configuration made before anything is known
    /// about it.
    @State private var capabilitiesLoaded = false

    private var store: SessionProfileStore { .shared }

    init(context: ProfileEditorContext, dismiss: @escaping () -> Void) {
        purpose = context.purpose
        self.dismiss = dismiss
        _draft = State(initialValue: context.profile)
        _apiKey = State(initialValue: context.initialAPIKey)
    }

    // MARK: - Derived state

    private var isNew: Bool { purpose == .new }

    private var sessionRunning: Bool { AppState.shared.phase != .idle }

    /// Editing a profile that has since stopped being the selected one — the
    /// menu bar switched away while this sheet was open. The store would
    /// refuse the save; say so before the button is pressed.
    private var editingUnselected: Bool {
        !isNew && store.selectedID != draft.id
    }

    private var translationActive: Bool { draft.mode.translates }

    /// If the stored value is missing from the candidates (written directly
    /// via defaults, or saved back when the list was still Translation-
    /// framework-based), add the value itself so the Picker does not break.
    private var sourceOptions: [LanguageOption] {
        guard !recognizedSourceOptions.isEmpty,
              !recognizedSourceOptions.contains(where: { $0.id == draft.sourceLocaleID }) else {
            return recognizedSourceOptions
        }
        return recognizedSourceOptions + [Preferences.option(id: draft.sourceLocaleID)]
    }

    /// The capability set is keyed by BCP-47, but a stored ID need not be:
    /// `defaults write` and older settings leave underscored forms like en_US
    /// behind. Engine.start canonicalizes before it checks, so comparing the
    /// raw string here would have the editor refuse a language the session
    /// would have run.
    private var canonicalTargetID: String {
        Locale(identifier: draft.targetLocaleID).identifier(.bcp47)
    }

    private func recognizable(_ option: LanguageOption) -> Bool {
        supportedSourceIDs.contains(Locale(identifier: option.id).identifier(.bcp47))
    }

    /// Swapping puts the current target into the recognition slot, so it is
    /// only allowed when that language is a SpeechTranscriber-supported locale
    /// (the target list is broader — translation targets are LLM-arbitrary).
    private var swapPossible: Bool {
        capabilitiesLoaded && supportedSourceIDs.contains(canonicalTargetID)
    }

    /// The modes that recognize language 2 offer the recognizer's locales and
    /// nothing else; the modes that only translate into it (or, for
    /// transcription-only, merely hold the value) offer the broad list. A
    /// stored value outside the chosen list is appended here rather than kept
    /// in the lists themselves — the difference between showing the current
    /// selection and offering it.
    private var targetOptions: [LanguageOption] {
        let base = draft.mode.isBidirectional ? recognizedTargetOptions : broadTargetOptions
        guard !base.contains(where: { $0.id == draft.targetLocaleID }) else { return base }
        return base + [Preferences.option(id: draft.targetLocaleID)]
    }

    /// The modes that recognize language 2 cannot run with a target the
    /// recognizer does not support, so they are not offered while one is
    /// selected. Before the capability list arrives nothing is blocked.
    private var pairModesAvailable: Bool {
        !capabilitiesLoaded || supportedSourceIDs.contains(canonicalTargetID)
    }

    private var targetLabel: String {
        targetOptions.first { $0.id == draft.targetLocaleID }?.label ?? draft.targetLocaleID
    }

    private func modeAvailable(_ mode: SessionMode) -> Bool {
        pairModesAvailable || !mode.isBidirectional
    }

    private var sourceLanguageLabel: String {
        switch draft.mode {
        case .translate: L("settings.language.source.translate")
        case .transcribe: L("settings.language.source.transcribe")
        case .bidirectional, .bilingual: L("settings.language.source.pair")
        }
    }

    private var targetLanguageLabel: String {
        switch draft.mode {
        case .translate, .transcribe: L("settings.language.target.translate")
        case .bidirectional, .bilingual: L("settings.language.target.pair")
        }
    }

    private var languageCaption: String {
        switch draft.mode {
        case .translate: L("settings.languageCaption.translate")
        case .transcribe: L("settings.languageCaption.transcribe")
        case .bidirectional, .bilingual: L("settings.languageCaption.pair")
        }
    }

    private var targetLanguageCaption: String {
        switch draft.mode {
        case .translate: L("settings.languageCaption.target")
        case .transcribe: L("settings.languageCaption.targetUnused")
        case .bidirectional, .bilingual: L("settings.languageCaption.pair")
        }
    }

    private var claudeModelOptions: [String] {
        var options = ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001"]
        // Keep the Picker from breaking on an unknown model written directly via defaults.
        if !options.contains(draft.claudeModel) {
            options.append(draft.claudeModel)
        }
        return options
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? L("settings.profiles.newTitle") : L("settings.profiles.editTitle"))
                .font(.headline)
                .padding(.bottom, 12)

            Form {
                LabeledContent(L("settings.profiles.name")) {
                    TextField("", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                Divider()

                sessionSection

                Divider()

                backendSection
            }

            if sessionRunning {
                Text(L("settings.sessionLockedCaption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else if editingUnselected {
                Text(L("settings.profiles.notSelectedCaption"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button(L("settings.cancel"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L("settings.profiles.addButton") : L("settings.profiles.save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sessionRunning || editingUnselected)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 480)
        .task {
            // Language 1, and language 2 in the modes that recognize it, come
            // from the recognizer's locales; one-direction translation gets the
            // broad list, which starts with those same locales.
            let options = await Preferences.languageOptions()
            supportedSourceIDs = Set(options.map(\.id))
            recognizedSourceOptions = options
            recognizedTargetOptions = options
            broadTargetOptions = await Preferences.translationTargetOptions()
            capabilitiesLoaded = true
        }
        // On the whole sheet, not on the URL field: a preset that also
        // changes the backend brings the field into the hierarchy in the same
        // update, and a modifier on a view that was not there when the value
        // changed never fires. Keys are stored per host, so when the endpoint
        // changes, switch the field to the key saved for that host. The
        // fetched model list belongs to the old server; drop it.
        .onChange(of: draft.openAIBaseURL) {
            apiKey = OpenAICompatSession.apiKey(forBaseURL: draft.openAIBaseURL) ?? ""
            invalidateModelList()
        }
        .onChange(of: apiKey) {
            // The model list depends on the credentials too (plans and
            // projects expose different models); invalidate any fetched or
            // in-flight list the same way a URL change does.
            invalidateModelList()
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        // A Menu of Buttons rather than a Picker: a Picker's items ignore
        // .disabled on macOS, and a mode that cannot run has to read as
        // unavailable at the moment it is looked at — inside the open menu —
        // not as an entry that quietly does nothing.
        LabeledContent {
            HStack(spacing: 6) {
                Menu {
                    ForEach(SessionMode.allCases) { mode in
                        Button {
                            if modeAvailable(mode) { draft.mode = mode }
                        } label: {
                            if mode == draft.mode {
                                Label(SettingsView.modeLabel(mode), systemImage: "checkmark")
                            } else {
                                Text(SettingsView.modeLabel(mode))
                            }
                        }
                        .disabled(!modeAvailable(mode))
                    }
                } label: {
                    Text(SettingsView.modeLabel(draft.mode))
                }
                .fixedSize()
                // Why two of the entries are greyed out, next to the control
                // they are greyed out in.
                if !pairModesAvailable, !targetOptions.isEmpty {
                    HelpTip(
                        LF("settings.modePairUnavailableCaption", targetLabel),
                        systemImage: "exclamationmark.triangle.fill",
                        style: AnyShapeStyle(.orange),
                        accessibilityName: L("settings.warning"))
                }
            }
        } label: { HelpLabel(L("settings.mode"), help: L("settings.modeCaption")) }

        Picker(selection: $draft.audioSource) {
            Text(L("settings.audioSource.mic")).tag("mic")
            Text(L("settings.audioSource.system")).tag("system")
            Text(L("settings.audioSource.both")).tag("both")
        } label: { HelpLabel(L("settings.audioSource"), help: L("settings.audioSourceCaption")) }

        Picker(selection: $draft.sourceLocaleID) {
            ForEach(sourceOptions) { option in
                Text(option.label).tag(option.id)
            }
        } label: { HelpLabel(sourceLanguageLabel, help: languageCaption) }
        .disabled(sourceOptions.isEmpty)

        // Transcription-only recognizes one language, so the second slot has
        // no part to play — unless the stored value is the reason two other
        // modes are greyed out, in which case hiding the one control that
        // could release them would leave the warning asking for a change the
        // reader has no way to make.
        if draft.mode != .transcribe || !pairModesAvailable {
            Picker(selection: $draft.targetLocaleID) {
                // Split so that "the recognizer knows this one too" and "the
                // model is on its own here" are visible in the list rather
                // than only in the help text.
                if draft.mode == .translate {
                    Section(L("settings.language.target.recognizedSection")) {
                        ForEach(targetOptions.filter { recognizable($0) }) {
                            Text($0.label).tag($0.id)
                        }
                    }
                    Section(L("settings.language.target.translationOnlySection")) {
                        ForEach(targetOptions.filter { !recognizable($0) }) {
                            Text($0.label).tag($0.id)
                        }
                    }
                } else {
                    ForEach(targetOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            } label: {
                HelpLabel(targetLanguageLabel, help: targetLanguageCaption)
            }
            .disabled(targetOptions.isEmpty)
            // Bilingual transcription treats the two languages identically —
            // both recognized, neither translated — so an exchange between
            // them answers no question the reader would think to ask.
            if draft.mode != .bilingual {
                Button(L("settings.swapLanguages")) {
                    guard swapPossible else { return }
                    // The canonical form, not the stored string: the swap is
                    // allowed on the strength of the canonical ID matching a
                    // recognizer locale, so that is the value the recognition
                    // slot has to receive. Moving en_US across as it stands
                    // would match nothing in the source list and leave the
                    // Picker blank.
                    let promoted = canonicalTargetID
                    draft.targetLocaleID = draft.sourceLocaleID
                    draft.sourceLocaleID = promoted
                }
                .controlSize(.small)
                .disabled(!swapPossible)
                if capabilitiesLoaded, !swapPossible, !targetOptions.isEmpty {
                    Text(L("settings.swapUnsupportedCaption"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var backendSection: some View {
        LabeledContent {
            Menu(L("settings.presets.pick")) {
                ForEach(BackendPreset.allCases) { preset in
                    Button(preset.label) { preset.apply(to: &draft) }
                }
            }
            .controlSize(.small)
            .fixedSize()
        } label: { HelpLabel(L("settings.presets"), help: L("settings.presetsCaption")) }
        .disabled(!translationActive)

        Picker(L("settings.backend"), selection: $draft.backend) {
            Text(L("settings.backend.claude")).tag("claude")
            Text(L("settings.backend.openai")).tag("openai")
        }
        .disabled(!translationActive)

        if draft.backend == "openai" {
            LabeledContent {
                TextField("", text: $draft.openAIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .autocorrectionDisabled()
            } label: { HelpLabel(L("settings.openaiBaseURL"), help: L("settings.openaiCaption")) }
            .disabled(!translationActive)
            LabeledContent(L("settings.openaiModel")) {
                HStack {
                    TextField("", text: $draft.openAIModel)
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
            .disabled(!translationActive)
            if let modelFetchError {
                Text(LF("settings.openaiModelsError", modelFetchError))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent(L("settings.openaiKey")) {
                SecureField("", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .disabled(!translationActive)

            Toggle(isOn: $draft.provisionalTranslation) {
                HelpLabel(L("settings.provisional"), help: L("settings.provisionalCaption"))
            }
            .disabled(!translationActive)
        }

        if draft.backend == "claude" {
            Picker(selection: $draft.claudeModel) {
                ForEach(claudeModelOptions, id: \.self) { id in
                    Text(SettingsView.claudeModelLabel(id)).tag(id)
                }
            } label: { HelpLabel(L("settings.claudeModel"), help: L("settings.modelCaption")) }
            .disabled(!translationActive)
        }
    }

    // MARK: - Actions

    private func invalidateModelList() {
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
        let baseURL = draft.openAIBaseURL
        // The key as currently typed — the Keychain copy is only written on
        // save, so reading it back here would fetch with a missing or outdated
        // credential for a new endpoint or a changed key.
        let key = apiKey.isEmpty ? nil : apiKey
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

    /// Normalize, validate, hand to the store, and only then write the key:
    /// the store can refuse (a session started, the selection moved), and a
    /// key written before that refusal would survive the Cancel that follows.
    private func save() {
        var profile = draft
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.openAIModel = profile.openAIModel.trimmingCharacters(in: .whitespaces)
        profile.openAIBaseURL = profile.openAIBaseURL.trimmingCharacters(in: .whitespaces)

        if let error = validate(profile) {
            showError(error)
            return
        }
        do {
            switch purpose {
            case .new: try store.add(profile)
            case .edit: try store.update(profile)
            }
        } catch {
            showError(error)
            return
        }
        if profile.backend == "openai" {
            OpenAICompatSession.setAPIKey(apiKey, forBaseURL: profile.openAIBaseURL)
        }
        dismiss()
    }

    /// The first thing wrong with the draft, in the order a reader would fix
    /// them. The store repeats the name checks; the language and backend
    /// checks are this sheet's alone.
    private func validate(_ profile: SessionProfile) -> ProfileError? {
        if profile.name.isEmpty { return .emptyName }
        if store.profiles.contains(where: { $0.id != profile.id && $0.name == profile.name }) {
            return .duplicateName
        }
        // The store's list, not this sheet's: the store's is what the menu bar
        // and the settings screen judge profiles by, and a profile saved past
        // it would come back marked unsupported.
        if store.capabilitiesLoaded,
           let missing = profile.recognizedLocaleIDs.first(where: { !store.supportedLocaleIDs.contains($0) }) {
            return .unsupportedLanguage(Preferences.option(id: missing).label)
        }
        // The same rule the record button applies before starting.
        return profile.setupProblem
    }

    /// Takes `any Error` because a `do` around a SwiftUI action loses the
    /// typed throw; nothing but a ProfileError ever arrives.
    private func showError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = L("profiles.error.title")
        alert.informativeText = (error as? ProfileError)?.message ?? error.localizedDescription
        alert.runModal()
    }
}
