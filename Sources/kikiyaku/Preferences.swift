import Foundation
import Speech

struct LanguageOption: Identifiable, Sendable {
    let id: String     // BCP-47 (e.g. "en-US")
    let label: String  // display name (e.g. "English (United States)")
}

/// What a session does: the single value the settings screen selects and a
/// start pins down. Persisted as two orthogonal booleans (translationEnabled ×
/// bidirectionalEnabled) so each axis stays individually writable through
/// `defaults write`, but the app itself only ever reads and writes the pair
/// through this type — a half-updated combination the menu never offers
/// cannot be observed.
enum SessionMode: String, Sendable, CaseIterable, Identifiable {
    var id: String { rawValue }

    /// Language 1 is recognized and translated into language 2.
    case translate
    /// Both languages are recognized; each utterance is translated into the
    /// other language.
    case bidirectional
    /// Language 1 is recognized, without translation.
    case transcribe
    /// Both languages are recognized without translation (bilingual transcript).
    case bilingual

    /// The session translates, so the backend configuration is live.
    var translates: Bool { self == .translate || self == .bidirectional }
    /// Every channel recognizes both languages of the pair.
    var isBidirectional: Bool { self == .bidirectional || self == .bilingual }
}

/// A named snapshot of the translation-backend configuration, e.g.
/// "local qwen" (LM Studio) vs "OpenAI cloud". Keys are deliberately not
/// included: they live in the Keychain per endpoint and follow automatically.
struct BackendProfile: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var backend: String
    var openAIBaseURL: String
    var openAIModel: String
    var claudeModel: String
    var id: String { name }
}

/// App settings. Persisted in UserDefaults (com.utahta.kikiyaku), so they can
/// also be changed from the CLI, e.g. `defaults write com.utahta.kikiyaku
/// sourceLocaleID en-GB`.
enum Preferences {
    private static let sourceKey = "sourceLocaleID"
    private static let targetKey = "targetLocaleID"
    private static let confidenceKey = "minTranslationConfidence"
    private static let fontSizeKey = "fontSize"
    private static let panelOpacityKey = "panelOpacity"

    /// Panel opacity (0.3–1.0). Defaults to a slightly translucent 0.85.
    static var panelOpacity: Double {
        get {
            guard UserDefaults.standard.object(forKey: panelOpacityKey) != nil else { return 0.85 }
            return min(1.0, max(0.3, UserDefaults.standard.double(forKey: panelOpacityKey)))
        }
        set { UserDefaults.standard.set(newValue, forKey: panelOpacityKey) }
    }

    private static let newestOnTopKey = "newestOnTop"
    private static let liveLinesKey = "liveRegionLines"
    private static let translationEnabledKey = "translationEnabled"
    private static let backendKey = "translationBackend"
    private static let openAIBaseURLKey = "openAIBaseURL"
    private static let openAIModelKey = "openAIModel"
    private static let claudeModelKey = "claudeModel"

    private static let provisionalKey = "provisionalTranslation"

    /// Provisionally translate the closed sentences of the in-progress
    /// utterance (sentence-boundary triggered, with a time fallback).
    /// Effective only with the OpenAI-compatible backend — the pipe-based
    /// Claude CLI session cannot serve the concurrent requests.
    static var provisionalTranslationEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: provisionalKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: provisionalKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: provisionalKey) }
    }

    private static let audioSourceKey = "audioSource"

    /// Audio input source: "system" (default — whatever other apps are playing,
    /// captured with a Core Audio process tap) / "mic" / "both" (both channels
    /// at once, e.g. your own voice alongside the remote participants of a
    /// call).
    ///
    /// System audio leads because it is what the app is mostly reached for: a
    /// call, a video, a stream — speech the machine is playing and the listener
    /// cannot replay. It also needs no microphone permission on first run.
    static var audioSource: String {
        get {
            let value = UserDefaults.standard.string(forKey: audioSourceKey) ?? "system"
            return ["mic", "system", "both"].contains(value) ? value : "system"
        }
        set { UserDefaults.standard.set(newValue, forKey: audioSourceKey) }
    }

    private static let bidirectionalKey = "bidirectionalTranslation"

    /// Bidirectional mode: recognize both languages of the pair on every
    /// selected channel, adopt each finalized utterance by confidence, and
    /// translate it into the other language. Off = classic one-direction mode.
    static var bidirectionalEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: bidirectionalKey) }
        set { UserDefaults.standard.set(newValue, forKey: bidirectionalKey) }
    }

    /// "language-script" key (script filled in via likely subtags, region
    /// ignored). Examples: zh-CN → zh-Hans, zh-TW → zh-Hant, en-US / en-GB →
    /// en-Latn. Two locales with the same key need no translation between them.
    static func languageScriptKey(_ locale: Locale) -> String {
        let maximal = Locale.Language(identifier: locale.language.maximalIdentifier)
        let code = maximal.languageCode?.identifier ?? locale.identifier
        let script = maximal.script?.identifier ?? ""
        // Where the candidate list offers a language's regions as separate
        // entries, choosing between them has to mean something: pt-BR and
        // pt-PT share pt-Latn, and folding them together would decide "same
        // language, nothing to translate" against a reader who deliberately
        // picked the other one. Regions stay ignored everywhere else, so
        // en-US → en-GB still needs no translation.
        if let region = maximal.region?.identifier, regionalLanguages.contains(code) {
            return "\(code)-\(script)-\(region)"
        }
        return "\(code)-\(script)"
    }

    /// Languages whose regions the target list publishes separately, and which
    /// therefore have to survive the same-language test. Chinese and Serbian
    /// are already told apart by their scripts.
    private static let regionalLanguages: Set<String> = ["pt"]

    /// The mode selection resolved the way a session start resolves it:
    /// bidirectional only when the pair's languages actually differ
    /// (script-aware) — with an identical pair the engine falls back to the
    /// classic flow, and the panel layout follows suit.
    static var bidirectionalConfigured: Bool {
        sessionMode.isBidirectional
            && languageScriptKey(sourceLocale) != languageScriptKey(targetLocale)
    }

    /// The mode the settings screen selects, read and written as one value
    /// (see SessionMode). A start snapshots it once, before its first await,
    /// so a mid-start change cannot mix the two stored flags.
    static var sessionMode: SessionMode {
        get {
            switch (translationEnabled, bidirectionalEnabled) {
            case (true, false): .translate
            case (true, true): .bidirectional
            case (false, false): .transcribe
            case (false, true): .bilingual
            }
        }
        set {
            translationEnabled = newValue.translates
            bidirectionalEnabled = newValue.isBidirectional
        }
    }

    private static let claudePathKey = "claudePath"

    /// Explicit path to the claude CLI. When empty, ClaudeBinary.resolve
    /// auto-detects from its candidate list.
    static var claudePath: String {
        get { UserDefaults.standard.string(forKey: claudePathKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: claudePathKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: claudePathKey)
            }
        }
    }

    /// Translation backend: "openai" (OpenAI-compatible API, local servers
    /// included — the default) / "claude" (persistent CLI).
    static var translationBackend: String {
        get {
            let value = UserDefaults.standard.string(forKey: backendKey) ?? "openai"
            return ["claude", "openai"].contains(value) ? value : "openai"
        }
        set { UserDefaults.standard.set(newValue, forKey: backendKey) }
    }

    private static let profilesKey = "backendProfiles"

    /// Saved backend configurations, switchable from the settings screen.
    /// API keys are not part of a profile — they are stored per endpoint in
    /// the Keychain and follow the endpoint automatically.
    static var backendProfiles: [BackendProfile] {
        get {
            guard let data = UserDefaults.standard.data(forKey: profilesKey),
                  let profiles = try? JSONDecoder().decode([BackendProfile].self, from: data) else {
                return []
            }
            return profiles
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: profilesKey)
        }
    }

    /// Endpoint of the OpenAI-compatible API. Cloud: https://api.openai.com;
    /// local: http://localhost:1234 (LM Studio) and the like.
    static var openAIBaseURL: String {
        get { UserDefaults.standard.string(forKey: openAIBaseURLKey) ?? "https://api.openai.com" }
        set { UserDefaults.standard.set(newValue, forKey: openAIBaseURLKey) }
    }

    static var openAIModel: String {
        get { UserDefaults.standard.string(forKey: openAIModelKey) ?? "gpt-5.6-terra" }
        set { UserDefaults.standard.set(newValue, forKey: openAIModelKey) }
    }

    /// Whether translation is enabled. Off means transcription only.
    static var translationEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: translationEnabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: translationEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: translationEnabledKey) }
    }

    /// Model used for Claude translation. Changeable in the settings screen or via
    /// `defaults write com.utahta.kikiyaku claudeModel <id>`.
    static var claudeModel: String {
        get { UserDefaults.standard.string(forKey: claudeModelKey) ?? "claude-sonnet-5" }
        set { UserDefaults.standard.set(newValue, forKey: claudeModelKey) }
    }

    private static let uiLanguageKey = "uiLanguage"

    /// UI display language: "system" (follow the system) / "ja" / "en". Takes
    /// effect after an app relaunch.
    ///
    /// The state lives in an app-specific key (uiLanguage); the actual language
    /// switch is done by writing AppleLanguages (the same mechanism as macOS's
    /// per-app language setting). Never read AppleLanguages back to decide:
    /// UserDefaults.standard inherits the global domain, so the system language
    /// comes back even without an app-specific setting, making "follow the system"
    /// indistinguishable from "explicitly fixed".
    static var uiLanguage: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: uiLanguageKey) {
                return stored
            }
            // Even without our own key, honor a value set through the system's
            // per-app language setting (AppleLanguages in the app's own persistent
            // domain).
            if let bundleID = Bundle.main.bundleIdentifier,
               let domain = UserDefaults.standard.persistentDomain(forName: bundleID),
               let languages = domain["AppleLanguages"] as? [String],
               let first = languages.first {
                if first.hasPrefix("ja") { return "ja" }
                if first.hasPrefix("en") { return "en" }
            }
            return "system"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: uiLanguageKey)
            if newValue == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Locale for display text such as language names. Always follows the
    /// localization the resource bundle actually selected (resolvedUILanguage) so
    /// it matches the UI strings. Locale.current is never used: not only when the
    /// display language is fixed, but also under "follow the system", a macOS
    /// preferred language the app does not support (e.g. French) would diverge
    /// from the UI strings' fallback and leave just the language names in a
    /// different language.
    static var displayLocale: Locale {
        Locale(identifier: resolvedUILanguage)
    }

    private static let autoStopKey = "autoStopMinutes"

    /// Auto-stop after this many minutes without any recognition results. 0 turns
    /// it off. Guards against forgetting to stop.
    static var autoStopMinutes: Int {
        get {
            guard UserDefaults.standard.object(forKey: autoStopKey) != nil else { return 10 }
            return max(0, min(180, UserDefaults.standard.integer(forKey: autoStopKey)))
        }
        set { UserDefaults.standard.set(newValue, forKey: autoStopKey) }
    }

    private static let claudePromptKey = "claudeSystemPrompt"

    /// Custom system prompt template. nil means the default is used.
    static var claudePromptOverride: String? {
        get {
            let value = UserDefaults.standard.string(forKey: claudePromptKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(newValue, forKey: claudePromptKey)
            } else {
                UserDefaults.standard.removeObject(forKey: claudePromptKey)
            }
        }
    }

    /// Number of lines in the newest-on-top layout's live region (in-progress
    /// recognition text).
    static var liveLines: Int {
        get {
            guard UserDefaults.standard.object(forKey: liveLinesKey) != nil else { return 3 }
            return max(1, min(8, UserDefaults.standard.integer(forKey: liveLinesKey)))
        }
        set { UserDefaults.standard.set(newValue, forKey: liveLinesKey) }
    }

    /// true: pin the in-progress recognition text in a fixed region at the top and
    /// show finalized utterances newest-first below it.
    /// false: classic layout, appending at the bottom and following the bottom edge.
    static var newestOnTop: Bool {
        get {
            guard UserDefaults.standard.object(forKey: newestOnTopKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: newestOnTopKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: newestOnTopKey) }
    }

    /// Font size (pt) of translations in the panel.
    static var fontSize: Double {
        get {
            guard UserDefaults.standard.object(forKey: fontSizeKey) != nil else { return 20 }
            return UserDefaults.standard.double(forKey: fontSizeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: fontSizeKey) }
    }

    private static let sourceFontSizeKey = "sourceFontSize"
    private static let sourceTextVisibleKey = "sourceTextVisible"
    private static let liveSourceTextVisibleKey = "liveSourceTextVisible"

    /// Font size (pt) of the recognized source text (live text and the history
    /// rows' source lines).
    static var sourceFontSize: Double {
        get {
            guard UserDefaults.standard.object(forKey: sourceFontSizeKey) != nil else { return 20 }
            return UserDefaults.standard.double(forKey: sourceFontSizeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: sourceFontSizeKey) }
    }

    /// Whether the history rows carry their source text. Defaults to off — the
    /// panel is translation-first, and a row's source is one click away. Every
    /// row keeping both lines would double the height of the scrollback.
    static var sourceTextVisible: Bool {
        get {
            guard UserDefaults.standard.object(forKey: sourceTextVisibleKey) != nil else { return false }
            return UserDefaults.standard.bool(forKey: sourceTextVisibleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: sourceTextVisibleKey) }
    }

    /// Whether the live region shows the recognition text of the utterance
    /// being spoken. Defaults to on, unlike the history: the translation
    /// arrives about a second late, and the spinner alone says only that
    /// something is happening, not that the words were heard correctly. It
    /// costs nothing in height either — the line is transient, and what stays
    /// behind in the history is the translation alone.
    static var liveSourceTextVisible: Bool {
        get {
            guard UserDefaults.standard.object(forKey: liveSourceTextVisibleKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: liveSourceTextVisibleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: liveSourceTextVisibleKey) }
    }

    /// Default confidence floor, and the value the bidirectional modes fall
    /// back to when the filter is switched off (see confidenceFloor).
    static let defaultConfidenceThreshold = 0.4

    /// Utterances whose mean recognition confidence falls below this value are not
    /// translated. 0 disables the filter.
    static var confidenceThreshold: Double {
        get {
            guard UserDefaults.standard.object(forKey: confidenceKey) != nil else {
                return defaultConfidenceThreshold
            }
            return UserDefaults.standard.double(forKey: confidenceKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: confidenceKey) }
    }

    /// The floor a session actually applies.
    ///
    /// In one-direction mode the floor only filters out mis-recognitions, so
    /// switching it off is a legitimate choice. In the bidirectional modes it
    /// *is* the language judgment: with no floor, every utterance is adopted
    /// by both recognizers, producing a duplicate row and — with translation
    /// on — a confident-looking translation of the wrong-language garbage,
    /// every single time. Partial dedup narrows that but cannot stand in for
    /// the floor: it acts only on a clear confidence gap, and not at all when
    /// a confidence is missing. So "off" falls back to the default floor
    /// there. A deliberate non-zero value is always respected — the settings
    /// caption invites tuning it against the confidences recorded in the
    /// JSONL, and overriding that would break the invitation.
    ///
    /// Enforced here rather than only in the settings UI, so a value carried
    /// over from an older install or written with `defaults write` cannot
    /// disable the language judgment either.
    static func confidenceFloor(bidirectional: Bool) -> Double {
        let configured = confidenceThreshold
        if bidirectional && configured <= 0 { return defaultConfidenceThreshold }
        return configured
    }

    static var sourceLocaleID: String {
        get { UserDefaults.standard.string(forKey: sourceKey) ?? "en-US" }
        set { UserDefaults.standard.set(newValue, forKey: sourceKey) }
    }

    static var targetLocaleID: String {
        get { UserDefaults.standard.string(forKey: targetKey) ?? "ja-JP" }
        set { UserDefaults.standard.set(newValue, forKey: targetKey) }
    }

    static var sourceLocale: Locale { Locale(identifier: sourceLocaleID) }
    static var targetLocale: Locale { Locale(identifier: targetLocaleID) }

    /// Every locale SpeechTranscriber supports — the candidates for any
    /// language that has to be recognized: language 1 always, and language 2 in
    /// the modes that recognize both.
    static func languageOptions() async -> [LanguageOption] {
        let supported = await SpeechTranscriber.supportedLocales
        return supported
            .map { option(id: $0.identifier(.bcp47)) }
            .sorted { $0.id < $1.id }
    }

    /// Candidates for the translation target of the one-direction mode, where
    /// the language is never recognized — only named to the LLM, which can
    /// translate into anything. Holding this list down to the recognizer's
    /// locales gave away the very thing translating with an LLM is good for.
    ///
    /// Three layers. The recognizer's own locales come first, because those are
    /// the ones that also work in the modes that recognize both languages. Then
    /// every ISO language Foundation both names and places in a locale — that
    /// second half of the test is what keeps Avestan and Akkadian out of the
    /// menu, and it is the whole test: a length limit would have thrown out
    /// Cantonese, Filipino and Hawaiian along with them. Then the handful of
    /// variants a bare language code cannot express but a translation has to
    /// distinguish — none of which appear in Locale.availableIdentifiers, so
    /// they have to be named here.
    static func translationTargetOptions() async -> [LanguageOption] {
        var seen = Set<String>()
        let recognized = await languageOptions().filter { seen.insert($0.id).inserted }

        let placed = Set(Locale.availableIdentifiers.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        })
        let variants = ["zh-Hans", "zh-Hant", "pt-BR", "pt-PT", "sr-Latn", "sr-Cyrl"]
        let codes = Locale.LanguageCode.isoLanguageCodes
            .map(\.identifier)
            .filter { placed.contains($0) }

        let rest = (variants + codes)
            .filter { seen.insert($0).inserted }
            .map { option(id: $0) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return recognized + rest
    }

    static func option(id: String) -> LanguageOption {
        let label = displayLocale.localizedString(forIdentifier: id) ?? id
        return LanguageOption(id: id, label: "\(label) (\(id))")
    }
}
