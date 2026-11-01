// OWNER: ui-code-docs — the Rename sheet of the file tree (docs/code-editor.md › Rename).
import HephaestusCore
import SwiftUI

/// Rename or move a file or folder: one field holding the item's project path with its last
/// component selected (without the extension for a file).
struct RenameFileSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var message: String?
    @State private var isRenaming = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { ProjectPaths.isValidName(trimmed) }

    private var isFolder: Bool {
        let tree = CodeDocsStore.shared.fileTree(window: window, workspace: workspace, projectID: projectID)
        return tree.entry(at: path)?.isDirectory ?? tree.isListed(path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename “\(ProjectPaths.name(of: path))”")
                .font(.headline)
            TextField("", text: $text, selection: $selection)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) {
                    message = nil
                }
            if let error = message ?? (isValid ? nil : "Use a name such as main.go or Sources/App.swift.") {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    Task { await rename() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isRenaming)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            text = path
            selection = TextSelection(range: ProjectPaths.lastComponentSelection(in: path, withoutExtension: !isFolder))
        }
    }

    /// `files.rename`; `conflict` shows `<path> already exists.` and `forbidden` the engine's
    /// message under the field.
    private func rename() async {
        guard isValid, !isRenaming else { return }
        let newPath = trimmed
        guard newPath != path else {
            dismiss()
            return
        }
        isRenaming = true
        defer { isRenaming = false }
        do {
            try await FileActions.rename(path, to: newPath, window: window, workspace: workspace, projectID: projectID)
            dismiss()
        } catch let error as EngineError where error.code == .conflict {
            message = "\(newPath) already exists."
        } catch {
            message = errorMessage(error)
        }
    }
}
