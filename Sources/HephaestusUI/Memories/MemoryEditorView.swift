// OWNER: ui-memories — the memory editor and the MEMORY.md editor: header, description, type,
// other frontmatter, body and footer; an inherited memory shows read-only (docs/memories.md ›
// Memory editor, › MEMORY.md editor).
import AppKit
import HephaestusCore
import SwiftUI

/// The editor of the selected memory (docs/memories.md › Memory editor); an inherited memory
/// shows read-only: its fields disabled, without Revert and Save, its body in Preview.
struct MemoryEditorView: View {
    let editor: MemoryEditorState
    @Bindable var form: MemoryForm
    let window: WindowState
    let workspace: DeviceWorkspace
    let scope: MemoryScope

    private var file: String {
        editor.selection
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if editor.conflict != nil {
                SkillBanner(text: "This memory was changed elsewhere.") {
                    Button("Reload") { editor.reloadConflict() }
                    Button("Keep Mine") { editor.keepMine() }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    descriptionPart
                    typePart
                    if !editor.extraFrontmatter.isEmpty {
                        otherFrontmatterPart
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        MemoryMarkdownEditor(editor: editor, buffer: form.body, workspace: workspace, title: "Body")
                            .frame(height: 340)
                    }
                }
                .padding(16)
            }
            Divider()
            MemoryFooter(target: editor.target, workspace: workspace, scope: scope)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("Name", text: $form.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .accessibilityLabel("Name")
                    .disabled(editor.isReadOnly)
                if !editor.isReadOnly {
                    Button("Revert") {
                        editor.revert()
                    }
                    .disabled(!form.hasUnsavedChanges || editor.isSaving)
                    Button("Save") {
                        Task { await editor.save() }
                    }
                    .disabled(!editor.canSave)
                }
            }
            if !editor.isReadOnly, let message = form.nameMessage(folder: workspace.memoryFolder(scope), file: file) {
                ValidationMessage(text: message)
            }
        }
    }

    // MARK: Description, type and other frontmatter

    private var descriptionPart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Description")
                .font(.headline)
            if editor.isReadOnly {
                // An inherited memory: the description shows dimmed and cannot be edited.
                ScrollView {
                    Text(form.description)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                }
                .padding(.vertical, 4)
                .frame(height: 66)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Description")
            } else {
                MultilineField(text: $form.description)
                    .frame(height: 66)
                    .accessibilityLabel("Description")
                if let message = form.descriptionMessage {
                    ValidationMessage(text: message)
                }
            }
        }
    }

    /// `User`, `Feedback`, `Project` and `Reference`; no segment is selected for an Other memory
    /// until the user chooses one.
    private var typePart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Type")
                .font(.headline)
            MemoryTypePicker(selection: $form.type)
                .disabled(editor.isReadOnly)
        }
    }

    /// Read-only, monospaced, the keys in YAML sorted by key, as in the Skills editor.
    private var otherFrontmatterPart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other frontmatter")
                .font(.headline)
            Text(SkillEditorView.yamlLines(editor.extraFrontmatter))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

/// The editor of `MEMORY.md`: the whole file in the Markdown editor, with Revert and Save
/// (docs/memories.md › MEMORY.md editor).
struct MemoryIndexEditorView: View {
    let editor: MemoryEditorState
    let workspace: DeviceWorkspace
    let scope: MemoryScope

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MemoryActions.indexFileName)
                    .font(.system(.title3, design: .monospaced))
                Spacer(minLength: 8)
                Button("Revert") {
                    editor.revert()
                }
                .disabled(!editor.hasUnsavedChanges || editor.isSaving)
                Button("Save") {
                    Task { await editor.save() }
                }
                .disabled(!editor.canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if editor.conflict != nil {
                SkillBanner(text: "MEMORY.md was changed elsewhere.") {
                    Button("Reload") { editor.reloadConflict() }
                    Button("Keep Mine") { editor.keepMine() }
                }
            }
            Divider()
            MemoryMarkdownEditor(editor: editor, buffer: editor.index, workspace: workspace, title: nil)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            MemoryFooter(target: .index, workspace: workspace, scope: scope)
        }
    }
}

/// The type picker of the editor and of the New Memory sheet: one segment per type, none
/// selected while the selection is nil.
struct MemoryTypePicker: View {
    @Binding var selection: MemoryType?

    var body: some View {
        Picker("Type", selection: $selection) {
            ForEach(MemoryType.allCases, id: \.self) { type in
                Text(MemoryGroups.title(of: type)).tag(Optional(type))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Type")
    }
}

/// The file's path, in the project's folder or in the inherited folder of its ancestor, home
/// folder written `~`; `Reveal in Finder` on This Mac only (docs/memories.md › Remote windows).
private struct MemoryFooter: View {
    let target: MemoryEditorState.Target
    let workspace: DeviceWorkspace
    let scope: MemoryScope

    var body: some View {
        HStack(spacing: 8) {
            Text(MemoryActions.displayPath(of: target, in: workspace, scope: scope))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if workspace.isLocal {
                Button("Reveal in Finder") {
                    MemoryActions.reveal(target, in: workspace, scope: scope)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }
}

/// A Markdown editor with the modes Edit, Preview and Split and the shared Markdown renderer
/// (docs/memories.md › Memory editor): the memory's body or `MEMORY.md`. An inherited memory
/// shows in Preview, its mode picker disabled, `memoryBodyMode` unchanged.
private struct MemoryMarkdownEditor: View {
    let editor: MemoryEditorState
    let buffer: EditorBuffer
    let workspace: DeviceWorkspace
    /// The heading over the mode picker; nil shows the picker alone.
    let title: String?

    /// The text rendered in Split mode, 200 ms after the last edit
    /// (docs/documentation-viewer.md › Modes).
    @State private var splitPreviewText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let title {
                    Text(title)
                        .font(.headline)
                }
                Spacer()
                Picker("Mode", selection: modeBinding) {
                    Text("Edit").tag(DocMode.edit)
                    Text("Preview").tag(DocMode.preview)
                    Text("Split").tag(DocMode.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(editor.isReadOnly)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .task(id: buffer.text) {
            guard mode == .split else {
                splitPreviewText = buffer.text
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled {
                splitPreviewText = buffer.text
            }
        }
    }

    /// The shown mode: Preview for an inherited memory, otherwise the editor's mode.
    private var mode: DocMode {
        editor.isReadOnly ? .preview : editor.bodyMode
    }

    private var modeBinding: Binding<DocMode> {
        Binding(get: { mode }, set: { newMode in
            if !editor.isReadOnly { editor.setBodyMode(newMode) }
        })
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .edit:
            textEditor
        case .preview:
            preview(buffer.text)
        case .split:
            // 50/50 at the start, each side at least 180 pt (docs/documentation-viewer.md › Modes).
            HSplitView {
                textEditor
                    .frame(minWidth: 180, idealWidth: 1000, maxWidth: .infinity)
                preview(splitPreviewText)
                    .frame(minWidth: 180, idealWidth: 1000, maxWidth: .infinity)
            }
        }
    }

    /// The code editor with Markdown highlighting; the New Memory sheet focuses it once.
    private var textEditor: some View {
        CodeEditorView(buffer: buffer, workspace: workspace)
            .goToLinePopover(isPresented: editor.goToLineBinding(for: buffer), host: buffer)
            .background(TextViewFocuser(isPending: editor.bodyFocusRequest > editor.handledBodyFocusRequest) {
                editor.handledBodyFocusRequest = editor.bodyFocusRequest
            })
    }

    /// The shared Markdown renderer, natively, with the options and the markers of the Skills
    /// editor, set by the Memories section: the ▶ of a sound marker plays the sound of the project,
    /// other links do nothing and project images show as blocked.
    private func preview(_ text: String) -> some View {
        ScrollView {
            MarkdownView(markdown: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
