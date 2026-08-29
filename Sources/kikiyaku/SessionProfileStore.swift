import Foundation
import Observation
import Speech

/// Everything that decides what the next session does — what it listens to,
/// which languages it recognizes, what it does with the result and through
/// which backend — under one name. The display settings are not in here: they
/// change how a transcript looks, not what a session is, and switching to
/// "English meeting" should not also change the font.
///
/// API keys are deliberately absent. They live in the Keychain per endpoint,
/// so a profile pointing at an endpoint finds its key waiting there, and the
/// profile records (which sit in UserDefaults, in plain text) never carry one.
struct SessionProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var mode: SessionMode
    var audioSource: String
    var sourceLocaleID: String
    var targetLocaleID: String
    var backend: String
    var openAIBaseURL: String
    var openAIModel: String
    var claudeModel: String
    var provisionalTranslation: Bool

    /// Whether switching from `other` to this profile changes how the panel
    /// reads its rows — the mode, or the language pair. A backend or audio
    /// input difference leaves every row looking exactly as it did.
    func layoutDiffers(from other: SessionProfile) -> Bool {
        mode != other.mode
            || sourceLocaleID != other.sourceLocaleID
            || targetLocaleID != other.targetLocaleID
    }

    /// The same settings under a different identity.
    func copy(id: UUID, name: String) -> SessionProfile {
        SessionProfile(
            id: id,
            name: name,
            mode: mode,
            audioSource: audioSource,
            sourceLocaleID: sourceLocaleID,
            targetLocaleID: targetLocaleID,
            backend: backend,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            claudeModel: claudeModel,
            provisionalTranslation: provisionalTranslation
        )
    }

    /// The same fields, ignoring identity — what "the CLI changed something"
    /// and "this old profile matches the current settings" both compare.
    func sameSettings(as other: SessionProfile) -> Bool {
        copy(id: other.id, name: other.name) == other
    }

    /// The locales a session with this profile has to recognize, canonical
    /// BCP-47 so an `en_US` left behind by `defaults write` or an older
    /// version is not mistaken for an unsupported language. The rule is the
    /// settings screen's, not the engine's: the engine drops back to one
    /// language when the pair is the same language twice, but the point here
    /// is that a profile cannot reach a configuration the screen refuses.
    var recognizedLocaleIDs: [String] {
        let ids = mode.isBidirectional ? [sourceLocaleID, targetLocaleID] : [sourceLocaleID]
        return ids.map { Locale(identifier: $0).identifier(.bcp47) }
    }

    /// What a brand-new profile starts as. The text fields are empty — a new
    /// profile has no endpoint until one is chosen or a preset fills it in,
    /// and an empty endpoint also means the editor has no key to look up, so
    /// opening it touches nothing. The pickers cannot be empty, so they hold
    /// the app's defaults. Not the mirror keys: those describe the selected
    /// profile, and a new one built from them would carry its leftovers.
    static func blank() -> SessionProfile {
        SessionProfile(
            id: UUID(),
            name: "",
            mode: .translate,
            audioSource: "system",
            sourceLocaleID: "en-US",
            targetLocaleID: "ja-JP",
            backend: "openai",
            openAIBaseURL: "",
            openAIModel: "",
            claudeModel: "claude-sonnet-5",
            provisionalTranslation: true
        )
    }

    /// The one profile a fresh install starts with: blank, under a name that
    /// says so. Translating rather than transcribing, so that the first press
    /// of the record button leads into the editor instead of quietly running
    /// without the feature the app is named for.
    static func unconfigured() -> SessionProfile {
        var profile = blank()
        profile.name = L("profiles.unconfigured")
        return profile
    }

    /// What is missing for a session to start with this profile, or nil.
    /// The single rule the editor's Save and the record button both apply,
    /// so that the two cannot disagree about what "configured" means.
    /// Transcription needs no LLM at all; the translating modes need a model,
    /// and the OpenAI-compatible backend an endpoint that parses as one.
    ///
    /// Not covered: the name (a saving concern, not a starting one), the
    /// languages (the engine checks them against the recognizer at start),
    /// the claude binary (a fact about the machine, not the profile), and
    /// the API key (Ollama and LM Studio need none, so it cannot be required).
    var setupProblem: ProfileError? {
        guard mode.translates else { return nil }
        switch backend {
        case "openai":
            if openAIModel.isEmpty { return .emptyModel }
            if OpenAICompatSession.endpointURL(baseURL: openAIBaseURL) == nil { return .invalidURL }
        case "claude":
            if claudeModel.isEmpty { return .emptyModel }
        default:
            break
        }
        return nil
    }

    /// The current mirror keys, read back as a profile.
    static func fromPreferences(id: UUID, name: String) -> SessionProfile {
        SessionProfile(
            id: id,
            name: name,
            mode: Preferences.sessionMode,
            audioSource: Preferences.audioSource,
            sourceLocaleID: Preferences.sourceLocaleID,
            targetLocaleID: Preferences.targetLocaleID,
            backend: Preferences.translationBackend,
            openAIBaseURL: Preferences.openAIBaseURL,
            openAIModel: Preferences.openAIModel,
            claudeModel: Preferences.claudeModel,
            provisionalTranslation: Preferences.provisionalTranslationEnabled
        )
    }
}

/// Why a profile cannot be used right now, in words the UI shows as they are.
enum ProfileError: Error {
    case emptyName
    case duplicateName
    case lastProfile
    case sessionRunning
    case unsavedTranscript
    case unsupportedLanguage(String)
    case notSelected
    case emptyModel
    case invalidURL

    var message: String {
        switch self {
        case .emptyName: L("profiles.error.emptyName")
        case .duplicateName: L("profiles.error.duplicateName")
        case .lastProfile: L("profiles.error.lastProfile")
        case .sessionRunning: L("profiles.error.running")
        case .unsavedTranscript: L("profiles.error.unsaved")
        case .unsupportedLanguage(let label): LF("profiles.error.unsupportedLanguage", label)
        case .notSelected: L("profiles.error.notSelected")
        case .emptyModel: L("profiles.error.emptyModel")
        case .invalidURL: L("profiles.error.invalidURL")
        }
    }
}

/// Whether a profile can be switched to, and if not, what stands in the way.
/// Two kinds of "no": `blocked` is about the moment (a session is running, an
/// unsaved transcript would be swept away), `unsupported` is about the profile
/// (a language the recognizer does not know). The menu bar refuses both; the
/// settings screen accepts an unsupported profile, because selecting it is
/// the only way to repair it.
enum ProfileSwitchability {
    case available
    case unsupported(ProfileError)
    case blocked(ProfileError)

    var reason: ProfileError? {
        switch self {
        case .available: nil
        case .unsupported(let error), .blocked(let error): error
        }
    }
}

/// The one place profiles are read, written, selected and mirrored. Exactly
/// one profile is selected at all times and the settings screen edits that
/// profile directly — there is no "apply" step that copies a snapshot into
/// live settings, and so nothing for the two to drift apart from.
///
/// The individual keys the engine reads at start (`sourceLocaleID`,
/// `openAIModel` and so on) stay in UserDefaults as a mirror of the selected
/// profile. The engine is untouched by all this, and `defaults write` still
/// works: a value written to a mirror key is read back as an edit to the
/// selected profile the next time the store looks (launch, opening the
/// settings, opening the profile menu).
@MainActor @Observable
final class SessionProfileStore {
    static let shared = SessionProfileStore()

    private(set) var profiles: [SessionProfile] = []
    private(set) var selectedID = UUID()

    var selected: SessionProfile {
        profiles.first { $0.id == selectedID } ?? profiles[0]
    }

    /// The recognizer's locales, canonical BCP-47. Empty until loaded — and an
    /// empty set means "not known yet", never "nothing is supported": a
    /// profile is judged unsupported only once `capabilitiesLoaded` is true.
    private(set) var supportedLocaleIDs: Set<String> = []
    private(set) var capabilitiesLoaded = false

    private static let profilesKey = "sessionProfiles"
    private static let selectedKey = "selectedSessionProfileID"
    private static let schemaVersionKey = "sessionProfilesSchemaVersion"
    private static let schemaVersion = 1

    /// The keys the engine reads. Their presence is what tells an existing
    /// installation from a fresh one when no profile record exists yet.
    private static let mirrorKeys = [
        "translationEnabled", "bidirectionalTranslation", "audioSource",
        "sourceLocaleID", "targetLocaleID", "translationBackend",
        "openAIBaseURL", "openAIModel", "claudeModel", "provisionalTranslation",
    ]

    private init() {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.schemaVersionKey) < Self.schemaVersion {
            if Self.isFreshInstall(defaults) {
                startUnconfigured()
            } else {
                migrate()
            }
            return
        }
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([SessionProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            // Empty or unreadable: the mirror still describes a working
            // configuration, so rebuild one profile from it rather than
            // start from nothing.
            profiles = [.fromPreferences(id: UUID(), name: L("profiles.migrated.default"))]
            persist()
        }
        if let stored = defaults.string(forKey: Self.selectedKey),
           let id = UUID(uuidString: stored),
           profiles.contains(where: { $0.id == id }) {
            selectedID = id
            // The mirror may have been edited from the CLI since the last
            // look. Read it back before anything else writes over it — the
            // other order would silently lose the edit.
            importMirrorIntoSelected(syncLayout: false)
        } else {
            // The selected profile is gone (deleted through `defaults`, say).
            // The mirror holds *its* values, not the first profile's, so this
            // is the one case where the mirror is not read back: importing
            // here would overwrite the first profile with a dead one's settings.
            selectedID = profiles[0].id
            persistSelection()
            writeMirror(selected)
        }
    }

    // MARK: - Migration

    /// Nothing of an earlier version is present: no old profile key (the key
    /// itself — an empty array stored there is evidence of use) and none of
    /// the mirror keys. Anything saved makes this an existing installation,
    /// whose saved values are carried over by `migrate`. What is deliberately
    /// not carried over is an old default that was never saved: a person who
    /// ran on the old OpenAI default without touching the settings has no
    /// keys and starts unconfigured, which is the point of this change.
    private static func isFreshInstall(_ defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: Preferences.legacyProfilesKey) == nil else { return false }
        return mirrorKeys.allSatisfy { defaults.object(forKey: $0) == nil }
    }

    /// A fresh install's one profile. The mirror is not written: the getters'
    /// defaults already read as this profile, and a mirror key written before
    /// the version stamp would make a launch that died in between look like
    /// an existing installation on the next try.
    private func startUnconfigured() {
        let profile = SessionProfile.unconfigured()
        profiles = [profile]
        selectedID = profile.id
        persist()
        persistSelection()
        UserDefaults.standard.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
    }

    /// First launch with this schema. The old backend-only profiles are kept
    /// as profiles, each completed with the current session settings; the
    /// selection goes to whichever of them matches the current backend
    /// configuration, or to a new profile made from the current settings when
    /// none does. The old key is left in place for a version that still reads
    /// it.
    private func migrate() {
        let current = SessionProfile.fromPreferences(id: UUID(), name: "")
        var converted: [SessionProfile] = []
        for old in Preferences.backendProfiles {
            var profile = current.copy(id: UUID(), name: Self.uniqueName(old.name, among: converted))
            profile.backend = old.backend
            profile.openAIBaseURL = old.openAIBaseURL
            profile.openAIModel = old.openAIModel
            profile.claudeModel = old.claudeModel
            converted.append(profile)
        }
        if let match = converted.first(where: { $0.sameSettings(as: current) }) {
            selectedID = match.id
        } else {
            let base = converted.isEmpty ? L("profiles.migrated.default") : L("profiles.migrated.current")
            var profile = current
            profile.name = Self.uniqueName(base, among: converted)
            converted.append(profile)
            selectedID = profile.id
        }
        profiles = converted
        // Profiles first, selection second, the version stamp last: a launch
        // that dies between them finds no stamp and simply migrates again.
        persist()
        persistSelection()
        UserDefaults.standard.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
    }

    // MARK: - Capabilities

    /// Asks the recognizer which locales it supports. Until this has run,
    /// every profile is judged switchable as far as languages go.
    func loadCapabilities() async {
        let locales = await SpeechTranscriber.supportedLocales
        supportedLocaleIDs = Set(locales.map { $0.identifier(.bcp47) })
        capabilitiesLoaded = true
    }

    // MARK: - Selection

    /// Whether `id` can be switched to now. Decided before anything is written,
    /// which is what makes the unsaved-transcript check a refusal rather than
    /// the silent no-op it would be inside applySettingsChange.
    func switchability(of id: UUID) -> ProfileSwitchability {
        guard let profile = profiles.first(where: { $0.id == id }) else { return .available }
        if AppState.shared.phase != .idle {
            return .blocked(.sessionRunning)
        }
        if profile.layoutDiffers(from: selected), Engine.shared.hasUnsavedTranscript {
            return .blocked(.unsavedTranscript)
        }
        if capabilitiesLoaded,
           let missing = profile.recognizedLocaleIDs.first(where: { !supportedLocaleIDs.contains($0) }) {
            return .unsupported(.unsupportedLanguage(Preferences.option(id: missing).label))
        }
        return .available
    }

    /// Makes `id` the selected profile. Refuses only what `switchability`
    /// calls blocked; an unsupported profile goes through, so that the
    /// settings screen can show it and let its languages be fixed.
    func select(_ id: UUID) throws(ProfileError) {
        guard id != selectedID, let profile = profiles.first(where: { $0.id == id }) else { return }
        if case .blocked(let error) = switchability(of: id) {
            throw error
        }
        let previous = selected
        // The whole profile goes to the mirror in one go before the selection
        // moves: writing field by field would let an observer see a pair that
        // is briefly half one profile and half the other.
        writeMirror(profile)
        selectedID = id
        persistSelection()
        if profile.layoutDiffers(from: previous) {
            AppDelegate.applySettingsChange()
        }
    }

    // MARK: - Editing

    /// Replaces the selected profile with what the editor saved. Owns the one
    /// side effect a save has beyond persistence: re-syncing the panel layout
    /// when the mode or a language changed, and not otherwise (a backend edit
    /// must not clear the history).
    ///
    /// The editor is modal to the settings window only, so by the time it
    /// saves, the selection may have moved (menu bar) or a session may have
    /// started (panel). Both are refused here rather than ignored: a save that
    /// silently did nothing would close the editor looking like a success.
    func update(_ profile: SessionProfile) throws(ProfileError) {
        guard profile.id == selectedID, let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw .notSelected
        }
        guard AppState.shared.phase == .idle else { throw .sessionRunning }
        var profile = profile
        profile.name = try Self.validatedName(profile.name, excluding: profile.id, among: profiles)
        let previous = profiles[index]
        guard profile != previous else { return }
        profiles[index] = profile
        persist()
        writeMirror(profile)
        if profile.layoutDiffers(from: previous) {
            AppDelegate.applySettingsChange()
        }
    }

    /// Adds `profile` under a fresh ID and selects it. The ID the editor built
    /// its draft with is not trusted — taking it as given would let two
    /// profiles share one. Throws when the selection would be blocked, in
    /// which case nothing is added.
    @discardableResult
    func add(_ profile: SessionProfile) throws(ProfileError) -> UUID {
        guard AppState.shared.phase == .idle else { throw .sessionRunning }
        let name = try Self.validatedName(profile.name, excluding: nil, among: profiles)
        let added = profile.copy(id: UUID(), name: name)
        profiles.append(added)
        persist()
        do {
            try select(added.id)
        } catch {
            profiles.removeAll { $0.id == added.id }
            persist()
            throw error
        }
        return added.id
    }

    /// The name as it is stored: trimmed, non-empty, and unlike every other
    /// profile's. Trimming before the comparison is what keeps "foo " from
    /// slipping past the rule that "foo" is taken.
    private static func validatedName(
        _ name: String, excluding id: UUID?, among profiles: [SessionProfile]
    ) throws(ProfileError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard !profiles.contains(where: { $0.id != id && $0.name == trimmed }) else { throw .duplicateName }
        return trimmed
    }

    /// Removes a profile. Deleting the selected one hands the selection to its
    /// neighbour (the one before it, or the one after for the first) through
    /// the ordinary `select`, so the mirror and the layout are updated the
    /// same way a switch updates them — and refused for the same reasons.
    func delete(_ id: UUID) throws(ProfileError) {
        guard profiles.count > 1 else { throw .lastProfile }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if id == selectedID {
            let successor = profiles[index == 0 ? 1 : index - 1]
            try select(successor.id)
        }
        profiles.remove(at: index)
        persist()
    }

    // MARK: - CLI edits

    /// Reads the mirror keys back into the selected profile. A value that
    /// differs from the profile can only have been written from outside — the
    /// store is the app's sole writer — so it is taken as an edit of the
    /// selected profile, exactly as if it had been typed into the settings.
    /// With `syncLayout`, a mode or language change is followed by the same
    /// layout re-sync a typed change gets; launch passes false, since the
    /// panel is about to be built from the mirror anyway.
    func importMirrorIntoSelected(syncLayout: Bool = true) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        let stored = profiles[index]
        let mirrored = SessionProfile.fromPreferences(id: stored.id, name: stored.name)
        guard mirrored != stored else { return }
        profiles[index] = mirrored
        persist()
        if syncLayout, mirrored.layoutDiffers(from: stored) {
            AppDelegate.applySettingsChange()
        }
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: Self.profilesKey)
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedID.uuidString, forKey: Self.selectedKey)
    }

    /// Writes a profile to the keys the engine reads at start.
    private func writeMirror(_ profile: SessionProfile) {
        Preferences.sessionMode = profile.mode
        Preferences.audioSource = profile.audioSource
        Preferences.sourceLocaleID = profile.sourceLocaleID
        Preferences.targetLocaleID = profile.targetLocaleID
        Preferences.translationBackend = profile.backend
        Preferences.openAIBaseURL = profile.openAIBaseURL
        Preferences.openAIModel = profile.openAIModel
        Preferences.claudeModel = profile.claudeModel
        Preferences.provisionalTranslationEnabled = profile.provisionalTranslation
    }

    /// `base`, or `base 2`, `base 3`, … — the first that no profile in `among`
    /// already uses. Names have to stay distinct because a UUID tells two
    /// profiles apart and a reader cannot.
    private static func uniqueName(_ base: String, among profiles: [SessionProfile]) -> String {
        let taken = Set(profiles.map(\.name))
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard taken.contains(trimmed) else { return trimmed }
        var n = 2
        while taken.contains("\(trimmed) \(n)") { n += 1 }
        return "\(trimmed) \(n)"
    }
}
