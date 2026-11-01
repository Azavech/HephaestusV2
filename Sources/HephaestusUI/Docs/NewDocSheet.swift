// OWNER: ui-code-docs — the New Doc sheet (docs/documentation-viewer.md › New Doc).
import HephaestusCore
import SwiftUI

/// New Doc in `folder`.
struct NewDocSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    /// The folder the sheet was opened for, relative to the project root.
    let folder: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Untitled.md"
    @State private var selection: TextSelection?
    @State private var message: String?
    @State private var isCreating = false
    @State private var failure: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { ProjectPaths.isValidName(trimmed) }

    /// The name with `.md` appended when it does not end in `.md` or `.markdown`.
    private var fileName: String {
        ProjectPaths.isMarkdownName(trimmed) ? trimmed : trimmed + ".md"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Doc")
                .font(.headline)
            Text("In \(folder.isEmpty ? "/" : folder)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Name", text: $name, selection: $selection)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) {
                    message = nil
                }
            if let text = message ?? (isValid ? nil : "Use a name such as notes.md or guides/setup.md.") {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            selection = TextSelection(range: ProjectPaths.lastComponentSelection(in: name, withoutExtension: true))
        }
        // docs/documentation-viewer.md › New Doc, step 4.
        .alert("Create failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// `files.create`, then `files.write` of `# <base name>\n`; the new doc is selected and opens
    /// in Edit mode with the cursor at the end of the text.
    private func create() async {
        guard isValid, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        let path = ProjectPaths.join(folder, fileName)
        let text = "# \(ProjectPaths.baseName(ProjectPaths.name(of: fileName)))\n"
        let written: FileContent
        do {
            _ = try await workspace.call(FilesCreate.self, FilesCreate.Params(projectID: projectID, path: path, isDirectory: false))
            written = try await workspace.call(FilesWrite.self, FilesWrite.Params(projectID: projectID, path: path, text: text))
        } catch let error as EngineError where error.code == .conflict {
            message = "\(path) already exists."
            return
        } catch {
            failure = errorMessage(error)
            return
        }
        dismiss()
        let state = FileActions.viewState(window, projectID)
        if let current = state.docBuffer, current.isDirty, state.selectedDocPath != path {
            guard await UnsavedChangesPrompt.confirm([current], in: window) else { return }
        }
        let buffer = EditorBuffer(path: path, role: .doc)
        buffer.takeNewFile(text: written.text ?? text, modified: written.modified, workspace: workspace, projectID: projectID, window: window)
        buffer.pendingReveal = .end
        window.updateViewState(of: projectID) { state in
            state.docBuffer?.detach()
            state.docBuffer = buffer
            state.selectedDocPath = path
            state.docMode = .edit
        }
    }
}
