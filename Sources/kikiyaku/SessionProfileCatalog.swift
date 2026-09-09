import Foundation

struct Glossary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var text: String
}

struct MirrorSettings: Codable, Equatable, Sendable {
    var translationEnabled: Bool
    var bidirectionalTranslation: Bool
    var audioSource: String
    var sourceLocaleID: String
    var targetLocaleID: String
    var translationBackend: String
    var openAIBaseURL: String
    var openAIModel: String
    var claudeModel: String
    var provisionalTranslation: Bool
    var glossary: String

    static let keys = [
        "translationEnabled", "bidirectionalTranslation", "audioSource",
        "sourceLocaleID", "targetLocaleID", "translationBackend", "openAIBaseURL",
        "openAIModel", "claudeModel", "provisionalTranslation", "glossary",
    ]

    init(defaults: UserDefaults) {
        translationEnabled = defaults.object(forKey: "translationEnabled") == nil
            || defaults.bool(forKey: "translationEnabled")
        bidirectionalTranslation = defaults.bool(forKey: "bidirectionalTranslation")
        let audio = defaults.string(forKey: "audioSource") ?? "system"
        audioSource = ["mic", "system", "both"].contains(audio) ? audio : "system"
        sourceLocaleID = defaults.string(forKey: "sourceLocaleID") ?? "en-US"
        targetLocaleID = defaults.string(forKey: "targetLocaleID") ?? "ja-JP"
        let backend = defaults.string(forKey: "translationBackend") ?? "openai"
        translationBackend = ["claude", "openai"].contains(backend) ? backend : "openai"
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? ""
        openAIModel = defaults.string(forKey: "openAIModel") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-sonnet-5"
        provisionalTranslation = defaults.bool(forKey: "provisionalTranslation")
        glossary = defaults.string(forKey: "glossary") ?? ""
    }

    init(profile: SessionProfile, glossary: String) {
        translationEnabled = profile.mode.translates
        bidirectionalTranslation = profile.mode.isBidirectional
        audioSource = profile.audioSource
        sourceLocaleID = profile.sourceLocaleID
        targetLocaleID = profile.targetLocaleID
        translationBackend = profile.backend
        openAIBaseURL = profile.openAIBaseURL
        openAIModel = profile.openAIModel
        claudeModel = profile.claudeModel
        provisionalTranslation = profile.provisionalTranslation
        self.glossary = glossary
    }

    func applying(to profile: SessionProfile) -> SessionProfile {
        var profile = profile
        switch (translationEnabled, bidirectionalTranslation) {
        case (true, false): profile.mode = .translate
        case (true, true): profile.mode = .bidirectional
        case (false, false): profile.mode = .transcribe
        case (false, true): profile.mode = .bilingual
        }
        profile.audioSource = audioSource
        profile.sourceLocaleID = sourceLocaleID
        profile.targetLocaleID = targetLocaleID
        profile.backend = translationBackend
        profile.openAIBaseURL = openAIBaseURL
        profile.openAIModel = openAIModel
        profile.claudeModel = claudeModel
        profile.provisionalTranslation = provisionalTranslation
        return profile
    }

    func importing(_ observed: Self, since baseline: Self) -> Self {
        var result = self
        let strings: [WritableKeyPath<Self, String>] = [
            \.audioSource, \.sourceLocaleID, \.targetLocaleID, \.translationBackend,
            \.openAIBaseURL, \.openAIModel, \.claudeModel, \.glossary,
        ]
        for key in strings where observed[keyPath: key] != baseline[keyPath: key]
            && observed[keyPath: key] != self[keyPath: key] {
            result[keyPath: key] = observed[keyPath: key]
        }
        // Compare the two mode keys separately: a partial write is a third mode.
        let flags: [WritableKeyPath<Self, Bool>] = [
            \.translationEnabled, \.bidirectionalTranslation, \.provisionalTranslation,
        ]
        for key in flags where observed[keyPath: key] != baseline[keyPath: key]
            && observed[keyPath: key] != self[keyPath: key] {
            result[keyPath: key] = observed[keyPath: key]
        }
        return result
    }

    func write(to defaults: UserDefaults, includeGlossary: Bool = true) {
        defaults.set(translationEnabled, forKey: "translationEnabled")
        defaults.set(bidirectionalTranslation, forKey: "bidirectionalTranslation")
        defaults.set(audioSource, forKey: "audioSource")
        defaults.set(sourceLocaleID, forKey: "sourceLocaleID")
        defaults.set(targetLocaleID, forKey: "targetLocaleID")
        defaults.set(translationBackend, forKey: "translationBackend")
        defaults.set(openAIBaseURL, forKey: "openAIBaseURL")
        defaults.set(openAIModel, forKey: "openAIModel")
        defaults.set(claudeModel, forKey: "claudeModel")
        defaults.set(provisionalTranslation, forKey: "provisionalTranslation")
        if includeGlossary { defaults.set(glossary, forKey: "glossary") }
    }
}

struct SessionProfileCatalog: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var profiles: [SessionProfile]
    var selectedID: UUID
    var glossaries: [Glossary]
    var mirrorBaseline: MirrorSettings

    var selected: SessionProfile? { profiles.first { $0.id == selectedID } }

    func text(for profile: SessionProfile) -> String? {
        guard let id = profile.glossaryID else { return "" }
        return glossaries.first { $0.id == id }?.text
    }

    func validate() throws(ProfileError) {
        guard schemaVersion == 2 else { throw .catalogVersion(schemaVersion) }
        guard !profiles.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(glossaries.map(\.id)).count == glossaries.count else {
            throw .catalogUnreadable
        }
    }

    static func fresh(defaults: UserDefaults) -> Self {
        let profile = SessionProfile.unconfigured()
        return Self(profiles: [profile], selectedID: profile.id, glossaries: [],
                    mirrorBaseline: MirrorSettings(defaults: defaults))
    }

    static func migrate(defaults: UserDefaults) -> Self {
        var legacy: [LegacySessionProfile]
        var selectedID: UUID
        if defaults.integer(forKey: "sessionProfilesSchemaVersion") >= 1 {
            if let data = defaults.data(forKey: "sessionProfiles"),
               let decoded = try? JSONDecoder().decode([LegacySessionProfile].self, from: data),
               !decoded.isEmpty {
                legacy = decoded
            } else {
                legacy = [.fromMirror(defaults: defaults, name: L("profiles.migrated.default"))]
            }
            if let rawID = defaults.string(forKey: "selectedSessionProfileID"),
               let id = UUID(uuidString: rawID),
               let index = legacy.firstIndex(where: { $0.profile.id == id }) {
                selectedID = id
                Preferences.restoreProvisionalTranslationIfUnset(
                    legacy[index].profile.provisionalTranslation, defaults: defaults)
                let mirror = MirrorSettings(defaults: defaults)
                legacy[index].profile = mirror.applying(to: legacy[index].profile)
                legacy[index].text = mirror.glossary
            } else {
                selectedID = legacy[0].profile.id
            }
        } else {
            let fresh = defaults.object(forKey: "backendProfiles") == nil
                && defaults.object(forKey: "sessionProfiles") == nil
                && MirrorSettings.keys.allSatisfy { defaults.object(forKey: $0) == nil }
            if fresh { return .fresh(defaults: defaults) }
            let current = LegacySessionProfile.fromMirror(defaults: defaults, name: "")
            let old = defaults.data(forKey: "backendProfiles")
                .flatMap { try? JSONDecoder().decode([BackendProfile].self, from: $0) } ?? []
            legacy = []
            for backend in old {
                var profile = current.profile.copy(
                    id: UUID(), name: uniqueName(backend.name, taken: legacy.map { $0.profile.name }))
                profile.backend = backend.backend
                profile.openAIBaseURL = backend.openAIBaseURL
                profile.openAIModel = backend.openAIModel
                profile.claudeModel = backend.claudeModel
                legacy.append(LegacySessionProfile(profile: profile, text: current.text))
            }
            if let match = legacy.first(where: { $0.profile.sameSettings(as: current.profile) }) {
                selectedID = match.profile.id
            } else {
                let base = legacy.isEmpty ? L("profiles.migrated.default") : L("profiles.migrated.current")
                var profile = current.profile
                profile.name = uniqueName(base, taken: legacy.map { $0.profile.name })
                selectedID = profile.id
                legacy.append(LegacySessionProfile(profile: profile, text: current.text))
            }
        }
        var glossaries: [Glossary] = []
        let profiles = legacy.map { entry in
            var profile = entry.profile
            profile.glossaryID = nil
            if !entry.text.isEmpty {
                let glossary = Glossary(
                    id: UUID(), name: uniqueName(LF("glossaries.migratedName", profile.name),
                                                taken: glossaries.map(\.name)), text: entry.text)
                glossaries.append(glossary)
                profile.glossaryID = glossary.id
            }
            return profile
        }
        return Self(profiles: profiles, selectedID: selectedID, glossaries: glossaries,
                    mirrorBaseline: MirrorSettings(defaults: defaults))
    }

    static func uniqueName(_ base: String, taken: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taken.contains(trimmed) else { return trimmed }
        var suffix = 2
        while taken.contains("\(trimmed) \(suffix)") { suffix += 1 }
        return "\(trimmed) \(suffix)"
    }
}

private struct LegacySessionProfile: Decodable {
    var profile: SessionProfile
    var text: String

    init(profile: SessionProfile, text: String) {
        self.profile = profile
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case glossary }

    init(from decoder: any Decoder) throws {
        profile = try SessionProfile(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .glossary) ?? ""
    }

    static func fromMirror(defaults: UserDefaults, name: String) -> Self {
        let mirror = MirrorSettings(defaults: defaults)
        var profile = mirror.applying(to: .blank())
        profile.name = name
        return Self(profile: profile, text: mirror.glossary)
    }
}
