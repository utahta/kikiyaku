import Foundation
import Testing

@testable import kikiyaku

// languageScriptKey decides "same language, nothing to translate". Regions
// are ignored, scripts are not, and Portuguese is the deliberate exception.
struct LanguageScriptKeyTests {
    private func key(_ id: String) -> String {
        Preferences.languageScriptKey(Locale(identifier: id))
    }

    @Test func regionsAreIgnored() {
        #expect(key("en-US") == key("en-GB"))
        #expect(key("ja") == key("ja-JP"))
    }

    @Test func scriptsAreNot() {
        #expect(key("zh-CN") != key("zh-TW"))  // Hans vs Hant
        #expect(key("sr-Latn") != key("sr-Cyrl"))
    }

    /// pt-BR and pt-PT are offered as separate targets, so choosing between
    /// them has to mean something.
    @Test func portugueseKeepsItsRegions() {
        #expect(key("pt-BR") != key("pt-PT"))
    }
}
