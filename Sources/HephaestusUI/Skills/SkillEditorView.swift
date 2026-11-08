// OWNER: ui-skills-feedback — the skill editor: header, description, other frontmatter, body,
// extra files and footer (docs/skills.md › Editor, › Saving, › Remote windows).
import AppKit
import HephaestusCore
import SwiftUI

/// The editor of the selected skill (docs/skills.md › Editor).
struct SkillEditorView: View {
    let editor: SkillEditorState
    @Bindable var form: SkillForm
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    /// The value of the Enabled toggle while `skills.setEnabled` runs and until the project's
    /// `project.updated` shows it.
    @State private var pendingEnabled: Bool?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .paneHeaderBar()
            Divider()
            underHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            if editor.conflict != nil {
                SkillBanner(text: "This skill was changed elsewhere.") {
                    Button("Reload") { editor.reloadConflict() }
                    Button("Keep Mine") { editor.keepMine() }
                }
            }
            if form.savedDescription.isEmpty {
                SkillBanner(text: "This skill has no description. Claude uses the description to decide when to use the skill.") {
                    EmptyView()
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    descriptionPart
                    if !editor.extraFrontmatter.isEmpty {
                        otherFrontmatterPart
                    }
                    SkillBodyPart(editor: editor, form: form, workspace: workspace)
                    SkillFilesPart(editor: editor, window: window, workspace: workspace)
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    // MARK: Header

    private var projectName: String {
        workspace.project(projectID)?.name ?? projectID
    }

    /// The editor's pane header (docs/ui.md › Pane headers): the Name field, disabled for an
    /// internal skill, Restore Default for an internal skill, Revert and Save.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Name", text: $form.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .accessibilityLabel("Name")
                .disabled(editor.isInternal)
            // The buttons keep their whole labels; the Name field takes the width left.
            if editor.isInternal {
                Button("Restore Default") {
                    Task { await editor.restoreDefault() }
                }
                .fixedSize()
                .disabled(editor.isSaving)
            }
            Button("Revert") {
                editor.revert()
            }
            .fixedSize()
            .disabled(!form.hasUnsavedChanges || editor.isSaving)
            Button("Save") {
                Task { await editor.save() }
            }
            .fixedSize()
            .disabled(!editor.canSave)
        }
    }

    /// The row just under the header's separator: the name's validation message, the caption and
    /// the Enabled toggle, which do not fit on the header's row.
    private var underHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = form.nameMessage(library: workspace.skills) {
                ValidationMessage(text: message)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Claude sees this skill as hephaestus-skills:\(editor.skillName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                // An internal skill is always enabled: its toggle is on and cannot be turned off
                // (docs/skills.md › Internal skills).
                Toggle("Enabled in \(projectName)", isOn: editor.isInternal ? .constant(true) : enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(editor.isInternal)
            }
        }
        .onChange(of: isEnabledInProject) { _, enabled in
            if pendingEnabled == enabled {
                pendingEnabled = nil
            }
        }
    }

    /// Whether the saved name is in the active project's `skills`.
    private var isEnabledInProject: Bool {
        workspace.details[projectID]?.project.skills.contains(editor.skillName) ?? false
    }

    /// `Enabled in <project name>` applies at once through `skills.setEnabled`, using the saved
    /// name (docs/skills.md › Editor).
    private var enabledBinding: Binding<Bool> {
        Binding(get: { pendingEnabled ?? isEnabledInProject }, set: { enabled in
            let name = editor.skillName
            pendingEnabled = enabled
            Task {
                do {
                    _ = try await workspace.call(SkillsSetEnabled.self, .init(projectID: projectID, name: name, enabled: enabled))
                    if isEnabledInProject == enabled {
                        pendingEnabled = nil
                    }
                } catch {
                    pendingEnabled = nil
                    window.alert = .failure("Enabled in \(projectName)", error)
                }
            }
        })
    }

    // MARK: Description and other frontmatter

    private var descriptionPart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Description")
                .font(.headline)
            MultilineField(text: $form.description)
                .frame(height: 66)
                .accessibilityLabel("Description")
            HStack(alignment: .firstTextBaseline) {
                if let message = form.descriptionMessage {
                    ValidationMessage(text: message)
                }
                Spacer()
                Text(SkillValidation.counter(form.description))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(form.description.count > SkillValidation.descriptionLimit ? Color.red : Color.secondary)
            }
        }
    }

    /// Read-only, monospaced, one `key: value` line per key in YAML, sorted by key.
    private var otherFrontmatterPart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other frontmatter")
                .font(.headline)
            Text(Self.yamlLines(editor.extraFrontmatter))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    /// Each key as the engine writes it in the frontmatter.
    static func yamlLines(_ frontmatter: [String: JSONValue]) -> String {
        frontmatter.keys.sorted().map { key in
            let value = frontmatter[key] ?? .null
            if let yaml = try? YAMLCoding.encode([key: value]) {
                var text = yaml
                while text.hasSuffix("\n") {
                    text.removeLast()
                }
                return text
            }
            return "\(key): \(value)"
        }
        .joined(separator: "\n")
    }

    // MARK: Footer

    /// The skill folder path, home folder written `~`; `Reveal in Finder` on This Mac only
    /// (docs/skills.md › Remote windows).
    private var footer: some View {
        HStack(spacing: 8) {
            Text(SkillLibraryLocation.displayPath(of: editor.skillName, in: workspace))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if workspace.isLocal {
                Button("Reveal in Finder") {
                    guard let library = SkillLibraryLocation.localURL(of: workspace) else { return }
                    let folder = library.appendingPathComponent(editor.skillName, isDirectory: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }
}

// MARK: - Body

/// The body: a Markdown editor with the modes Edit, Preview and Split (docs/skills.md › Editor).
private struct SkillBodyPart: View {
    let editor: SkillEditorState
    let form: SkillForm
    let workspace: DeviceWorkspace

    /// The text rendered in Split mode, 200 ms after the last edit
    /// (docs/documentation-viewer.md › Modes).
    @State private var splitPreviewText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Body")
                    .font(.headline)
                Spacer()
                Picker("Mode", selection: modeBinding) {
                    Text("Edit").tag(DocMode.edit)
                    Text("Preview").tag(DocMode.preview)
                    Text("Split").tag(DocMode.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            content
                .frame(height: 340)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .task(id: form.body.text) {
            guard editor.bodyMode == .split else {
                splitPreviewText = form.body.text
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled {
                splitPreviewText = form.body.text
            }
        }
    }

    private var modeBinding: Binding<DocMode> {
        Binding(get: { editor.bodyMode }, set: { editor.bodyMode = $0 })
    }

    @ViewBuilder
    private var content: some View {
        switch editor.bodyMode {
        case .edit:
            bodyEditor
        case .preview:
            preview(form.body.text)
        case .split:
            // 50/50 at the start, each side at least 180 pt (docs/documentation-viewer.md › Modes).
            HSplitView {
                bodyEditor
                    .frame(minWidth: 180, idealWidth: 1000, maxWidth: .infinity)
                preview(splitPreviewText)
                    .frame(minWidth: 180, idealWidth: 1000, maxWidth: .infinity)
            }
        }
    }

    /// The code editor with Markdown highlighting and the placeholder
    /// `Instructions Claude follows when it uses this skill (Markdown).`
    private var bodyEditor: some View {
        CodeEditorView(buffer: form.body, workspace: workspace)
            .goToLinePopover(isPresented: editor.goToLineBinding(for: form.body), host: form.body)
            .overlay(alignment: .topLeading) {
                if form.body.text.isEmpty {
                    Text("Instructions Claude follows when it uses this skill (Markdown).")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 48)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(TextViewFocuser(isPending: editor.bodyFocusRequest > editor.handledBodyFocusRequest) {
                editor.handledBodyFocusRequest = editor.bodyFocusRequest
            })
    }

    /// The shared Markdown renderer, natively, with the default options and context: links do
    /// nothing and project images show as blocked (docs/skills.md › Editor).
    private func preview(_ text: String) -> some View {
        ScrollView {
            MarkdownView(markdown: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Extra files

/// The extra files with `+` (New File…) and `−` (Move to Trash…); the selected file opens under the
/// list (docs/skills.md › Editor, Extra file view).
private struct SkillFilesPart: View {
    let editor: SkillEditorState
    let window: WindowState
    let workspace: DeviceWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files")
                .font(.headline)
            VStack(spacing: 0) {
                List(selection: selection) {
                    ForEach(editor.files, id: \.self) { path in
                        Text(path)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(path)
                    }
                }
                .listStyle(.inset)
                .frame(height: 112)
                Divider()
                HStack(spacing: 2) {
                    Button {
                        window.sheet = .newSkillFile(skillName: editor.skillName)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 20)
                    }
                    .help("New File…")
                    .accessibilityLabel("New File…")
                    Button {
                        guard let path = editor.file?.path else { return }
                        Task {
                            await SkillActions.trashFile(path, of: editor, window: window, workspace: workspace)
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 22, height: 20)
                    }
                    .help("Move to Trash…")
                    .accessibilityLabel("Move to Trash…")
                    .disabled(editor.file == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
                .frame(height: 26)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            if let file = editor.file {
                SkillFileView(file: file, editor: editor, workspace: workspace)
                    .frame(height: 320)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { editor.file?.path }, set: { path in
            Task {
                await editor.openFile(path)
            }
        })
    }
}

/// The view of the open extra file: the code editor for text, the image scaled to fit, or
/// `Binary file · <size>`.
private struct SkillFileView: View {
    let file: SkillExtraFile
    let editor: SkillEditorState
    let workspace: DeviceWorkspace

    var body: some View {
        switch file.kind {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            CodeEditorView(buffer: file.buffer, workspace: workspace)
                .goToLinePopover(isPresented: editor.goToLineBinding(for: file.buffer), host: file.buffer)
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                notice("Binary file · \(Self.size(data.count))")
            }
        case .binary(let size):
            notice("Binary file · \(Self.size(size))")
        case .failed(let message):
            // The code editor's error row (docs/skills.md › Editor, Extra file view).
            VStack(spacing: 8) {
                Text("The file could not be opened.")
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await editor.loadFile(file) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Shared pieces

/// A 32-point banner with the system yellow at 18 % opacity, as the editor's disk banners
/// (docs/code-editor.md › Banners).
struct SkillBanner<Buttons: View>: View {
    let text: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(text)
                .lineLimit(2)
            Spacer(minLength: 8)
            buttons()
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 32)
        .background(Color.yellow.opacity(0.18))
    }
}

/// A field validation message, in red under its field.
struct ValidationMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A multi-line text field that wraps: Return inserts a line break.
struct MultilineField: View {
    @Binding var text: String
    /// The keyboard focus of the field, when its owner sets it.
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        Group {
            if let focus {
                TextEditor(text: $text)
                    .focused(focus)
            } else {
                TextEditor(text: $text)
            }
        }
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
