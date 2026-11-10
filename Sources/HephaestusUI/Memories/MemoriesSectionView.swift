// OWNER: ui-memories — the Memories section and the Global Memories view: list and editor, with
// the read-only groups of the inherited folders (docs/memories.md › Memories section, › Global
// Memories view).
import HephaestusCore
import SwiftUI

/// The memories of the active project (`ProjectViewState.selectedMemoryFile`, `memoryEditor`), or
/// the global memories of the window's device (`MemoryViewState`): the list and the editor of the
/// selected row, in two columns (docs/memories.md › Memories section, › Global Memories view).
struct MemoriesSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let scope: MemoryScope

    @State private var commands = MemoriesSectionCommands()
    @State private var filter = ""
    /// The message of a failed `memories.list`.
    @State private var listError: String?

    private var viewState: MemoryViewState {
        window.memoryViewState(scope, deviceID: workspace.deviceID)
    }

    private var selectedFile: String? {
        viewState.selectedMemoryFile
    }

    private var folder: MemoryFolder? {
        workspace.memoryFolder(scope)
    }

    var body: some View {
        Group {
            if let folder, showsEmptyState(folder) {
                MemoriesEmptyView(window: window, workspace: workspace, scope: scope, folder: folder)
            } else {
                HSplitView {
                    MemoryList(window: window, workspace: workspace, scope: scope, filter: $filter, listError: listError)
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 420, maxHeight: .infinity)
                    editorColumn
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The previews draw the markers of every Markdown view with the section's project, or the
        // window's active project in the Global Memories view (docs/memories.md › Memory editor,
        // › Global Memories view).
        .markdownMarkers(projectID: scope.projectID ?? window.projectID, workspace: workspace, window: window)
        .onAppear {
            commands.window = window
            commands.scope = scope
            commands.deviceID = workspace.deviceID
            window.sectionCommands = commands
            ensureEditor()
        }
        .onDisappear(perform: sectionDidDisappear)
        .onChange(of: selectedFile) {
            ensureEditor()
        }
        .task(id: workspace.connectionGeneration) {
            // On appearing and after every reconnection: the list, then the shown row
            // (docs/remote.md › After a reconnect).
            await loadList()
            await viewState.memoryEditor?.refresh()
        }
        .task {
            for await event in workspace.events() {
                guard case .memoriesChanged(let changed) = event.event, MemoryScope(projectID: changed.projectID) == scope else { continue }
                listError = nil
                await viewState.memoryEditor?.refresh()
            }
        }
    }

    /// `No Memories`: the folder has no memory and no `MEMORY.md`, and no inherited folder lists a
    /// memory; an editor with unsaved changes stays shown, with its banner.
    private func showsEmptyState(_ folder: MemoryFolder) -> Bool {
        MemoryGroups.showsEmptyState(folder, listError: listError, hasUnsavedChanges: viewState.memoryEditor?.hasUnsavedChanges == true)
    }

    // MARK: Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let file = selectedFile {
            if let editor = viewState.memoryEditor, editor.selection == file {
                if editor.isMissing || MemoryActions.isNoLongerInherited(editor.target, in: folder) {
                    if editor.target == .index {
                        NotFoundView(kind: "File", id: MemoryActions.indexFileName)
                    } else {
                        Text("Memory \(editor.displayName) was not found.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if editor.hasLoaded {
                    switch editor.target {
                    case .memory, .inherited:
                        MemoryEditorView(editor: editor, form: editor.form, window: window, workspace: workspace, scope: scope)
                    case .index:
                        MemoryIndexEditorView(editor: editor, workspace: workspace, scope: scope)
                    }
                } else if let error = editor.loadError {
                    MemoryLoadFailedView(message: error.message) {
                        Task { await editor.refresh() }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text("Select a memory")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Loading

    /// `memories.list` as a seeding call under the replay rule, without `projectID` for the global
    /// memories (docs/memories.md › Live updates); its failure shows the error message in place of
    /// the list.
    private func loadList() async {
        let scope = self.scope
        do {
            try await workspace.seed({
                try await workspace.call(MemoriesList.self, .init(projectID: scope.projectID))
            }, replace: { folder in
                workspace.setMemoryFolder(folder, for: scope)
            }, replay: { event in
                if case .memoriesChanged(let folder) = event.event, MemoryScope(projectID: folder.projectID) == scope {
                    workspace.setMemoryFolder(folder, for: scope)
                }
            })
            listError = nil
        } catch {
            listError = errorMessage(error)
        }
    }

    /// Keeps the editor on the selected row: a selection kept from earlier gets its editor here.
    private func ensureEditor() {
        let state = viewState
        state.memoryEditor?.attach(window: window, workspace: workspace)
        guard let file = state.selectedMemoryFile else {
            if state.memoryEditor != nil {
                window.updateMemoryViewState(scope, deviceID: workspace.deviceID) { $0.memoryEditor = nil }
            }
            return
        }
        guard state.memoryEditor?.selection != file else { return }
        let editor = MemoryEditorState(target: MemoryActions.target(of: file), scope: scope, bodyMode: state.memoryBodyMode)
        editor.attach(window: window, workspace: workspace)
        window.updateMemoryViewState(scope, deviceID: workspace.deviceID) { $0.memoryEditor = editor }
        Task {
            await editor.refresh()
        }
    }

    /// The window still shows this view: the project's Memories section, or the Global Memories
    /// view.
    private var isShown: Bool {
        switch scope {
        case .project: return window.shownSection == .memories
        case .global: return window.showsGlobalMemories
        }
    }

    /// Cancel of the unsaved changes prompt shows the view again.
    private func showAgain() {
        switch scope {
        case .project(let projectID):
            if window.projectID == projectID {
                window.section = .memories
            }
        case .global:
            window.showsGlobalMemories = true
        }
    }

    /// Leaving the section, or the Global Memories view, with unsaved changes asks `Do you want to
    /// save the changes to “<name>”?`; Cancel, or a failed save, shows it again and Don't Save
    /// discards the changes (docs/memories.md › Saving, › Global Memories view). Switching project
    /// or device keeps the editor in the window's state, as every unsaved editor of a project
    /// (docs/ui.md › WindowState).
    private func sectionDidDisappear() {
        if window.sectionCommands === commands {
            window.sectionCommands = nil
        }
        guard !isShown, window.app?.windows[window.id] != nil,
              let editor = viewState.memoryEditor, !editor.unsavedEditors.isEmpty else { return }
        Task {
            let unsaved = editor.unsavedEditors
            guard !unsaved.isEmpty else { return }
            if await UnsavedChangesPrompt.confirm(unsaved, in: window) {
                if !editor.unsavedEditors.isEmpty {
                    editor.discardChanges()
                }
            } else {
                showAgain()
            }
        }
    }
}

/// File ▸ Save (⌘S) in the Memories section and the Global Memories view: the memory form or
/// `MEMORY.md` when it has changes (docs/ui.md › Menus and keyboard shortcuts, Save).
@MainActor @Observable
final class MemoriesSectionCommands: SectionCommandHandler {
    @ObservationIgnored weak var window: WindowState?
    @ObservationIgnored var scope: MemoryScope?
    @ObservationIgnored var deviceID: String?

    private var editor: MemoryEditorState? {
        guard let window, let scope, let deviceID else { return nil }
        return window.memoryViewState(scope, deviceID: deviceID).memoryEditor
    }

    var canSave: Bool {
        editor?.canSave ?? false
    }

    func save() {
        guard let editor else { return }
        Task {
            await editor.save()
        }
    }

    var canGoToLine: Bool {
        editor?.focusedEditor != nil
    }

    func goToLine() {
        guard let editor, let buffer = editor.focusedEditor else { return }
        editor.goToLineEditor = buffer
    }

    var canToggleComment: Bool {
        editor?.focusedEditor?.canToggleEditorComment ?? false
    }

    func toggleComment() {
        guard canToggleComment, let buffer = editor?.focusedEditor else { return }
        buffer.toggleEditorComment()
    }
}

/// A failed read for another reason than a missing file: the engine's message and Try Again
/// (docs/memories.md › Empty and error states).
private struct MemoryLoadFailedView: View {
    let message: String
    let tryAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Try Again", action: tryAgain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - List

/// The list: its title row, a filter field, the `MEMORY.md` row, the memories under their group
/// headings, the read-only groups of the inherited folders and the bottom bar (docs/memories.md ›
/// List).
private struct MemoryList: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let scope: MemoryScope
    @Binding var filter: String
    let listError: String?

    private var selectedFile: String? {
        window.memoryViewState(scope, deviceID: workspace.deviceID).selectedMemoryFile
    }

    private var folder: MemoryFolder? {
        workspace.memoryFolder(scope)
    }

    /// The selected row when it is a memory of the project's own folder: not `MEMORY.md` nor an
    /// inherited memory, which cannot be moved to the Trash from here.
    private var selectedMemoryFile: String? {
        MemoryActions.ownMemoryFile(of: selectedFile)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The list's pane header (docs/ui.md › Pane headers): `Memories` in the section, `Global
    /// Memories` in the view.
    @ViewBuilder
    private var titleRow: some View {
        switch scope {
        case .project:
            PaneTitleRow(section: .memories)
        case .global:
            PaneTitleRow(title: PaneTitle.globalMemories)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let listError {
            Text(listError)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let folder {
            let showsIndex = folder.hasIndex && MemoryGroups.matches(name: MemoryActions.indexFileName, description: "", filter: filter)
            let groups = MemoryGroups.groups(of: folder.memories.filter {
                MemoryGroups.matches(name: $0.name, description: $0.description, filter: filter)
            })
            let inherited = MemoryGroups.inheritedGroups(of: folder.inherited, filter: filter) { workspace.project($0)?.name }
            List(selection: selection) {
                if !showsIndex, groups.isEmpty, inherited.isEmpty, !filter.isEmpty {
                    Text("No memories match “\(filter)”")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                if showsIndex {
                    Text(MemoryActions.indexFileName)
                        .lineLimit(1)
                        .padding(.vertical, 2)
                        .tag(MemoryActions.indexFileName)
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.memories, id: \.file) { memory in
                            MemoryRow(memory: memory)
                                .tag(memory.file)
                        }
                    }
                }
                // Keyed by ancestor: two ancestors may share a name.
                ForEach(inherited, id: \.projectID) { group in
                    Section(group.title) {
                        ForEach(group.memories, id: \.file) { memory in
                            MemoryRow(memory: memory)
                                .tag(MemoryActions.inheritedTag(projectID: group.projectID, file: memory.file))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(keys: [.delete]) { press in
                // ⌫ or ⌘⌫ with a row of the project's own memories selected (docs/memories.md › Keyboard).
                guard press.modifiers.isEmpty || press.modifiers == .command, let file = selectedMemoryFile else {
                    return .ignored
                }
                trash(file)
                return .handled
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The selection; choosing another row asks first when the shown one has unsaved changes.
    private var selection: Binding<String?> {
        Binding(get: { selectedFile }, set: { file in
            guard file != selectedFile else { return }
            Task {
                await MemoryActions.select(file, window: window, workspace: workspace, scope: scope)
            }
        })
    }

    /// `+` (New Memory…) and `−` (Move to Trash…, disabled without a selected memory, while
    /// `MEMORY.md` is selected and while an inherited memory is selected).
    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                Task { await MemoryActions.openNewMemorySheet(window: window, workspace: workspace, scope: scope) }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 20)
            }
            .help("New Memory…")
            .accessibilityLabel("New Memory…")
            Button {
                if let selectedMemoryFile {
                    trash(selectedMemoryFile)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 22, height: 20)
            }
            .help("Move to Trash…")
            .accessibilityLabel("Move to Trash…")
            .disabled(selectedMemoryFile == nil)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    private func trash(_ file: String) {
        Task {
            await MemoryActions.trashMemory(file, window: window, workspace: workspace, scope: scope)
        }
    }
}

/// A memory: the name and, under it, the description on one truncated line.
private struct MemoryRow: View {
    let memory: MemorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(memory.name)
                .lineLimit(1)
            Text(memory.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
    }
}

/// `No Memories`: where Claude saves memories, and `New Memory…`; `No Global Memories` for the
/// global memories (docs/memories.md › Empty and error states, › Global Memories view).
private struct MemoriesEmptyView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let scope: MemoryScope
    let folder: MemoryFolder

    private var title: String {
        scope == .global ? "No Global Memories" : "No Memories"
    }

    private var text: String {
        switch scope {
        case .project:
            return "Claude saves what it learns about you and this project in \(MemoryActions.displayPath(folder.path, in: workspace))."
        case .global:
            return "Claude saves here what it learns that holds for every project."
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 440)
            Button("New Memory…") {
                Task { await MemoryActions.openNewMemorySheet(window: window, workspace: workspace, scope: scope) }
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
