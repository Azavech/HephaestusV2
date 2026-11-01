// OWNER: ui-code-docs — the New File and New Folder sheets of the file tree (docs/code-editor.md › New File and New Folder).
import HephaestusCore
import SwiftUI

/// New File or New Folder in `folder`.
struct NewFileSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    /// The location, a project path; `""` for the root, shown as `/`.
    let folder: String
    let isFolder: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var edited = false
    @State private var message: String?
    @State private var isCreating = false
    @State private var failure: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { ProjectPaths.isValidName(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isFolder ? "New Folder" : "New File")
                .font(.headline)
            Text("In \(folder.isEmpty ? "/" : folder)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) {
                    edited = true
                    message = nil
                }
            if let text = message ?? (edited && !isValid ? "Use a name such as main.go or Sources/App.swift." : nil) {
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
        // docs/code-editor.md › New File and New Folder, step 2.
        .alert("Create failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// `files.create` with the location joined with the name; a new file opens in a new editor tab
    /// with an empty, clean buffer; a new folder is expanded and selected.
    private func create() async {
        guard isValid, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        let path = ProjectPaths.join(folder, trimmed)
        do {
            let entry = try await workspace.call(FilesCreate.self, FilesCreate.Params(projectID: projectID, path: path, isDirectory: isFolder))
            dismiss()
            if isFolder {
                window.updateViewState(of: projectID) { state in
                    state.expandedCodeFolders.formUnion(ProjectPaths.ancestors(of: path))
                    state.expandedCodeFolders.insert(path)
                    state.selectedTreePath = path
                }
            } else {
                var buffer: EditorBuffer?
                window.updateViewState(of: projectID) { state in
                    buffer = state.openEditorTab(path)
                }
                buffer?.takeNewFile(text: "", modified: entry.modified, workspace: workspace, projectID: projectID, window: window)
            }
        } catch let error as EngineError where error.code == .conflict {
            message = "\(path) already exists."
        } catch {
            failure = errorMessage(error)
        }
    }
}
