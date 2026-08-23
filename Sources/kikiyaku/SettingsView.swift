import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var directoryPath = TranscriptStore.directory.path
    @State private var audioSource = Preferences.audioSource
    @State private var sourceID = Preferences.sourceLocaleID
    @State private var targetID = Preferences.targetLocaleID
    @State private var confidenceThreshold = Preferences.confidenceThreshold
    @State private var fontSize = Preferences.fontSize
    @State private var sourceFontSize = Preferences.sourceFontSize
    @State private var sourceTextVisible = Preferences.sourceTextVisible
    @State private var newestOnTop = Preferences.newestOnTop
    @State private var liveLines = Preferences.liveLines
    @State private var translationEnabled = Preferences.translationEnabled
    @State private var backend = Preferences.translationBackend
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
                }
                Picker(L("settings.targetLanguage"), selection: $targetID) {
                    ForEach(targetOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .disabled(targetOptions.isEmpty)
                .onChange(of: targetID) {
                    Preferences.targetLocaleID = targetID
                }
                Text(L("settings.languageCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle(L("settings.translation"), isOn: $translationEnabled)
                    .onChange(of: translationEnabled) {
                        Preferences.translationEnabled = translationEnabled
                    }
                Text(L("settings.translationCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Picker(L("settings.backend"), selection: $backend) {
                    Text(L("settings.backend.claude")).tag("claude")
                    Text(L("settings.backend.openai")).tag("openai")
                }
                .disabled(!translationEnabled)
                .onChange(of: backend) {
                    Preferences.translationBackend = backend
                }

                Toggle(L("settings.provisional"), isOn: $provisionalEnabled)
                    .disabled(!translationEnabled || backend != "openai")
                    .onChange(of: provisionalEnabled) {
                        Preferences.provisionalTranslationEnabled = provisionalEnabled
                    }
                Text(L("settings.provisionalCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if backend == "openai" {
                    LabeledContent(L("settings.openaiBaseURL")) {
                        TextField("", text: $openAIBaseURL, prompt: Text(verbatim: "https://api.openai.com"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .autocorrectionDisabled()
                    }
                    .disabled(!translationEnabled)
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
                    .disabled(!translationEnabled)
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
                    .disabled(!translationEnabled)
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
                    .disabled(!translationEnabled)
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
                }

                Picker(L("settings.claudeModel"), selection: $claudeModel) {
                    ForEach(claudeModelOptions, id: \.self) { id in
                        Text(claudeModelLabel(id)).tag(id)
                    }
                }
                .disabled(!translationEnabled || backend != "claude")
                .onChange(of: claudeModel) {
                    Preferences.claudeModel = claudeModel
                }
                Text(L("settings.modelCaption"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

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
                .disabled(!translationEnabled)  // the prompt is shared by both backends
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
            var sources = await Preferences.sourceOptions()
            var targets = await Preferences.targetOptions()
            // If the stored value is missing from the candidates (written directly
            // via defaults, etc.), add the value itself so the Picker does not break.
            if !sources.contains(where: { $0.id == sourceID }) {
                sources.append(Preferences.option(id: sourceID))
            }
            if !targets.contains(where: { $0.id == targetID }) {
                targets.append(Preferences.option(id: targetID))
            }
            sourceOptions = sources
            targetOptions = targets
        }
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
