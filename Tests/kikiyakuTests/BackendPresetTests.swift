import Testing

@testable import kikiyaku

// A preset is a fill-in for the connection fields and must leave everything
// that is not a connection field exactly as it was.
struct BackendPresetTests {
    private func draft() -> SessionProfile {
        var p = SessionProfile.blank()
        p.name = "meeting"
        p.mode = .bidirectional
        p.audioSource = "mic"
        p.sourceLocaleID = "fr-FR"
        p.targetLocaleID = "de-DE"
        p.backend = "claude"
        p.openAIBaseURL = "http://example:1"
        p.openAIModel = "old-model"
        p.claudeModel = "claude-opus-5"
        p.provisionalTranslation = false
        return p
    }

    private func untouched(_ after: SessionProfile, _ before: SessionProfile) -> Bool {
        after.name == before.name && after.mode == before.mode
            && after.audioSource == before.audioSource
            && after.sourceLocaleID == before.sourceLocaleID
            && after.targetLocaleID == before.targetLocaleID
            && after.provisionalTranslation == before.provisionalTranslation
    }

    @Test func openAIFillsTheThreeConnectionFields() {
        var p = draft()
        BackendPreset.openAI.apply(to: &p)
        #expect(p.backend == "openai")
        #expect(p.openAIBaseURL == "https://api.openai.com")
        #expect(p.openAIModel == "gpt-5.6-terra")
        #expect(untouched(p, draft()))
    }

    /// The local servers get no model: which models are installed differs from
    /// machine to machine, and a guessed name would be saved as a model that
    /// does not exist.
    @Test func localServersLeaveTheModelEmpty() {
        var lmStudio = draft()
        BackendPreset.lmStudio.apply(to: &lmStudio)
        #expect(lmStudio.openAIBaseURL == "http://localhost:1234")
        #expect(lmStudio.openAIModel.isEmpty)

        var ollama = draft()
        BackendPreset.ollama.apply(to: &ollama)
        #expect(ollama.openAIBaseURL == "http://localhost:11434")
        #expect(ollama.openAIModel.isEmpty)
    }

    /// The Claude preset touches the backend and the Claude model alone; the
    /// OpenAI fields keep whatever they held, ready for a switch back.
    @Test func claudeTouchesOnlyItsOwnFields() {
        var p = draft()
        p.backend = "openai"
        BackendPreset.claudeCLI.apply(to: &p)
        #expect(p.backend == "claude")
        #expect(p.claudeModel == "claude-sonnet-5")
        #expect(p.openAIBaseURL == "http://example:1")
        #expect(p.openAIModel == "old-model")
        #expect(untouched(p, draft()))
    }
}
