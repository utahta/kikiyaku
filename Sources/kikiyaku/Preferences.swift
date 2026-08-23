import Foundation
import Speech
import Translation

struct LanguageOption: Identifiable, Sendable {
    let id: String     // BCP-47 (e.g. "en-US")
    let label: String  // display name (e.g. "English (United States)")
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

    /// Audio input source: "mic" (default) / "system" (what other apps are
    /// playing, captured with a Core Audio process tap — for online meetings).
    static var audioSource: String {
        get {
            let value = UserDefaults.standard.string(forKey: audioSourceKey) ?? "mic"
            return ["mic", "system"].contains(value) ? value : "mic"
        }
        set { UserDefaults.standard.set(newValue, forKey: audioSourceKey) }
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
        get { UserDefaults.standard.string(forKey: openAIModelKey) ?? "gpt-5.5" }
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

    /// Font size (pt) of the recognized source text (live text and the history
    /// rows' source lines).
    static var sourceFontSize: Double {
        get {
            guard UserDefaults.standard.object(forKey: sourceFontSizeKey) != nil else { return 20 }
            return UserDefaults.standard.double(forKey: sourceFontSizeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: sourceFontSizeKey) }
    }

    /// Whether the recognized source text is shown at all. Defaults to off —
    /// the panel is translation-first, with the source one click away
    /// (per-row and live-slot reveal toggles).
    static var sourceTextVisible: Bool {
        get {
            guard UserDefaults.standard.object(forKey: sourceTextVisibleKey) != nil else { return false }
            return UserDefaults.standard.bool(forKey: sourceTextVisibleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: sourceTextVisibleKey) }
    }

    /// Utterances whose mean recognition confidence falls below this value are not
    /// translated. 0 disables the filter.
    static var confidenceThreshold: Double {
        get {
            guard UserDefaults.standard.object(forKey: confidenceKey) != nil else { return 0.4 }
            return UserDefaults.standard.double(forKey: confidenceKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: confidenceKey) }
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

    /// Source-language candidates: every locale SpeechTranscriber supports.
    static func sourceOptions() async -> [LanguageOption] {
        let supported = await SpeechTranscriber.supportedLocales
        return supported
            .map { option(id: $0.identifier(.bcp47)) }
            .sorted { $0.id < $1.id }
    }

    /// Target-language candidates: every language this machine's Translation
    /// framework supports. (The Apple translation engine itself was removed; the
    /// Translation framework is used only as the source of the target-language
    /// list.)
    /// IDs are normalized to "language-region" form, keeping the script only when
    /// dropping it would change the language. The test compares likely-subtags
    /// expansions (maximalIdentifier):
    ///   - ja(-Jpan)-JP → matches ja-JP's expansion → script unneeded → "ja-JP"
    ///   - zh-Hant-TW  → matches zh-TW's expansion → script unneeded → "zh-TW"
    ///   - zh-Hans-HK  → differs from zh-HK's expansion (Hant) → script needed →
    ///     "zh-Hans-HK"
    /// `Locale.Language.script` cannot distinguish an explicit script from
    /// Foundation's inference, so a script != nil condition would produce ghost
    /// candidates like "ja-Jpan".
    static func targetOptions() async -> [LanguageOption] {
        let supported = await LanguageAvailability().supportedLanguages
        let ids = Set(supported.compactMap { lang -> String? in
            guard let code = lang.languageCode?.identifier else { return nil }
            let region = lang.region?.identifier
            var base = code
            if let region {
                base += "-\(region)"
            }
            if let script = lang.script?.identifier,
               Locale.Language(identifier: base).maximalIdentifier != lang.maximalIdentifier {
                base = region == nil ? "\(code)-\(script)" : "\(code)-\(script)-\(region!)"
            }
            return base
        })
        return ids.map { option(id: $0) }.sorted { $0.id < $1.id }
    }

    static func option(id: String) -> LanguageOption {
        let label = displayLocale.localizedString(forIdentifier: id) ?? id
        return LanguageOption(id: id, label: "\(label) (\(id))")
    }
}
