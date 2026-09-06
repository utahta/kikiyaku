import Foundation
import Testing

@testable import kikiyaku

struct PreferencesTests {
    @Test(arguments: [false, true])
    func missingProvisionalTranslationKeyRestoresTheSavedValue(enabled: Bool) throws {
        let suiteName = "kikiyakuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(defaults.object(forKey: "provisionalTranslation") == nil)

        Preferences.restoreProvisionalTranslationIfUnset(enabled, defaults: defaults)

        #expect(defaults.object(forKey: "provisionalTranslation") != nil)
        #expect(defaults.bool(forKey: "provisionalTranslation") == enabled)
    }

    @Test(arguments: [false, true])
    func explicitProvisionalTranslationKeyOverridesTheSavedValue(enabled: Bool) throws {
        let suiteName = "kikiyakuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(enabled, forKey: "provisionalTranslation")
        defaults.set("cli-model", forKey: "openAIModel")

        Preferences.restoreProvisionalTranslationIfUnset(!enabled, defaults: defaults)

        #expect(defaults.bool(forKey: "provisionalTranslation") == enabled)
        #expect(defaults.string(forKey: "openAIModel") == "cli-model")
    }
}
