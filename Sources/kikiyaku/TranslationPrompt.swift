import Foundation

enum TranslationPrompt {
    static func build(template: String, glossary: String) -> String {
        let entries = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entries.isEmpty else { return template }
        return """
            \(template)

            Use the term mappings in the <glossary> below in either translation direction, \
            choosing the form appropriate to the target language.
            <glossary>
            \(entries)
            </glossary>
            """
    }
}
