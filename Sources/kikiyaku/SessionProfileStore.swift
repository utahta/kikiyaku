import Foundation
import Observation
import Speech

/// Session configuration only; display settings and endpoint-scoped API keys
/// remain outside profiles.
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
    var glossaryID: UUID?

    func layoutDiffers(from other: SessionProfile) -> Bool {
        mode != other.mode
            || sourceLocaleID != other.sourceLocaleID
            || targetLocaleID != other.targetLocaleID
    }

    func copy(id: UUID, name: String) -> SessionProfile {
        SessionProfile(
            id: id, name: name, mode: mode, audioSource: audioSource,
            sourceLocaleID: sourceLocaleID, targetLocaleID: targetLocaleID,
            backend: backend, openAIBaseURL: openAIBaseURL, openAIModel: openAIModel,
            claudeModel: claudeModel, provisionalTranslation: provisionalTranslation,
            glossaryID: glossaryID)
    }

    func sameSettings(as other: SessionProfile) -> Bool {
        copy(id: other.id, name: other.name) == other
    }

    /// The editor validates the pair even when the engine would collapse two
    /// equivalent languages to one recognition lane.
    var recognizedLocaleIDs: [String] {
        let ids = mode.isBidirectional ? [sourceLocaleID, targetLocaleID] : [sourceLocaleID]
        return ids.map { Locale(identifier: $0).identifier(.bcp47) }
    }

    /// New profiles must not inherit the selected profile's mirror settings.
    static func blank() -> SessionProfile {
        SessionProfile(
            id: UUID(), name: "", mode: .translate, audioSource: "system",
            sourceLocaleID: "en-US", targetLocaleID: "ja-JP", backend: "openai",
            openAIBaseURL: "", openAIModel: "", claudeModel: "claude-sonnet-5",
            provisionalTranslation: false)
    }

    static func unconfigured() -> SessionProfile {
        var profile = blank()
        profile.name = L("profiles.unconfigured")
        return profile
    }

    /// Transcription needs no backend. API keys are optional for local servers.
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
}

enum ProfileError: Error, Equatable {
    case emptyName
    case duplicateName
    case lastProfile
    case sessionRunning
    case unsavedTranscript
    case unsupportedLanguage(String)
    case notSelected
    case emptyModel
    case invalidURL
    case missingGlossary
    case emptyGlossaryName
    case duplicateGlossaryName
    case glossaryInUse(String)
    case catalogUnreadable
    case catalogVersion(Int)
    case saveFailed
    case backupRequired
    case backupFailed

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
        case .missingGlossary: L("glossaries.error.missing")
        case .emptyGlossaryName: L("glossaries.error.emptyName")
        case .duplicateGlossaryName: L("glossaries.error.duplicateName")
        case .glossaryInUse(let names): LF("glossaries.error.inUse", names)
        case .catalogUnreadable: L("profiles.error.catalogUnreadable")
        case .catalogVersion(let version): LF("profiles.error.catalogVersion", version)
        case .saveFailed: L("profiles.error.saveFailed")
        case .backupRequired: L("profiles.error.backupRequired")
        case .backupFailed: L("profiles.error.backupFailed")
        }
    }
}

/// Unsupported profiles remain selectable in settings so they can be repaired.
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

/// Owns both sides of glossary references. Catalog persistence precedes mirror
/// publication so an interrupted write can be repaired on the next launch.
@MainActor @Observable
final class SessionProfileStore {
    static let shared = SessionProfileStore()
    static let catalogKey = "sessionProfileCatalog"

    private var catalog: SessionProfileCatalog?
    private(set) var loadError: ProfileError?
    private(set) var glossaryNotice: String?
    private(set) var supportedLocaleIDs: Set<String> = []
    private(set) var capabilitiesLoaded = false
    private var recoveryBackup: Data?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionActive: () -> Bool
    @ObservationIgnored private let unsavedTranscript: () -> Bool
    @ObservationIgnored private let layoutChanged: () -> Void

    var profiles: [SessionProfile] { catalog?.profiles ?? [] }
    var selectedID: UUID? { catalog?.selectedID }
    var selected: SessionProfile? { catalog?.selected }
    var glossaries: [Glossary] { catalog?.glossaries ?? [] }
    var hasRecoveryBackup: Bool { recoveryBackup != nil }

    init(defaults: UserDefaults = .standard,
         sessionActive: @escaping () -> Bool = { AppState.shared.phase != .idle },
         unsavedTranscript: @escaping () -> Bool = { Engine.shared.hasUnsavedTranscript },
         layoutChanged: @escaping () -> Void = { AppDelegate.applySettingsChange() }) {
        self.defaults = defaults
        self.sessionActive = sessionActive
        self.unsavedTranscript = unsavedTranscript
        self.layoutChanged = layoutChanged
        do {
            if defaults.object(forKey: Self.catalogKey) != nil {
                guard let data = defaults.data(forKey: Self.catalogKey) else {
                    throw ProfileError.catalogUnreadable
                }
                struct Version: Decodable { let schemaVersion: Int }
                let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
                guard version == 2 else { throw ProfileError.catalogVersion(version) }
                var decoded = try JSONDecoder().decode(SessionProfileCatalog.self, from: data)
                try decoded.validate()
                if decoded.selected == nil {
                    decoded.selectedID = decoded.profiles[0].id
                    decoded.mirrorBaseline = MirrorSettings(defaults: defaults)
                    try persist(decoded)
                } else {
                    catalog = decoded
                    importMirrorIntoSelected(syncLayout: false)
                }
            } else {
                try persist(SessionProfileCatalog.migrate(defaults: defaults))
            }
        } catch {
            loadError = error as? ProfileError ?? .catalogUnreadable
        }
    }

    func glossary(id: UUID) -> Glossary? {
        glossaries.first { $0.id == id }
    }

    func backUpCatalog(to url: URL) throws(ProfileError) {
        let data = try recoveryData()
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw .backupFailed
        }
        recoveryBackup = data
    }

    /// Recovery is explicit and requires a backup of the values being replaced.
    func restoreLegacyAfterBackup() throws(ProfileError) {
        guard !sessionActive() else { throw .sessionRunning }
        guard loadError != nil, let recoveryBackup,
              recoveryBackup == (try recoveryData()) else { throw .backupRequired }
        let hasLegacy = ["sessionProfiles", "sessionProfilesSchemaVersion", "backendProfiles"]
            .contains { defaults.object(forKey: $0) != nil }
        let restored: SessionProfileCatalog = hasLegacy
            ? .migrate(defaults: defaults) : .fresh(defaults: defaults)
        try persist(restored)
        loadError = nil
        glossaryNotice = nil
        self.recoveryBackup = nil
        layoutChanged()
    }

    private func recoveryData() throws(ProfileError) -> Data {
        let keys = [Self.catalogKey, "sessionProfiles", "selectedSessionProfileID",
                    "sessionProfilesSchemaVersion", "backendProfiles"] + MirrorSettings.keys
        var values: [String: Any] = [:]
        for key in keys { values[key] = defaults.object(forKey: key) }
        do {
            return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        } catch {
            throw .backupFailed
        }
    }

    func profilesUsingGlossary(_ id: UUID) -> [SessionProfile] {
        profiles.filter { $0.glossaryID == id }
    }

    @discardableResult
    func addGlossary(name: String, text: String) throws(ProfileError) -> UUID {
        let id = UUID()
        try transact { (candidate: inout SessionProfileCatalog) throws(ProfileError) in
            let name = try Self.validatedGlossaryName(name, excluding: nil, in: candidate)
            candidate.glossaries.append(Glossary(id: id, name: name, text: text))
        }
        return id
    }

    func updateGlossary(_ glossary: Glossary) throws(ProfileError) {
        try transact { (candidate: inout SessionProfileCatalog) throws(ProfileError) in
            guard let index = candidate.glossaries.firstIndex(where: { $0.id == glossary.id }) else {
                throw .missingGlossary
            }
            var glossary = glossary
            glossary.name = try Self.validatedGlossaryName(glossary.name, excluding: glossary.id, in: candidate)
            candidate.glossaries[index] = glossary
        }
    }

    func deleteGlossary(_ id: UUID) throws(ProfileError) {
        try transact { (candidate: inout SessionProfileCatalog) throws(ProfileError) in
            guard candidate.glossaries.contains(where: { $0.id == id }) else { throw .missingGlossary }
            let users = candidate.profiles.filter { $0.glossaryID == id }
            guard users.isEmpty else { throw .glossaryInUse(users.map(\.name).joined(separator: ", ")) }
            candidate.glossaries.removeAll { $0.id == id }
        }
    }

    func dismissGlossaryNotice() {
        glossaryNotice = nil
    }

    private static func validatedGlossaryName(_ name: String, excluding id: UUID?,
                                              in catalog: SessionProfileCatalog) throws(ProfileError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyGlossaryName }
        guard !catalog.glossaries.contains(where: { $0.id != id && $0.name == trimmed }) else {
            throw .duplicateGlossaryName
        }
        return trimmed
    }

    func glossaryName(for profile: SessionProfile) -> String {
        guard let id = profile.glossaryID else { return L("glossaries.none") }
        return glossary(id: id)?.name ?? L("glossaries.missing")
    }

    func glossaryForNextSession() throws(ProfileError) -> String {
        if let loadError { throw loadError }
        guard let catalog, let profile = catalog.selected else { throw .catalogUnreadable }
        guard profile.mode.translates else { return "" }
        guard let text = catalog.text(for: profile) else { throw .missingGlossary }
        return text
    }

    func loadCapabilities() async {
        let locales = await SpeechTranscriber.supportedLocales
        supportedLocaleIDs = Set(locales.map { $0.identifier(.bcp47) })
        capabilitiesLoaded = true
    }

    func switchability(of id: UUID) -> ProfileSwitchability {
        if let loadError { return .blocked(loadError) }
        guard let profile = profiles.first(where: { $0.id == id }), let selected else {
            return .blocked(.notSelected)
        }
        if sessionActive() { return .blocked(.sessionRunning) }
        if profile.layoutDiffers(from: selected), unsavedTranscript() {
            return .blocked(.unsavedTranscript)
        }
        if capabilitiesLoaded,
           let missing = profile.recognizedLocaleIDs.first(where: { !supportedLocaleIDs.contains($0) }) {
            return .unsupported(.unsupportedLanguage(Preferences.option(id: missing).label))
        }
        if profile.mode.translates, let id = profile.glossaryID, glossary(id: id) == nil {
            return .unsupported(.missingGlossary)
        }
        return .available
    }

    func select(_ id: UUID) throws(ProfileError) {
        try transact { (candidate: inout SessionProfileCatalog) throws(ProfileError) in
            guard let target = candidate.profiles.first(where: { $0.id == id }),
                  let current = candidate.selected else { throw .notSelected }
            guard id != current.id else { return }
            try checkSelection(from: current, to: target)
            candidate.selectedID = id
        }
    }

    func update(_ profile: SessionProfile) throws(ProfileError) {
        try transact { (candidate: inout SessionProfileCatalog) throws(ProfileError) in
            guard profile.id == candidate.selectedID,
                  let index = candidate.profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw .notSelected
            }
            guard !sessionActive() else { throw .sessionRunning }
            var profile = profile
            profile.name = try Self.validatedName(profile.name, excluding: profile.id,
                                                  among: candidate.profiles)
            try Self.validateReference(profile, in: candidate)
            candidate.profiles[index] = profile
        }
    }

    @discardableResult
    func add(_ profile: SessionProfile) throws(ProfileError) -> UUID {
        let id = UUID()
        try transact { (candidate: inout SessionProfileCatalog) throws(ProfileError) in
            guard !sessionActive() else { throw .sessionRunning }
            let name = try Self.validatedName(profile.name, excluding: nil, among: candidate.profiles)
            let added = profile.copy(id: id, name: name)
            try Self.validateReference(added, in: candidate)
            if let previous = candidate.selected { try checkSelection(from: previous, to: added) }
            candidate.profiles.append(added)
            candidate.selectedID = id
        }
        return id
    }

    func delete(_ id: UUID) throws(ProfileError) {
        try transact { (candidate: inout SessionProfileCatalog) throws(ProfileError) in
            guard !sessionActive() else { throw .sessionRunning }
            guard candidate.profiles.count > 1 else { throw .lastProfile }
            guard let index = candidate.profiles.firstIndex(where: { $0.id == id }) else { return }
            if id == candidate.selectedID {
                let successor = candidate.profiles[index == 0 ? 1 : index - 1]
                try checkSelection(from: candidate.profiles[index], to: successor)
                candidate.selectedID = successor.id
            }
            candidate.profiles.remove(at: index)
        }
    }

    private func checkSelection(from previous: SessionProfile, to next: SessionProfile) throws(ProfileError) {
        guard !sessionActive() else { throw .sessionRunning }
        if next.layoutDiffers(from: previous), unsavedTranscript() { throw .unsavedTranscript }
    }

    private static func validatedName(_ name: String, excluding id: UUID?,
                                      among profiles: [SessionProfile]) throws(ProfileError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard !profiles.contains(where: { $0.id != id && $0.name == trimmed }) else { throw .duplicateName }
        return trimmed
    }

    private static func validateReference(_ profile: SessionProfile,
                                          in catalog: SessionProfileCatalog) throws(ProfileError) {
        if let id = profile.glossaryID, !catalog.glossaries.contains(where: { $0.id == id }) {
            throw .missingGlossary
        }
    }

    func importMirrorIntoSelected(syncLayout: Bool = true) {
        guard loadError == nil else { return }
        do {
            try transact(syncLayout: syncLayout) { _ in }
        } catch {
            loadError = error
        }
    }

    private func transact(syncLayout: Bool = true,
                          _ edit: (inout SessionProfileCatalog) throws(ProfileError) -> Void) throws(ProfileError) {
        if let loadError { throw loadError }
        guard var candidate = catalog, let previous = candidate.selected,
              let index = candidate.profiles.firstIndex(where: { $0.id == previous.id }) else {
            throw .catalogUnreadable
        }
        Preferences.restoreProvisionalTranslationIfUnset(previous.provisionalTranslation, defaults: defaults)
        let observed = MirrorSettings(defaults: defaults)
        let text = candidate.text(for: previous)
        let resolved = MirrorSettings(profile: previous, glossary: text ?? observed.glossary)
        let imported = resolved.importing(observed, since: candidate.mirrorBaseline)
        candidate.profiles[index] = imported.applying(to: previous)
        var importedGlossary: Glossary?
        let glossaryChanged = text != nil && imported.glossary != resolved.glossary
        if glossaryChanged {
            if imported.glossary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidate.profiles[index].glossaryID = nil
            } else {
                let glossary = Glossary(
                    id: UUID(), name: SessionProfileCatalog.uniqueName(
                        LF("glossaries.migratedName", previous.name), taken: candidate.glossaries.map(\.name)),
                    text: imported.glossary)
                candidate.glossaries.append(glossary)
                candidate.profiles[index].glossaryID = glossary.id
                importedGlossary = glossary
            }
        }
        try edit(&candidate)
        if candidate != catalog {
            candidate.mirrorBaseline = observed
            try persist(candidate)
        } else {
            writeMirror(candidate)
        }
        if glossaryChanged {
            if let importedGlossary,
               !candidate.profiles.contains(where: { $0.glossaryID == importedGlossary.id }) {
                glossaryNotice = LF("glossaries.notice.unused", importedGlossary.name)
            } else if let updated = candidate.profiles.first(where: { $0.id == previous.id }),
                      updated.glossaryID != previous.glossaryID {
                glossaryNotice = LF("glossaries.notice.detached", previous.name)
            }
        }
        if syncLayout, let next = candidate.selected, next.layoutDiffers(from: previous) {
            layoutChanged()
        }
    }

    private func persist(_ candidate: SessionProfileCatalog) throws(ProfileError) {
        try candidate.validate()
        let data: Data
        do {
            data = try JSONEncoder().encode(candidate)
        } catch {
            throw .saveFailed
        }
        defaults.set(data, forKey: Self.catalogKey)
        catalog = candidate
        writeMirror(candidate)
    }

    private func writeMirror(_ candidate: SessionProfileCatalog) {
        guard let selected = candidate.selected else { return }
        let text = candidate.text(for: selected)
        MirrorSettings(profile: selected, glossary: text ?? "")
            .write(to: defaults, includeGlossary: text != nil)
    }
}
