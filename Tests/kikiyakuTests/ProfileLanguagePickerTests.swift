import SwiftUI
import Testing

@testable import kikiyaku

@MainActor
struct ProfileLanguagePickerTests {
    private let options = [
        LanguageOption(id: "en-US", label: "English"),
        LanguageOption(id: "ja-JP", label: "Japanese"),
    ]

    private func picker(_ selection: Binding<String>, options: [LanguageOption]? = nil,
                        title: String = "Language", help: String = "Help",
                        recognizedIDs: Set<String>? = nil) -> ProfileLanguagePicker {
        ProfileLanguagePicker(selection: selection, options: options ?? self.options,
                              title: title, help: help, recognizedIDs: recognizedIDs)
    }

    @Test func unrelatedDraftEditsKeepPickerEqual() {
        var draft = SessionProfile.blank()
        let selection = Binding(get: { draft.sourceLocaleID }, set: { draft.sourceLocaleID = $0 })
        let before = picker(selection)
        draft.name = "Renamed"
        draft.glossaryID = UUID()
        draft.openAIModel = "New model"
        #expect(before == picker(selection))
    }

    @Test func selectionComparisonUsesSnapshotAndBindingStillWritesThrough() {
        var draft = SessionProfile.blank()
        draft.sourceLocaleID = "en-US"
        let selection = Binding(get: { draft.sourceLocaleID }, set: { draft.sourceLocaleID = $0 })
        let before = picker(selection)
        before.select("ja-JP")
        #expect(draft.sourceLocaleID == "ja-JP")
        #expect(before != picker(selection))
    }

    @Test func candidateLoadingAndLabelChangesInvalidatePicker() {
        let selection = Binding.constant("en-US")
        let before = picker(selection)
        #expect(before != picker(selection, options: []))
        #expect(before != picker(selection, options: Array(options.reversed())))
        #expect(before != picker(selection, options: [LanguageOption(id: "en-US", label: "English")]))
        #expect(before != picker(selection, options: [
            LanguageOption(id: "en-US", label: "英語"), options[1],
        ]))
    }

    @Test func modeLabelsAndHelpInvalidatePicker() {
        let selection = Binding.constant("en-US")
        let before = picker(selection)
        #expect(before != picker(selection, title: "Language 1"))
        #expect(before != picker(selection, help: "Pair help"))
    }

    @Test func groupingAndCapabilitiesInvalidatePicker() {
        let selection = Binding.constant("en-US")
        let ungrouped = picker(selection)
        let grouped = picker(selection, recognizedIDs: [])
        #expect(ungrouped != grouped)
        #expect(grouped != picker(selection, recognizedIDs: ["en-US"]))
        #expect(picker(selection, recognizedIDs: ["en-US", "ja-JP"])
                == picker(selection, recognizedIDs: ["ja-JP", "en-US"]))
    }
}
