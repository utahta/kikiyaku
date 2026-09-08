import SwiftUI

// Unrelated draft edits must not rebuild the language menu's hundreds of items.
struct ProfileLanguagePicker: View, Equatable {
    private let selectedID: String
    let select: (String) -> Void
    let options: [LanguageOption]
    let title: String
    let help: String
    let recognizedIDs: Set<String>?

    init(selection: Binding<String>, options: [LanguageOption], title: String,
         help: String, recognizedIDs: Set<String>? = nil) {
        selectedID = selection.wrappedValue
        // Storing @Binding would also subscribe this view to unrelated draft edits.
        select = { selection.wrappedValue = $0 }
        self.options = options
        self.title = title
        self.help = help
        self.recognizedIDs = recognizedIDs
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // A live binding would read the new selection on both sides.
        lhs.selectedID == rhs.selectedID
            && lhs.options == rhs.options
            && lhs.title == rhs.title
            && lhs.help == rhs.help
            && lhs.recognizedIDs == rhs.recognizedIDs
    }

    private func recognizable(_ option: LanguageOption) -> Bool {
        recognizedIDs?.contains(Locale(identifier: option.id).identifier(.bcp47)) == true
    }

    var body: some View {
        Picker(selection: Binding(get: { selectedID }, set: { select($0) })) {
            if recognizedIDs != nil {
                Section(L("settings.language.target.recognizedSection")) {
                    ForEach(options.filter { recognizable($0) }) {
                        Text($0.label).tag($0.id)
                    }
                }
                Section(L("settings.language.target.translationOnlySection")) {
                    ForEach(options.filter { !recognizable($0) }) {
                        Text($0.label).tag($0.id)
                    }
                }
            } else {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
        } label: { HelpLabel(title, help: help) }
    }
}
