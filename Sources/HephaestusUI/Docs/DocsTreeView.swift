// OWNER: ui-code-docs — the docs tree and its context menu (docs/documentation-viewer.md › Docs tree).
import AppKit
import HephaestusCore
import SwiftUI

/// The docs of the project's docs folder (`ProjectViewState.expandedDocFolders`) under the header
/// `Docs` and its `+` button (New Doc…).
struct DocsTreeView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        let tree = CodeDocsStore.shared.docsTree(window: window, workspace: workspace, projectID: projectID)
        let state = FileActions.viewState(window, projectID)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Docs")
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                // DOC-GAP: docs/documentation-viewer.md › New Doc does not name the folder of the `+`
                // button; it is the docs folder, as for the empty area.
                Button {
                    DocActions.newDoc(in: tree.docsPath, window: window, projectID: projectID)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Doc…")
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            Divider()
            if tree.docs == nil, tree.error == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OutlineTreeView(
                    rows: tree.rows(expanded: state.expandedDocFolders),
                    expanded: state.expandedDocFolders,
                    selection: tree.treeSelection ?? state.selectedDocPath,
                    onSelect: { path in
                        tree.treeSelection = path
                    },
                    onClick: { row in
                        if row.kind == .item {
                            open(row.id, tree: tree)
                        }
                    },
                    onDoubleClick: { row in
                        if row.kind == .folder {
                            window.updateViewState(of: projectID) { state in
                                if state.expandedDocFolders.contains(row.id) {
                                    state.expandedDocFolders.remove(row.id)
                                } else {
                                    state.expandedDocFolders.insert(row.id)
                                }
                            }
                        }
                    },
                    onReturn: { row in
                        if row.kind == .item {
                            open(row.id, tree: tree)
                        } else {
                            window.updateViewState(of: projectID) { state in
                                if state.expandedDocFolders.contains(row.id) {
                                    state.expandedDocFolders.remove(row.id)
                                } else {
                                    state.expandedDocFolders.insert(row.id)
                                }
                            }
                        }
                    },
                    onExpand: { path in
                        window.updateViewState(of: projectID) { $0.expandedDocFolders.insert(path) }
                    },
                    onCollapse: { path in
                        window.updateViewState(of: projectID) { $0.expandedDocFolders.remove(path) }
                    },
                    onDelete: { row in
                        trash(row, tree: tree)
                    },
                    menu: { row in menu(for: row, tree: tree) }
                )
            }
        }
        .onAppear {
            tree.ensureLoaded()
            expandFolders(above: state.selectedDocPath, tree: tree)
        }
        .onChange(of: state.selectedDocPath) { _, path in
            tree.treeSelection = nil
            expandFolders(above: path, tree: tree)
        }
    }

    /// Selecting a doc expands the folders above it.
    private func expandFolders(above path: String?, tree: DocsTreeModel) {
        guard let path else { return }
        let folders = tree.folders(above: path)
        let expanded = FileActions.viewState(window, projectID).expandedDocFolders
        if !folders.isEmpty, !expanded.isSuperset(of: folders) {
            window.updateViewState(of: projectID) { $0.expandedDocFolders.formUnion(folders) }
        }
    }

    /// Opens a doc; Cancel of the unsaved changes alert keeps the current doc selected.
    private func open(_ path: String, tree: DocsTreeModel) {
        Task {
            if !(await DocActions.select(path, window: window, projectID: projectID)) {
                tree.treeSelection = nil
            }
        }
    }

    private func trash(_ row: OutlineRow, tree: DocsTreeModel) {
        guard row.kind != .message else { return }
        Task {
            await DocActions.moveToTrash(row.id, isFolder: row.kind == .folder, tree: tree, window: window,
                                         workspace: workspace, projectID: projectID)
        }
    }

    /// The context menu (docs/documentation-viewer.md › Docs tree, Context menu).
    private func menu(for row: OutlineRow?, tree: DocsTreeModel) -> [OutlineMenuItem] {
        guard let row else {
            return [OutlineMenuItem(title: "New Doc…") {
                DocActions.newDoc(in: tree.docsPath, window: window, projectID: projectID)
            }]
        }
        var items: [OutlineMenuItem] = []
        if row.kind == .folder {
            items.append(OutlineMenuItem(title: "New Doc…") {
                DocActions.newDoc(in: row.id, window: window, projectID: projectID)
            })
            items.append(.separator)
        }
        items.append(OutlineMenuItem(title: "Rename…") {
            window.sheet = .renameDoc(projectID: projectID, path: row.id)
        })
        items.append(OutlineMenuItem(title: "Move to Trash…") { trash(row, tree: tree) })
        if workspace.isLocal {
            items.append(.separator)
            items.append(OutlineMenuItem(title: "Show in Finder") {
                FileActions.showInFinder(row.id, workspace: workspace, projectID: projectID)
            })
        }
        return items
    }
}

/// Actions of the Docs section: selecting a doc, New Doc, renames and Move to Trash
/// (docs/documentation-viewer.md › Opening a doc, › New Doc, › Rename, › Move to Trash).
@MainActor
enum DocActions {
    /// Selects a doc; with unsaved changes in the shown doc, the unsaved changes alert comes
    /// first and Cancel keeps the current doc selected. Returns false on Cancel.
    @discardableResult
    static func select(_ path: String, window: WindowState, projectID: String) async -> Bool {
        let state = FileActions.viewState(window, projectID)
        guard state.selectedDocPath != path else { return true }
        if let buffer = state.docBuffer, buffer.isDirty {
            guard await UnsavedChangesPrompt.confirm([buffer], in: window) else { return false }
        }
        window.updateViewState(of: projectID) { $0.selectedDocPath = path }
        return true
    }

    static func newDoc(in folder: String, window: WindowState, projectID: String) {
        window.sheet = .newDoc(projectID: projectID, folder: folder)
    }

    /// Move to Trash… asks, then calls `files.trash`. When the open doc is moved to the Trash, its
    /// buffer is discarded and the selection is cleared.
    static func moveToTrash(_ path: String, isFolder: Bool, tree: DocsTreeModel, window: WindowState, workspace: DeviceWorkspace,
                            projectID: String) async {
        let name = ProjectPaths.name(of: path)
        let state = FileActions.viewState(window, projectID)
        let alert = NSAlert()
        if isFolder {
            let count = tree.docCount(under: path)
            alert.messageText = "Move the folder “\(name)” to the Trash?"
            // DOC-GAP: docs/documentation-viewer.md › Move to Trash writes `Its <n> docs`; with one
            // doc it reads `Its 1 doc`, as the other counted texts of the docs do.
            let docs = count == 1 ? "1 doc" : "\(count) docs"
            alert.informativeText = "Its \(docs) and every other file in it are moved to the Trash of \(workspace.deviceName)."
        } else {
            alert.messageText = "Move “\(name)” to the Trash?"
            var text = "It can be restored from the Trash of \(workspace.deviceName)."
            if let buffer = state.docBuffer, buffer.path == path, buffer.isDirty {
                text += " Unsaved changes will be lost."
            }
            alert.informativeText = text
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let nsWindow = window.app?.windowRegistry.window(forMain: window.id)
        guard await AlertPresenter.present(alert, on: nsWindow) == .alertFirstButtonReturn else { return }
        let buffer = state.docBuffer.flatMap { ProjectPaths.isSameOrDescendant($0.path, of: path) ? $0 : nil }
        buffer?.holdChecks()
        do {
            _ = try await workspace.call(FilesTrash.self, FilesTrash.Params(projectID: projectID, path: path))
            window.updateViewState(of: projectID) { state in
                if let selected = state.selectedDocPath, ProjectPaths.isSameOrDescendant(selected, of: path) {
                    state.docBuffer?.detach()
                    state.docBuffer = nil
                    state.selectedDocPath = nil
                }
            }
            if let selection = tree.treeSelection, ProjectPaths.isSameOrDescendant(selection, of: path) {
                tree.treeSelection = nil
            }
        } catch {
            // DOC-GAP: docs/documentation-viewer.md › Move to Trash gives no failure text; the alert
            // of docs/ui.md › Principles names the button pressed, `Move to Trash failed`.
            window.alert = .failure("Move to Trash", error)
        }
        buffer?.releaseChecks()
    }

    /// After a rename, the open doc's buffer, `selectedDocPath` and `expandedDocFolders` follow the
    /// new path, unsaved changes included.
    static func rename(_ path: String, to newPath: String, window: WindowState, workspace: DeviceWorkspace, projectID: String) async throws {
        let buffer = FileActions.viewState(window, projectID).docBuffer
        let affected = buffer.flatMap { ProjectPaths.isSameOrDescendant($0.path, of: path) ? $0 : nil }
        affected?.holdChecks()
        defer { affected?.releaseChecks() }
        _ = try await workspace.call(FilesRename.self, FilesRename.Params(projectID: projectID, path: path, newPath: newPath))
        window.updateViewState(of: projectID) { state in
            if let buffer = state.docBuffer, let moved = ProjectPaths.renamed(buffer.path, from: path, to: newPath) {
                buffer.move(to: moved)
            }
            if let selected = state.selectedDocPath, let moved = ProjectPaths.renamed(selected, from: path, to: newPath) {
                state.selectedDocPath = moved
            }
            state.expandedDocFolders = Set(state.expandedDocFolders.map { ProjectPaths.renamed($0, from: path, to: newPath) ?? $0 })
        }
    }
}
