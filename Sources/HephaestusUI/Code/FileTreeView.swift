// OWNER: ui-code-docs — the file tree and its context menu (docs/code-editor.md › Layout, › File tree).
import HephaestusCore
import SwiftUI

/// The file tree of the active project (`ProjectViewState.expandedCodeFolders`, `selectedTreePath`)
/// under its header: the project name and a `+` button with New File… and New Folder….
struct FileTreeView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        let tree = CodeDocsStore.shared.fileTree(window: window, workspace: workspace, projectID: projectID)
        let state = FileActions.viewState(window, projectID)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(workspace.project(projectID)?.name ?? projectID)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Menu {
                    Button("New File…") { newItem(isFolder: false, in: selectionLocation(tree, state)) }
                    Button("New Folder…") { newItem(isFolder: true, in: selectionLocation(tree, state)) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider()
            content(tree, state)
        }
        .onAppear {
            tree.ensureListed("")
            for folder in tree.visibleExpandedFolders(state.expandedCodeFolders) {
                tree.ensureListed(folder)
            }
        }
        .onChange(of: state.expandedCodeFolders) { _, expanded in
            for folder in tree.visibleExpandedFolders(expanded) {
                tree.ensureListed(folder)
            }
        }
    }

    @ViewBuilder
    private func content(_ tree: FileTreeModel, _ state: ProjectViewState) -> some View {
        if let error = tree.errors[""] {
            // docs/code-editor.md › File tree, Failed root
            VStack(spacing: 8) {
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { tree.retry("") }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let root = tree.listings[""] {
            if root.isEmpty {
                VStack(spacing: 8) {
                    Text("This folder is empty.")
                        .foregroundStyle(.secondary)
                    Button("New File…") { newItem(isFolder: false, in: "") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu {
                    Button("New File…") { newItem(isFolder: false, in: "") }
                    Button("New Folder…") { newItem(isFolder: true, in: "") }
                }
            } else {
                OutlineTreeView(
                    rows: tree.rows(of: "", expanded: state.expandedCodeFolders),
                    expanded: state.expandedCodeFolders,
                    selection: state.selectedTreePath,
                    onSelect: { path in
                        window.updateViewState(of: projectID) { $0.selectedTreePath = path }
                    },
                    onClick: { row in
                        if row.kind == .item {
                            FileActions.openFile(row.id, window: window, workspace: workspace, projectID: projectID)
                        }
                    },
                    onDoubleClick: { row in
                        if row.kind == .folder {
                            toggle(row.id, tree)
                        }
                    },
                    onReturn: { row in
                        if row.kind == .folder {
                            toggle(row.id, tree)
                        } else {
                            FileActions.openFile(row.id, window: window, workspace: workspace, projectID: projectID)
                        }
                    },
                    onExpand: { path in
                        window.updateViewState(of: projectID) { $0.expandedCodeFolders.insert(path) }
                        tree.ensureListed(path)
                    },
                    onCollapse: { path in
                        window.updateViewState(of: projectID) { $0.expandedCodeFolders.remove(path) }
                    },
                    onDelete: { row in
                        trash(row)
                    },
                    menu: { row in menu(for: row) }
                )
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The location of New File and New Folder: the selected folder, the folder of the selected
    /// file, or the root when nothing is selected.
    private func selectionLocation(_ tree: FileTreeModel, _ state: ProjectViewState) -> String {
        guard let selected = state.selectedTreePath else { return "" }
        if tree.entry(at: selected)?.isDirectory == true || tree.isListed(selected) {
            return selected
        }
        return ProjectPaths.parent(of: selected)
    }

    private func newItem(isFolder: Bool, in folder: String) {
        window.sheet = .newFile(projectID: projectID, folder: folder, isFolder: isFolder)
    }

    private func toggle(_ path: String, _ tree: FileTreeModel) {
        var expanding = false
        window.updateViewState(of: projectID) { state in
            if state.expandedCodeFolders.contains(path) {
                state.expandedCodeFolders.remove(path)
            } else {
                state.expandedCodeFolders.insert(path)
                expanding = true
            }
        }
        if expanding {
            tree.ensureListed(path)
        }
    }

    private func trash(_ row: OutlineRow) {
        guard row.kind != .message else { return }
        Task {
            await FileActions.moveToTrash(row.id, isFolder: row.kind == .folder, window: window, workspace: workspace,
                                          projectID: projectID)
        }
    }

    /// The context menu of a row or of the empty area (docs/code-editor.md › Context menu). New
    /// File and New Folder take their location from the row the menu was opened on, or the root
    /// for the empty area (docs/code-editor.md › New File and New Folder).
    private func menu(for row: OutlineRow?) -> [OutlineMenuItem] {
        let location: String
        if let row {
            location = row.kind == .folder ? row.id : ProjectPaths.parent(of: row.id)
        } else {
            location = ""
        }
        var items = [
            OutlineMenuItem(title: "New File…") { newItem(isFolder: false, in: location) },
            OutlineMenuItem(title: "New Folder…") { newItem(isFolder: true, in: location) },
        ]
        guard let row else { return items }
        items += [
            .separator,
            OutlineMenuItem(title: "Rename…") {
                window.sheet = .renameFile(projectID: projectID, path: row.id)
            },
            OutlineMenuItem(title: "Move to Trash…") { trash(row) },
            .separator,
            OutlineMenuItem(title: "Copy Path") { FileActions.copyPath(row.id) },
        ]
        if workspace.isLocal {
            items.append(OutlineMenuItem(title: "Show in Finder") {
                FileActions.showInFinder(row.id, workspace: workspace, projectID: projectID)
            })
        }
        return items
    }
}
