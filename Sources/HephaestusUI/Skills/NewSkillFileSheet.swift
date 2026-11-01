// OWNER: ui-skills-feedback — the New File sheet of a skill's extra files (docs/skills.md › Editor).
import HephaestusCore
import SwiftUI

/// A new extra file of a skill: a `Path` field (a relative path such as `templates/changelog.md`);
/// Create calls `skills.writeFile` with an empty text and selects the new file; path errors appear
/// under the field (docs/skills.md › Editor).
struct NewSkillFileSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let skillName: String
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var isCreating = false
    /// A path error, under the field.
    @State private var failure: String?
    @FocusState private var pathFocused: Bool

    /// The editor of the skill in the window's active project.
    private var editor: SkillEditorState? {
        guard let editor = window.viewState.skillEditor, editor.skillName == skillName else { return nil }
        return editor
    }

    /// The path as the engine reads it: trimmed, without a trailing `/`.
    private var normalizedPath: String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private var canCreate: Bool {
        !normalizedPath.isEmpty && !isCreating && workspace.isConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New File")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Path")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("templates/changelog.md", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($pathFocused)
                        .accessibilityLabel("Path")
                    if let failure {
                        ValidationMessage(text: failure)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 440)
        .disabled(isCreating)
        .onChange(of: path) {
            failure = nil
        }
        .onAppear {
            pathFocused = true
        }
    }

    private func create() {
        guard canCreate else { return }
        let path = normalizedPath
        // DOC-GAP: docs/skills.md › Editor does not say what Create does with the path of an
        // existing file, which `skills.writeFile` would empty; the sheet refuses it with the text of
        // docs/code-editor.md › New File and New Folder.
        if let files = editor?.files, files.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
            failure = "\(path) already exists."
            return
        }
        isCreating = true
        failure = nil
        Task {
            do {
                _ = try await workspace.call(SkillsWriteFile.self, .init(name: skillName, path: path, text: ""))
            } catch {
                failure = errorMessage(error)
                isCreating = false
                return
            }
            let editor = editor
            dismiss()
            guard let editor else { return }
            await editor.refresh()
            await editor.openFile(path)
        }
    }
}
