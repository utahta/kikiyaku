import Foundation
import Testing

@testable import kikiyaku

// SessionProfile's pure judgments, which the editor's Save and the record
// button both stand on.
struct SessionProfileTests {
    private func profile(
        mode: SessionMode = .translate,
        backend: String = "openai",
        url: String = "http://localhost:11434",
        model: String = "gemma4:26b-a4b-it-qat",
        claudeModel: String = "claude-sonnet-5",
        source: String = "en-US",
        target: String = "ja-JP"
    ) -> SessionProfile {
        var p = SessionProfile.blank()
        p.name = "test"
        p.mode = mode
        p.backend = backend
        p.openAIBaseURL = url
        p.openAIModel = model
        p.claudeModel = claudeModel
        p.sourceLocaleID = source
        p.targetLocaleID = target
        return p
    }

    // MARK: setupProblem

    @Test func transcriptionNeedsNoBackend() {
        #expect(profile(mode: .transcribe, url: "", model: "").setupProblem == nil)
        #expect(profile(mode: .bilingual, url: "", model: "").setupProblem == nil)
    }

    @Test func openAINeedsAModelFirstThenAnEndpoint() {
        guard case .emptyModel = profile(model: "").setupProblem else {
            Issue.record("expected .emptyModel"); return
        }
        // Model missing AND endpoint broken: the model comes first.
        guard case .emptyModel = profile(url: "", model: "").setupProblem else {
            Issue.record("expected .emptyModel before .invalidURL"); return
        }
        guard case .invalidURL = profile(url: "not a url").setupProblem else {
            Issue.record("expected .invalidURL"); return
        }
        #expect(profile().setupProblem == nil)
    }

    @Test func claudeNeedsAModel() {
        guard case .emptyModel = profile(backend: "claude", claudeModel: "").setupProblem else {
            Issue.record("expected .emptyModel"); return
        }
        #expect(profile(backend: "claude").setupProblem == nil)
    }

    /// The fresh install's profile is blank, and what it lacks first is the
    /// model — both fields are empty and the model is checked first.
    @Test func unconfiguredLacksAModel() {
        guard case .emptyModel = SessionProfile.unconfigured().setupProblem else {
            Issue.record("expected .emptyModel"); return
        }
    }

    // MARK: recognizedLocaleIDs

    @Test func onlyBidirectionalModesRecognizeTheSecondLanguage() {
        #expect(profile(mode: .translate).recognizedLocaleIDs == ["en-US"])
        #expect(profile(mode: .transcribe).recognizedLocaleIDs == ["en-US"])
        #expect(profile(mode: .bidirectional).recognizedLocaleIDs == ["en-US", "ja-JP"])
        #expect(profile(mode: .bilingual).recognizedLocaleIDs == ["en-US", "ja-JP"])
    }

    /// Underscored forms left behind by `defaults write` are canonicalized,
    /// not refused.
    @Test func localeIDsAreCanonicalizedToBCP47() {
        #expect(profile(source: "en_US").recognizedLocaleIDs == ["en-US"])
    }

    // MARK: layoutDiffers / sameSettings

    @Test func onlyModeAndLanguagesChangeTheLayout() {
        let base = profile()
        #expect(profile(mode: .bidirectional).layoutDiffers(from: base))
        #expect(profile(source: "fr-FR").layoutDiffers(from: base))
        #expect(profile(target: "de-DE").layoutDiffers(from: base))
        #expect(!profile(backend: "claude").layoutDiffers(from: base))
        var audio = base
        audio.audioSource = "mic"
        #expect(!audio.layoutDiffers(from: base))
    }

    @Test func sameSettingsIgnoresIdentity() {
        let base = profile()
        let copy = base.copy(id: UUID(), name: "another name")
        #expect(copy.sameSettings(as: base))
        var changed = copy
        changed.openAIModel = "other"
        #expect(!changed.sameSettings(as: base))
    }

    @Test func unconfiguredIsBlankUnderAName() {
        let blank = SessionProfile.blank()
        let unconfigured = SessionProfile.unconfigured()
        #expect(!unconfigured.name.isEmpty)
        #expect(unconfigured.sameSettings(as: blank))
    }
}
