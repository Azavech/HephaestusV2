// OWNER: ui-code-docs — the Code section: file tree, editor tabs and editor (docs/code-editor.md › Layout).
import AppKit
import HephaestusCore
import SwiftUI

/// The Code section of the active project; its tabs are `ProjectViewState.editorTabs`. It sets its
/// `CodeSectionCommands` as `WindowState.sectionCommands`.
struct CodeSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        let commands = CodeSectionCommands.of(window: window, workspace: workspace, projectID: projectID)
        let state = FileActions.viewState(window, projectID)
        @Bindable var layout = CodeDocsStore.shared.entry(window: window, projectID: projectID).layout
        SplitPanes(leadingWidth: $layout.codeTreeWidth, leadingRange: 180...480, minimumTrailingWidth: 300) {
            FileTreeView(window: window, workspace: workspace, projectID: projectID)
        } trailing: {
            EditorArea(window: window, workspace: workspace, projectID: projectID, commands: commands)
        }
        .onAppear {
            window.sectionCommands = commands
            loadTabs(state)
        }
        .onDisappear {
            if window.sectionCommands === commands {
                window.sectionCommands = nil
            }
        }
        .onChange(of: state.editorTabs.map(\.path)) {
            loadTabs(FileActions.viewState(window, projectID))
        }
        .onChange(of: state.selectedEditorPath) { old, _ in
            dropMissingTab(old)
        }
    }

    /// Reads the tabs that are still loading; restored tabs are read again from disk.
    private func loadTabs(_ state: ProjectViewState) {
        for tab in state.editorTabs {
            tab.buffer.load(workspace: workspace, projectID: projectID, window: window)
        }
        if state.selectedEditorPath == nil || !state.editorTabs.contains(where: { $0.path == state.selectedEditorPath }),
           let first = state.editorTabs.first {
            window.updateViewState(of: projectID) { $0.selectedEditorPath = first.path }
        }
    }

    /// A tab showing `File <path> was not found.` closes once another tab is selected
    /// (docs/ui.md › Resolving a target: the text shows until another item is selected).
    private func dropMissingTab(_ path: String?) {
        guard let path else { return }
        let state = FileActions.viewState(window, projectID)
        guard let tab = state.editorTabs.first(where: { $0.path == path }), tab.buffer.content == .notFound,
              state.selectedEditorPath != path else { return }
        window.updateViewState(of: projectID) { $0.removeEditorTab(tab.buffer) }
    }
}

/// The editor area: tabs, banner and editor, or `No Open File`.
private struct EditorArea: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Bindable var commands: CodeSectionCommands

    var body: some View {
        let state = FileActions.viewState(window, projectID)
        let selected = state.editorTabs.first { $0.path == state.selectedEditorPath }
        VStack(spacing: 0) {
            if state.editorTabs.isEmpty {
                VStack(spacing: 6) {
                    Text("No Open File")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Select a file in the tree.")
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EditorTabsBar(window: window, workspace: workspace, projectID: projectID, tabs: state.editorTabs,
                              selectedPath: state.selectedEditorPath)
                Divider()
                if let selected {
                    Group {
                        // An OpenAPI contract shows the mode bar (docs/openapi.md › Contract and Source).
                        if selected.buffer.isOpenAPI, selected.buffer.content == .text {
                            OpenAPITabView(buffer: selected.buffer, workspace: workspace)
                        } else {
                            CodeEditorView(buffer: selected.buffer, workspace: workspace)
                        }
                    }
                    .overlay(alignment: .top) {
                        GoToLineAnchor(isPresented: $commands.goToLineShown) {
                            selected.buffer.loadedTextController
                        }
                    }
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: EditorTheme.background))
    }
}

// MARK: - Tabs

/// The editor tabs, 30 pt high: 100 to 220 pt wide, scrolling horizontally and keeping the
/// selected tab visible; dragged to reorder (docs/code-editor.md › Editor tabs).
private struct EditorTabsBar: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let tabs: [EditorTabState]
    let selectedPath: String?
    @State private var dragged: String?

    var body: some View {
        let names = Dictionary(grouping: tabs.map(\.path), by: ProjectPaths.name(of:))
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        EditorTabItem(window: window, workspace: workspace, projectID: projectID, tab: tab,
                                      label: label(of: tab.path, sharedName: (names[ProjectPaths.name(of: tab.path)]?.count ?? 0) > 1),
                                      isSelected: tab.path == selectedPath)
                            .id(tab.path)
                            .onDrag {
                                dragged = tab.path
                                return NSItemProvider(object: tab.path as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab.path, dragged: $dragged) { from, to in
                                move(from, before: to)
                            })
                    }
                }
            }
            .onChange(of: selectedPath) { _, path in
                if let path {
                    withAnimation { proxy.scrollTo(path) }
                }
            }
            .onAppear {
                if let selectedPath {
                    proxy.scrollTo(selectedPath)
                }
            }
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The file name; with ` — <parent folder name>` when two open tabs have the same name.
    private func label(of path: String, sharedName: Bool) -> String {
        let name = ProjectPaths.name(of: path)
        guard sharedName else { return name }
        let parent = ProjectPaths.parent(of: path)
        // For a file of the project root, the project's folder name (docs/code-editor.md › Editor
        // tabs, Label).
        let parentName = parent.isEmpty
            ? ((workspace.project(projectID)?.rootPath ?? projectID) as NSString).lastPathComponent
            : ProjectPaths.name(of: parent)
        return "\(name) — \(parentName)"
    }

    private func move(_ path: String, before target: String) {
        guard path != target else { return }
        window.updateViewState(of: projectID) { state in
            guard let from = state.editorTabs.firstIndex(where: { $0.path == path }),
                  let to = state.editorTabs.firstIndex(where: { $0.path == target }) else { return }
            let tab = state.editorTabs.remove(at: from)
            state.editorTabs.insert(tab, at: to)
        }
    }
}

/// Reorders tabs while one is dragged over another.
private struct TabDropDelegate: DropDelegate {
    let target: String
    @Binding var dragged: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            move(dragged, target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// One tab: label, `lock` for read-only buffers, and the close button, replaced by `●` while the
/// buffer has unsaved changes except under the pointer.
private struct EditorTabItem: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    let tab: EditorTabState
    let label: String
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let buffer = tab.buffer
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            if buffer.isReadOnly {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            ZStack {
                if buffer.isDirty && !hovering {
                    Text("●")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(width: 16, height: 16)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(minWidth: 100, maxWidth: 220, maxHeight: .infinity)
        .background(isSelected ? Color(nsColor: EditorTheme.background) : Color.clear)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            window.updateViewState(of: projectID) { $0.selectedEditorPath = tab.path }
        }
        .onHover { hovering = $0 }
        .help(tab.path)
        .contextMenu {
            Button("Close") { close() }
            Button("Close Other Tabs") {
                Task { await FileActions.closeOtherTabs(keeping: buffer, window: window, projectID: projectID) }
            }
            Divider()
            Button("Reveal in File Tree") {
                FileActions.revealInTree(tab.path, window: window, projectID: projectID)
            }
            Button("Copy Path") { FileActions.copyPath(tab.path) }
            if workspace.isLocal {
                Button("Show in Finder") {
                    FileActions.showInFinder(tab.path, workspace: workspace, projectID: projectID)
                }
            }
        }
    }

    private func close() {
        Task { await FileActions.closeTab(tab.buffer, window: window, projectID: projectID) }
    }
}

// MARK: - Menu commands

/// The menu commands of the Code section (docs/ui.md › Menus and keyboard shortcuts): Save, Close
/// Tab, Go to Line, Toggle Comment and the adjacent tabs.
@MainActor @Observable
final class CodeSectionCommands: SectionCommandHandler {
    let projectID: String
    @ObservationIgnored private weak var window: WindowState?
    @ObservationIgnored private weak var workspace: DeviceWorkspace?
    /// The Go to Line popover is shown.
    var goToLineShown = false

    private init(window: WindowState, workspace: DeviceWorkspace, projectID: String) {
        self.window = window
        self.workspace = workspace
        self.projectID = projectID
    }

    /// The commands of a project's Code section in a window, kept by the window's store.
    static func of(window: WindowState, workspace: DeviceWorkspace, projectID: String) -> CodeSectionCommands {
        let entry = CodeDocsStore.shared.entry(window: window, projectID: projectID)
        if let commands = entry.codeCommands, commands.workspace === workspace { return commands }
        let commands = CodeSectionCommands(window: window, workspace: workspace, projectID: projectID)
        entry.codeCommands = commands
        return commands
    }

    private var state: ProjectViewState? {
        window.map { FileActions.viewState($0, projectID) }
    }

    private var selectedBuffer: EditorBuffer? {
        guard let state else { return nil }
        return state.editorTabs.first { $0.path == state.selectedEditorPath }?.buffer
    }

    /// The selected buffer when its editor has the focus.
    private var focusedBuffer: EditorBuffer? {
        guard let buffer = selectedBuffer, buffer.content == .text, buffer.hasEditorFocus else { return nil }
        return buffer
    }

    var canSave: Bool { selectedBuffer?.canSave ?? false }

    func save() {
        guard let buffer = selectedBuffer, buffer.canSave else { return }
        Task { try? await buffer.save() }
    }

    var canCloseTab: Bool { selectedBuffer != nil }

    func closeTab() {
        guard let window, let buffer = selectedBuffer else { return }
        let projectID = self.projectID
        Task { await FileActions.closeTab(buffer, window: window, projectID: projectID) }
    }

    var canGoToLine: Bool { focusedBuffer != nil }

    func goToLine() {
        guard focusedBuffer != nil else { return }
        goToLineShown = true
    }

    var canShowAdjacentTab: Bool { (state?.editorTabs.count ?? 0) >= 2 }

    func showPreviousTab() { selectAdjacent(-1) }

    func showNextTab() { selectAdjacent(1) }

    /// Selects the tab on the left or right, wrapping.
    private func selectAdjacent(_ step: Int) {
        guard let window, let state, state.editorTabs.count >= 2 else { return }
        let tabs = state.editorTabs
        let index = tabs.firstIndex { $0.path == state.selectedEditorPath } ?? 0
        let next = (index + step + tabs.count) % tabs.count
        window.updateViewState(of: projectID) { $0.selectedEditorPath = tabs[next].path }
    }

    var canToggleComment: Bool {
        guard let buffer = focusedBuffer, !buffer.isReadOnly else { return false }
        return EditorTextOps.commentPrefix(language: buffer.language) != nil
    }

    func toggleComment() {
        guard canToggleComment, let buffer = focusedBuffer else { return }
        buffer.textController.toggleComment()
    }
}
