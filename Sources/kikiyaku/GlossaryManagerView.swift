import AppKit
import SwiftUI

struct GlossaryManagerView: View {
    let store: SessionProfileStore
    let dismiss: () -> Void

    @State private var selection: UUID?
    @State private var editor: Editor?

    private struct Editor {
        let glossary: Glossary
        let isNew: Bool
    }

    private var selected: Glossary? {
        selection.flatMap { store.glossary(id: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = store.glossaryNotice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("glossaries.dismissNotice")) { store.dismissGlossaryNotice() }
                        .controlSize(.small)
                }
            }
            if let editor {
                GlossaryEditorView(store: store, glossary: editor.glossary, isNew: editor.isNew) { id in
                    if let id { selection = id }
                    self.editor = nil
                }
                .id(editor.glossary.id)
            } else {
                Text(L("glossaries.title")).font(.headline)
                if store.glossaries.isEmpty {
                    Text(L("glossaries.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    List(selection: $selection) {
                        ForEach(store.glossaries) { glossary in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(glossary.name)
                                Text(usage(glossary.id))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(glossary.id)
                        }
                    }
                    .frame(height: 240)
                    .accessibilityLabel(Text(L("glossaries.title")))
                }
                HStack {
                    Button(L("glossaries.new")) {
                        editor = Editor(glossary: Glossary(id: UUID(), name: "", text: ""), isNew: true)
                    }
                    Button(L("glossaries.edit")) {
                        if let selected { editor = Editor(glossary: selected, isNew: false) }
                    }
                    .disabled(selected == nil)
                    Button(L("glossaries.delete")) { deleteSelected() }
                        .disabled(selected.map { !store.profilesUsingGlossary($0.id).isEmpty } ?? true)
                        .help(selection.map(usage) ?? L("glossaries.selectHint"))
                    Spacer()
                    Button(L("glossaries.close"), action: dismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func usage(_ id: UUID) -> String {
        let names = store.profilesUsingGlossary(id).map(\.name)
        return names.isEmpty ? L("glossaries.unused") : LF("glossaries.usedBy", names.joined(separator: ", "))
    }

    private func deleteSelected() {
        guard let selected else { return }
        let alert = NSAlert()
        alert.messageText = LF("glossaries.deleteTitle", selected.name)
        alert.informativeText = L("glossaries.deleteMessage")
        alert.addButton(withTitle: L("glossaries.delete"))
        alert.addButton(withTitle: L("settings.cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.deleteGlossary(selected.id)
            selection = nil
        } catch {
            showStoreError(error)
        }
    }
}

struct GlossaryEditorView: View {
    let store: SessionProfileStore
    let isNew: Bool
    let finish: (UUID?) -> Void

    @State private var draft: Glossary
    @State private var height: CGFloat = 160
    @GestureState private var resizeTranslation: CGFloat = 0

    init(store: SessionProfileStore, glossary: Glossary, isNew: Bool,
         finish: @escaping (UUID?) -> Void) {
        self.store = store
        self.isNew = isNew
        self.finish = finish
        _draft = State(initialValue: glossary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? L("glossaries.newTitle") : L("glossaries.editTitle")).font(.headline)
            TextField(L("glossaries.name"), text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Text(L("glossaries.sharedCaption"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isNew {
                let users = store.profilesUsingGlossary(draft.id).map(\.name)
                Text(users.isEmpty ? L("glossaries.unused") : LF("glossaries.usedBy", users.joined(separator: ", ")))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            TextEditor(text: $draft.text)
                .font(.system(size: 12, design: .monospaced))
                .contentMargins(.bottom, 18, for: .scrollIndicators)
                .frame(height: clampedHeight(height + resizeTranslation))
                .autocorrectionDisabled()
                .accessibilityLabel(Text(L("settings.glossary")))
                .help(L("settings.glossaryCaption"))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text(L("settings.glossaryPlaceholder"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .padding(5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .overlay(alignment: .bottomTrailing) { resizeHandle.padding(2) }
            Text(L("settings.glossaryFormat"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("settings.cancel")) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L("glossaries.add") : L("settings.profiles.save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var resizeHandle: some View {
        Path { path in
            for offset in stride(from: 3, through: 7, by: 4) {
                path.move(to: CGPoint(x: CGFloat(offset), y: 11))
                path.addLine(to: CGPoint(x: 11, y: CGFloat(offset)))
            }
        }
        .stroke(.secondary, lineWidth: 1)
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: .bottom))
        .help(L("settings.glossaryResize"))
        .gesture(
            DragGesture(coordinateSpace: .global)
                .updating($resizeTranslation) { value, translation, _ in
                    translation = value.translation.height
                }
                .onEnded { value in height = clampedHeight(height + value.translation.height) }
        )
        .accessibilityLabel(Text(L("settings.glossaryResize")))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: height = clampedHeight(height + 20)
            case .decrement: height = clampedHeight(height - 20)
            @unknown default: break
            }
        }
    }

    private func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(240, max(80, height))
    }

    private func save() {
        do {
            if isNew {
                finish(try store.addGlossary(name: draft.name, text: draft.text))
            } else {
                try store.updateGlossary(draft)
                finish(draft.id)
            }
        } catch {
            showStoreError(error)
        }
    }
}

struct ProfileCatalogRecoveryView: View {
    let store: SessionProfileStore
    @State private var backupPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("profiles.recovery.title")).font(.headline)
            if let error = store.loadError { Text(error.message) }
            Text(L("profiles.recovery.explanation"))
                .font(.callout)
            Button(L("profiles.recovery.backup")) { backUp() }
            if let backupPath {
                Text(LF("profiles.recovery.backedUp", backupPath))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Text(L("profiles.recovery.lossWarning"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L("profiles.recovery.restore")) { restore() }
                .disabled(!store.hasRecoveryBackup || AppState.shared.phase != .idle)
        }
        .padding(20)
        .frame(width: 560)
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kikiyaku-profile-backup.plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.backUpCatalog(to: url)
            backupPath = url.path
        } catch {
            showStoreError(error)
        }
    }

    private func restore() {
        let alert = NSAlert()
        alert.messageText = L("profiles.recovery.restore")
        alert.informativeText = L("profiles.recovery.lossWarning")
        alert.addButton(withTitle: L("profiles.recovery.restore"))
        alert.addButton(withTitle: L("settings.cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.restoreLegacyAfterBackup()
        } catch {
            showStoreError(error)
        }
    }
}

@MainActor
private func showStoreError(_ error: ProfileError) {
    let alert = NSAlert()
    alert.messageText = L("profiles.error.title")
    alert.informativeText = error.message
    alert.runModal()
}
