import Testing

@testable import kikiyaku

struct TranslationPromptTests {
    @Test(arguments: ["", " \t\r\n", "\u{3000}\n"])
    func anEmptyGlossaryLeavesTheTemplateUnchanged(_ glossary: String) {
        for template in [ClaudeSession.defaultPromptTemplate, "Custom prompt.\n  "] {
            #expect(TranslationPrompt.build(template: template, glossary: glossary) == template)
        }
    }

    @Test func glossaryEntriesFollowTheTemplateInTheirOriginalOrder() {
        let glossary = "release = リリース\ndeadline = 締め切り"
        let prompt = TranslationPrompt.build(
            template: ClaudeSession.defaultPromptTemplate, glossary: "\n\(glossary)\n ")
        #expect(prompt.hasPrefix(ClaudeSession.defaultPromptTemplate + "\n\n"))
        #expect(prompt.hasSuffix("<glossary>\n\(glossary)\n</glossary>"))
    }

    @Test func customPromptsAlsoReceiveTheBidirectionalGlossaryInstruction() {
        let prompt = TranslationPrompt.build(template: "Custom prompt.", glossary: "deadline = 締め切り")
        #expect(prompt == """
            Custom prompt.

            Use the term mappings in the <glossary> below in either translation direction, \
            choosing the form appropriate to the target language.
            <glossary>
            deadline = 締め切り
            </glossary>
            """)
    }
}
