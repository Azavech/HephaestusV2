// OWNER: ui-code-docs — the Rename sheet of the docs tree (docs/documentation-viewer.md › Rename).
import HephaestusCore
import SwiftUI

/// Rename a doc or a folder of the docs tree: one field holding the item's path relative to the
/// docs folder (for a doc, the part before the extension selected).
struct RenameDocSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var message: String?
    @State private var isRenaming = false

    private var tree: DocsTreeModel {
        CodeDocsStore.shared.docsTree(window: window, workspace: workspace, projectID: projectID)
    }

    private var isFolder: Bool {
        tree.folderPaths.contains(path)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { ProjectPaths.isValidName(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename “\(ProjectPaths.name(of: path))”")
                .font(.headline)
            TextField("", text: $text, selection: $selection)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) {
                    message = nil
                }
            if let error = message ?? (isValid ? nil : "Use a name such as notes.md or guides/setup.md.") {
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
            let relative = tree.relativePath(path)
            text = relative
            selection = TextSelection(range: ProjectPaths.lastComponentSelection(in: relative, withoutExtension: !isFolder))
        }
    }

    /// `files.rename` with the old and new project paths; for a doc, `.md` is appended when the
    /// new name has no Markdown extension.
    private func rename() async {
        guard isValid, !isRenaming else { return }
        var relative = trimmed
        if !isFolder, !ProjectPaths.isMarkdownName(relative) {
            relative += ".md"
        }
        let newPath = ProjectPaths.join(tree.docsPath, relative)
        guard newPath != path else {
            dismiss()
            return
        }
        isRenaming = true
        defer { isRenaming = false }
        do {
            try await DocActions.rename(path, to: newPath, window: window, workspace: workspace, projectID: projectID)
            dismiss()
        } catch let error as EngineError where error.code == .conflict {
            message = "\(newPath) already exists."
        } catch {
            message = errorMessage(error)
        }
    }
}
