import Foundation
import Testing

@testable import kikiyaku

@MainActor
struct GlossaryStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "kikiyakuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func store(_ defaults: UserDefaults) -> SessionProfileStore {
        SessionProfileStore(defaults: defaults, sessionActive: { false },
                            unsavedTranscript: { false }, layoutChanged: {})
    }

    private func legacyProfile(id: UUID, name: String, text: String?) -> [String: Any] {
        var record: [String: Any] = [
            "id": id.uuidString, "name": name, "mode": "translate",
            "audioSource": "system", "sourceLocaleID": "en-US", "targetLocaleID": "ja-JP",
            "backend": "openai", "openAIBaseURL": "http://localhost:11434",
            "openAIModel": "local-model", "claudeModel": "claude-model",
            "provisionalTranslation": false,
        ]
        record["glossary"] = text
        return record
    }

    private func seedLegacy(_ records: [[String: Any]], selected: UUID?,
                            defaults: UserDefaults) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: "sessionProfiles")
        defaults.set(1, forKey: "sessionProfilesSchemaVersion")
        defaults.set(selected?.uuidString, forKey: "selectedSessionProfileID")
        if let record = records.first(where: { $0["id"] as? String == selected?.uuidString }) {
            defaults.set(true, forKey: "translationEnabled")
            defaults.set(false, forKey: "bidirectionalTranslation")
            for key in ["audioSource", "sourceLocaleID", "targetLocaleID", "openAIBaseURL",
                        "openAIModel", "claudeModel", "provisionalTranslation", "glossary"] {
                defaults.set(record[key], forKey: key)
            }
            defaults.set(record["backend"], forKey: "translationBackend")
        }
    }

    @Test func legacyTextBecomesAReferenceAndSurvivesRelaunch() throws {
        try withDefaults { defaults in
            let id = UUID()
            let text = " deadline = 締め切り\nrelease = リリース\n"
            try seedLegacy([legacyProfile(id: id, name: "Meeting", text: text)],
                           selected: id, defaults: defaults)
            let migrated = store(defaults)
            #expect(migrated.loadError == nil)
            let profile = try #require(migrated.selected)
            let glossaryID = try #require(profile.glossaryID)
            #expect(profile.id == id)
            #expect(migrated.glossary(id: glossaryID)?.text == text)
            let reopened = store(defaults)
            #expect(reopened.selected?.glossaryID == glossaryID)
            #expect(reopened.glossaries.count == 1)
            #expect(try reopened.glossaryForNextSession() == text)
        }
    }

    @Test func sharedEditsReachBothProfilesWithoutChangingASessionSnapshot() throws {
        try withDefaults { defaults in
            let store = store(defaults)
            let id = try store.addGlossary(name: "Shared", text: "release = リリース")
            var first = try #require(store.selected)
            first.glossaryID = id
            try store.update(first)
            let secondID = try store.add(first.copy(id: UUID(), name: "Second"))
            let startedText = try store.glossaryForNextSession()
            var glossary = try #require(store.glossary(id: id))
            glossary.name = "Renamed"
            glossary.text = "release = 公開"
            try store.updateGlossary(glossary)
            #expect(startedText == "release = リリース")
            #expect(try store.glossaryForNextSession() == "release = 公開")
            try store.select(first.id)
            #expect(try store.glossaryForNextSession() == "release = 公開")
            #expect(Set(store.profilesUsingGlossary(id).map(\.id)) == [first.id, secondID])
            let reopened = self.store(defaults)
            #expect(reopened.glossary(id: id)?.name == "Renamed")
            #expect(reopened.profiles.allSatisfy { $0.glossaryID == id })
        }
    }

    @Test func referencedGlossariesCannotBeDeletedAndUnreferencedOnesRemainUntilDeleted() throws {
        try withDefaults { defaults in
            let store = store(defaults)
            let id = try store.addGlossary(name: "Terms", text: "term = 用語")
            var profile = try #require(store.selected)
            profile.glossaryID = id
            try store.update(profile)
            #expect(throws: ProfileError.glossaryInUse(profile.name)) {
                try store.deleteGlossary(id)
            }
            profile.glossaryID = nil
            try store.update(profile)
            #expect(store.glossary(id: id) != nil)
            try store.deleteGlossary(id)
            #expect(store.glossaries.isEmpty)
            #expect(self.store(defaults).glossaries.isEmpty)
        }
    }

    @Test func unreadableCatalogRequiresBackupBeforeExplicitLegacyRecovery() throws {
        try withDefaults { defaults in
            let id = UUID()
            try seedLegacy([legacyProfile(id: id, name: "Before upgrade", text: "old = 旧")],
                           selected: id, defaults: defaults)
            let broken = Data("broken catalog".utf8)
            defaults.set(broken, forKey: "sessionProfileCatalog")
            let store = store(defaults)
            #expect(store.loadError == .catalogUnreadable)
            #expect(store.selected == nil)
            #expect(throws: ProfileError.catalogUnreadable) { try store.glossaryForNextSession() }
            #expect(throws: ProfileError.backupRequired) { try store.restoreLegacyAfterBackup() }
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).plist")
            defer { try? FileManager.default.removeItem(at: url) }
            try store.backUpCatalog(to: url)
            let backup = try #require(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any])
            #expect(backup["sessionProfileCatalog"] as? Data == broken)
            try store.restoreLegacyAfterBackup()
            #expect(store.loadError == nil)
            #expect(store.selected?.id == id)
            #expect(try store.glossaryForNextSession() == "old = 旧")
            #expect(try self.store(defaults).glossaryForNextSession() == "old = 旧")
        }
    }

    @Test(arguments: ["import", "profile save", "glossary save", "clear"])
    func externalTextOnlyDetachesTheSelectedProfile(operation: String) throws {
        try withDefaults { defaults in
            let store = store(defaults)
            let sharedID = try store.addGlossary(name: "Shared", text: "original")
            var first = try #require(store.selected)
            first.glossaryID = sharedID
            try store.update(first)
            let secondID = try store.add(first.copy(id: UUID(), name: "Second"))
            let draft = try #require(store.selected)
            defaults.set(operation == "clear" ? " \n" : "external", forKey: "glossary")
            switch operation {
            case "profile save": try store.update(draft)
            case "glossary save":
                try store.updateGlossary(Glossary(id: sharedID, name: "Renamed", text: "updated"))
            default: store.importMirrorIntoSelected()
            }
            #expect(store.selectedID == secondID)
            #expect(store.profiles.first { $0.id == first.id }?.glossaryID == sharedID)
            #expect(store.glossary(id: sharedID)?.text == (operation == "glossary save" ? "updated" : "original"))
            #expect(store.glossaryNotice != nil)
            if operation == "clear" {
                #expect(store.selected?.glossaryID == nil)
                #expect(store.glossaries.count == 1)
            } else {
                let imported = try #require(store.glossaries.first { $0.id != sharedID })
                #expect(imported.text == "external")
                if operation == "profile save" {
                    #expect(store.selected?.glossaryID == sharedID)
                    #expect(store.profilesUsingGlossary(imported.id).isEmpty)
                } else {
                    #expect(store.selected?.glossaryID == imported.id)
                    #expect(try store.glossaryForNextSession() == "external")
                }
            }
            let count = store.glossaries.count
            store.importMirrorIntoSelected()
            #expect(self.store(defaults).glossaries.count == count)
        }
    }

    @Test(arguments: [false, true])
    func clearingExternalTextDoesNotNotifyWhenTheSavedReferenceIsUnchanged(saveDraft: Bool) throws {
        try withDefaults { defaults in
            let store = store(defaults)
            var profile = try #require(store.selected)
            if saveDraft {
                profile.glossaryID = try store.addGlossary(name: "Terms", text: "saved text")
                try store.update(profile)
            }
            defaults.set(" \n", forKey: "glossary")
            if saveDraft {
                try store.update(profile)
            } else {
                store.importMirrorIntoSelected()
            }
            #expect(store.selected?.glossaryID == profile.glossaryID)
            #expect(store.glossaryNotice == nil)
        }
    }

    @Test func interruptionBeforeCatalogReplacementLeavesSavedTextIntact() throws {
        let suite = "kikiyakuTests.\(UUID())"
        let defaults = try #require(InterruptedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = store(defaults)
        let id = try store.addGlossary(name: "Terms", text: "saved text")
        var profile = try #require(store.selected)
        profile.glossaryID = id
        try store.update(profile)
        defaults.suppressAllWrites = true
        try store.updateGlossary(Glossary(id: id, name: "Terms", text: "uncommitted text"))
        defaults.suppressAllWrites = false
        let reopened = self.store(defaults)
        #expect(try reopened.glossaryForNextSession() == "saved text")
        #expect(reopened.glossaries.count == 1)
        #expect(reopened.selected?.glossaryID == id)
    }

    @Test func otherExternalSettingsKeepTheGlossaryReference() throws {
        try withDefaults { defaults in
            let store = store(defaults)
            let id = try store.addGlossary(name: "Selected", text: "selected text")
            let unusedID = try store.addGlossary(name: "Unused", text: "unused text")
            var profile = try #require(store.selected)
            profile.glossaryID = id
            try store.update(profile)
            defaults.set("external-model", forKey: "openAIModel")
            store.importMirrorIntoSelected()
            #expect(store.selected?.openAIModel == "external-model")
            #expect(store.selected?.glossaryID == id)
            #expect(store.glossaries.count == 2)
            try store.updateGlossary(Glossary(id: unusedID, name: "Unused", text: "changed unused text"))
            #expect(defaults.string(forKey: "glossary") == "selected text")
            #expect(try store.glossaryForNextSession() == "selected text")
        }
    }

    @Test func invalidCatalogSelectionDoesNotImportThePreviousProfilesMirror() throws {
        try withDefaults { defaults in
            let original = store(defaults)
            let firstID = try #require(original.selectedID)
            var second = SessionProfile.blank()
            second.name = "Second"
            second.openAIModel = "second-model"
            second.sourceLocaleID = "de-DE"
            second.glossaryID = try original.addGlossary(name: "Second", text: "second text")
            _ = try original.add(second)
            let data = try #require(defaults.data(forKey: "sessionProfileCatalog"))
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["selectedID"] = UUID().uuidString
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "sessionProfileCatalog")
            let reopened = store(defaults)
            #expect(reopened.selectedID == firstID)
            #expect(reopened.selected?.openAIModel == "")
            #expect(reopened.selected?.sourceLocaleID == "en-US")
            #expect(reopened.selected?.glossaryID == nil)
            #expect(reopened.glossaries.count == 1)
            #expect(self.store(defaults).selected == reopened.selected)
        }
    }

    @Test func backendOnlyMigrationCreatesIndependentGlossariesForEveryProfile() throws {
        try withDefaults { defaults in
            let backends: [[String: String]] = ["one", "two"].map { model in
                ["name": model, "backend": "openai", "openAIBaseURL": "http://localhost:11434",
                 "openAIModel": model, "claudeModel": "claude-model"]
            }
            defaults.set(try JSONSerialization.data(withJSONObject: backends), forKey: "backendProfiles")
            defaults.set("one", forKey: "openAIModel")
            defaults.set("http://localhost:11434", forKey: "openAIBaseURL")
            defaults.set("claude-model", forKey: "claudeModel")
            defaults.set("shared old text", forKey: "glossary")
            let store = store(defaults)
            #expect(store.loadError == nil)
            #expect(store.profiles.count == 2)
            #expect(store.selected?.name == "one")
            #expect(store.glossaries.count == 2)
            #expect(Set(store.profiles.compactMap(\.glossaryID)).count == 2)
            #expect(store.glossaries.allSatisfy { $0.text == "shared old text" })
        }
    }

    @Test func recoveryRequiresACurrentSuccessfulBackupAndCanResetWithoutLegacyData() throws {
        try withDefaults { defaults in
            defaults.set(Data("broken".utf8), forKey: "sessionProfileCatalog")
            let store = store(defaults)
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let url = directory.appending(path: "backup.plist")
            #expect(throws: ProfileError.backupFailed) { try store.backUpCatalog(to: url) }
            #expect(!store.hasRecoveryBackup)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            try store.backUpCatalog(to: url)
            defaults.set(Data("changed".utf8), forKey: "sessionProfileCatalog")
            #expect(throws: ProfileError.backupRequired) { try store.restoreLegacyAfterBackup() }
            try store.backUpCatalog(to: url)
            try store.restoreLegacyAfterBackup()
            #expect(store.loadError == nil)
            #expect(store.profiles.count == 1)
            #expect(store.selected?.glossaryID == nil)
            #expect(store.glossaries.isEmpty)
            #expect(!store.hasRecoveryBackup)
        }
    }

    @Test(arguments: [SessionMode.translate, .transcribe])
    func missingReferencesPreserveMirrorTextUntilExplicitRepair(mode: SessionMode) throws {
        try withDefaults { defaults in
            let original = store(defaults)
            var profile = try #require(original.selected)
            profile.mode = mode
            try original.update(profile)
            let data = try #require(defaults.data(forKey: "sessionProfileCatalog"))
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var profiles = try #require(json["profiles"] as? [[String: Any]])
            let missingID = UUID()
            profiles[0]["glossaryID"] = missingID.uuidString
            json["profiles"] = profiles
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "sessionProfileCatalog")
            defaults.set("unresolved text", forKey: "glossary")
            let store = self.store(defaults)
            #expect(store.loadError == nil)
            #expect(store.selected?.glossaryID == missingID)
            #expect(defaults.string(forKey: "glossary") == "unresolved text")
            #expect(store.glossaries.isEmpty)
            if mode.translates {
                #expect(throws: ProfileError.missingGlossary) { try store.glossaryForNextSession() }
            } else {
                #expect(try store.glossaryForNextSession() == "")
            }
            var repaired = try #require(store.selected)
            #expect(throws: ProfileError.missingGlossary) { try store.update(repaired) }
            repaired.glossaryID = nil
            try store.update(repaired)
            #expect(try store.glossaryForNextSession() == "")
            #expect(defaults.string(forKey: "glossary") == "")
            #expect(self.store(defaults).selected?.glossaryID == nil)
        }
    }

    @Test(arguments: ["version", "empty", "duplicate profiles", "duplicate glossaries", "wrong type"])
    func invalidCatalogIsPreservedAndBlocksNormalOperations(problem: String) throws {
        try withDefaults { defaults in
            let original = store(defaults)
            _ = try original.addGlossary(name: "Terms", text: "saved")
            let data = try #require(defaults.data(forKey: "sessionProfileCatalog"))
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            switch problem {
            case "version": json["schemaVersion"] = 999
            case "empty": json["profiles"] = [] as [String]
            case "duplicate profiles":
                let profiles = try #require(json["profiles"] as? [[String: Any]])
                json["profiles"] = profiles + profiles
            case "duplicate glossaries":
                let glossaries = try #require(json["glossaries"] as? [[String: Any]])
                json["glossaries"] = glossaries + glossaries
            default: break
            }
            let invalid: Any = problem == "wrong type" ? "not data" : try JSONSerialization.data(withJSONObject: json)
            defaults.set(invalid, forKey: "sessionProfileCatalog")
            let store = self.store(defaults)
            let error: ProfileError = problem == "version" ? .catalogVersion(999) : .catalogUnreadable
            #expect(store.loadError == error)
            #expect(store.profiles.isEmpty)
            #expect(store.selected == nil)
            #expect(throws: error) { try store.addGlossary(name: "New", text: "") }
            #expect(throws: error) { try store.glossaryForNextSession() }
            if let data = invalid as? Data {
                #expect(defaults.data(forKey: "sessionProfileCatalog") == data)
            } else {
                #expect(defaults.string(forKey: "sessionProfileCatalog") == "not data")
            }
        }
    }

    @Test func runningSessionsAllowGlossaryEditsWithoutLayoutChanges() throws {
        try withDefaults { defaults in
            var running = false
            var layoutChanges = 0
            let store = SessionProfileStore(defaults: defaults, sessionActive: { running },
                                            unsavedTranscript: { true }, layoutChanged: { layoutChanges += 1 })
            let glossaryID = try store.addGlossary(name: "Shared", text: "before")
            var first = try #require(store.selected)
            first.glossaryID = glossaryID
            try store.update(first)
            let secondID = try store.add(first.copy(id: UUID(), name: "Second"))
            let snapshot = try store.glossaryForNextSession()
            running = true
            try store.updateGlossary(Glossary(id: glossaryID, name: "Renamed", text: "after"))
            let unusedID = try store.addGlossary(name: "Unused", text: "")
            try store.deleteGlossary(unusedID)
            #expect(snapshot == "before")
            #expect(try store.glossaryForNextSession() == "after")
            #expect(throws: ProfileError.sessionRunning) { try store.select(first.id) }
            #expect(throws: ProfileError.sessionRunning) { try store.update(try #require(store.selected)) }
            #expect(throws: ProfileError.sessionRunning) { try store.delete(secondID) }
            #expect(layoutChanges == 0)
            running = false
            var second = try #require(store.selected)
            second.glossaryID = nil
            try store.update(second)
            #expect(layoutChanges == 0)
            second.sourceLocaleID = "fr-FR"
            try store.update(second)
            #expect(layoutChanges == 1)
        }
    }

    @Test func glossaryValidationRejectsEmptyDuplicateAndDeletedTargets() throws {
        try withDefaults { defaults in
            let store = store(defaults)
            #expect(store.glossaries.isEmpty)
            #expect(store.selected?.glossaryID == nil)
            #expect(throws: ProfileError.emptyGlossaryName) { try store.addGlossary(name: " \n", text: "") }
            let id = try store.addGlossary(name: " Terms\n", text: "")
            #expect(store.glossary(id: id)?.name == "Terms")
            #expect(throws: ProfileError.duplicateGlossaryName) { try store.addGlossary(name: "Terms", text: "") }
            _ = try store.addGlossary(name: "terms", text: "case sensitive")
            let draft = try #require(store.glossary(id: id))
            try store.deleteGlossary(id)
            #expect(throws: ProfileError.missingGlossary) { try store.updateGlossary(draft) }
            var profile = try #require(store.selected)
            profile.glossaryID = id
            #expect(throws: ProfileError.missingGlossary) { try store.update(profile) }
            profile.name = "New"
            #expect(throws: ProfileError.missingGlossary) { try store.add(profile) }
            #expect(store.selected?.glossaryID == nil)
            #expect(store.profiles.count == 1)
        }
    }

    @Test(arguments: ["valid", "invalid", "external"])
    func migrationPreservesIndependentTextsAndOnlyImportsAValidSelection(selection: String) throws {
        try withDefaults { defaults in
            let ids = (0..<5).map { _ in UUID() }
            let texts: [String?] = ["same\n", "same\n", "", " \n", nil]
            try seedLegacy(zip(ids, texts).map { legacyProfile(id: $0, name: "Meeting", text: $1) },
                           selected: selection == "invalid" ? UUID() : ids[0], defaults: defaults)
            let oldData = defaults.data(forKey: "sessionProfiles")
            if selection != "valid" { defaults.set("external", forKey: "glossary") }
            let store = store(defaults)
            #expect(store.loadError == nil)
            #expect(store.selectedID == ids[0])
            #expect(store.glossaries.count == 3)
            #expect(Set(store.glossaries.map(\.name)).count == 3)
            #expect(store.profiles[0].glossaryID != store.profiles[1].glossaryID)
            #expect(try store.glossaryForNextSession() == (selection == "external" ? "external" : "same\n"))
            #expect(store.glossary(id: try #require(store.profiles[1].glossaryID))?.text == "same\n")
            #expect(store.glossary(id: try #require(store.profiles[3].glossaryID))?.text == " \n")
            #expect(store.profiles[2].glossaryID == nil)
            #expect(store.profiles[4].glossaryID == nil)
            #expect(defaults.data(forKey: "sessionProfiles") == oldData)
            #expect(self.store(defaults).glossaries == store.glossaries)
        }
    }

    @Test(arguments: [SessionMode.translate, .bidirectional, .transcribe, .bilingual],
          [SessionMode.translate, .bidirectional, .transcribe, .bilingual])
    func partiallyPublishedModeFlagsDoNotImportAThirdMode(from: SessionMode, to: SessionMode) throws {
        for publishedKeys: Set<String> in [[], ["translationEnabled"], ["bidirectionalTranslation"],
                                           ["translationEnabled", "bidirectionalTranslation"]] {
            let suite = "kikiyakuTests.\(UUID())"
            let defaults = try #require(InterruptedDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = store(defaults)
            var profile = try #require(store.selected)
            profile.mode = from
            try store.update(profile)
            profile.mode = to
            defaults.publishedKeys = publishedKeys
            try store.update(profile)
            defaults.publishedKeys = nil
            let reopened = self.store(defaults)
            #expect(reopened.selected?.mode == to)
            #expect(defaults.bool(forKey: "translationEnabled") == to.translates)
            #expect(defaults.bool(forKey: "bidirectionalTranslation") == to.isBidirectional)
        }
    }

    @Test(arguments: ["select", "add", "delete", "profile save", "glossary save", "import"],
          [Set<String>(), ["sourceLocaleID", "glossary"], ["openAIModel", "translationEnabled"]])
    func interruptedMirrorPublicationKeepsTheCommittedSelection(
        operation: String, publishedKeys: Set<String>
    ) throws {
        let suite = "kikiyakuTests.\(UUID())"
        let defaults = try #require(InterruptedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = store(defaults)
        let firstGlossary = try store.addGlossary(name: "First", text: "first text")
        let secondGlossary = try store.addGlossary(name: "Second", text: "second text")
        var first = try #require(store.selected)
        first.glossaryID = firstGlossary
        first.openAIModel = "first-model"
        try store.update(first)
        var second = first.copy(id: UUID(), name: "Second")
        second.sourceLocaleID = "de-DE"
        second.targetLocaleID = "fr-FR"
        second.openAIModel = "second-model"
        second.glossaryID = secondGlossary
        let secondID = try store.add(second)
        if operation != "delete" { try store.select(first.id) }
        if operation == "import" {
            defaults.set("external text", forKey: "glossary")
            defaults.set("external-model", forKey: "openAIModel")
        }
        defaults.publishedKeys = publishedKeys
        switch operation {
        case "select": try store.select(secondID)
        case "add": _ = try store.add(second.copy(id: UUID(), name: "Third"))
        case "delete": try store.delete(secondID)
        case "profile save":
            first.sourceLocaleID = "de-DE"
            first.openAIModel = "updated-model"
            first.glossaryID = secondGlossary
            try store.update(first)
        case "glossary save":
            try store.updateGlossary(Glossary(id: firstGlossary, name: "Renamed", text: "updated text"))
        default: store.importMirrorIntoSelected()
        }
        let committed = store.selected
        let text = try store.glossaryForNextSession()
        let glossaries = store.glossaries
        defaults.publishedKeys = nil
        let reopened = self.store(defaults)
        #expect(reopened.loadError == nil)
        #expect(reopened.selected == committed)
        #expect(reopened.glossaries == glossaries)
        #expect(try reopened.glossaryForNextSession() == text)
        #expect(defaults.string(forKey: "glossary") == text)
        #expect(defaults.string(forKey: "openAIModel") == committed?.openAIModel)
        #expect(defaults.string(forKey: "sourceLocaleID") == committed?.sourceLocaleID)
    }
}

private final class InterruptedDefaults: UserDefaults, @unchecked Sendable {
    var publishedKeys: Set<String>?
    var suppressAllWrites = false

    override func set(_ value: Any?, forKey key: String) {
        if suppressAllWrites { return }
        if let publishedKeys, key != "sessionProfileCatalog", !publishedKeys.contains(key) { return }
        super.set(value, forKey: key)
    }

    override func set(_ value: Bool, forKey key: String) {
        set(NSNumber(value: value), forKey: key)
    }
}
