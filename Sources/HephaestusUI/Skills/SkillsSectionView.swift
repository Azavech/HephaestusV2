// OWNER: ui-skills-feedback — the Skills section: library list and editor (docs/skills.md › Skills section).
import HephaestusCore
import SwiftUI

/// The skills library with the active project's enablement (`ProjectViewState.selectedSkillName`,
/// `skillEditor`): the library list and the editor of the selected skill, in two columns
/// (docs/skills.md › Skills section). A selected skill that does not exist shows
/// `NotFoundView(kind: "Skill", id:)`.
struct SkillsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    @State private var commands = SkillsSectionCommands()
    @State private var filter = ""
    /// The message of a failed `skills.list`.
    @State private var listError: String?
    /// True once a `skills.list` call of this view answered.
    @State private var listLoaded = false

    private var key: ProjectKey {
        ProjectKey(deviceID: workspace.deviceID, projectID: projectID)
    }

    private var viewState: ProjectViewState? {
        window.projectStates[key]
    }

    private var selectedName: String? {
        viewState?.selectedSkillName
    }

    var body: some View {
        Group {
            if showsLibraryEmptyState {
                SkillsLibraryEmptyView(window: window, workspace: workspace, projectID: projectID)
            } else {
                HSplitView {
                    SkillLibraryList(window: window, workspace: workspace, projectID: projectID, filter: $filter,
                                     listError: listError)
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 420, maxHeight: .infinity)
                    editorColumn
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            commands.window = window
            commands.key = key
            window.sectionCommands = commands
            ensureEditor()
        }
        .onDisappear(perform: sectionDidDisappear)
        .onChange(of: selectedName) {
            ensureEditor()
        }
        .task(id: workspace.connectionGeneration) {
            // On appearing and after every reconnection: the library list, then the shown skill
            // (docs/remote.md › After a reconnect).
            await loadList()
            await viewState?.skillEditor?.refresh()
        }
        .task {
            for await event in workspace.events() {
                guard case .skillsChanged = event.event else { continue }
                listError = nil
                listLoaded = true
                await viewState?.skillEditor?.refresh()
            }
        }
    }

    /// `Library empty`: the library has no skill and no skill is selected.
    private var showsLibraryEmptyState: Bool {
        listError == nil && (listLoaded || workspace.hasSnapshot) && workspace.skills.isEmpty && selectedName == nil
    }

    // MARK: Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let name = selectedName {
            if let editor = viewState?.skillEditor, editor.skillName == name {
                if editor.isMissing {
                    NotFoundView(kind: "Skill", id: name)
                } else if editor.hasLoaded {
                    SkillEditorView(editor: editor, form: editor.form, window: window, workspace: workspace,
                                    projectID: projectID)
                } else if let error = editor.loadError {
                    SkillLoadFailedView(message: error.message) {
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
            Text("Select a skill")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Loading

    /// `skills.list` as a seeding call under the replay rule (docs/ui.md › DeviceWorkspace,
    /// Loading step 4); its failure shows the error message in place of the list.
    private func loadList() async {
        do {
            try await workspace.seed({
                try await workspace.call(SkillsList.self)
            }, replace: { skills in
                workspace.skills = skills
            }, replay: { event in
                if case .skillsChanged(let skills) = event.event {
                    workspace.skills = skills
                }
            })
            listError = nil
        } catch {
            listError = errorMessage(error)
        }
        listLoaded = true
    }

    /// Keeps the editor on the selected skill: a selection made by navigation (`skill` target)
    /// or kept from earlier gets its editor here.
    private func ensureEditor() {
        guard var state = viewState else { return }
        state.skillEditor?.attach(window: window, workspace: workspace)
        guard let name = state.selectedSkillName else {
            if state.skillEditor != nil {
                state.skillEditor = nil
                window.projectStates[key] = state
            }
            return
        }
        guard state.skillEditor?.skillName != name else { return }
        let editor = SkillEditorState(skillName: name, projectID: projectID, bodyMode: state.skillEditor?.bodyMode ?? .preview)
        editor.attach(window: window, workspace: workspace)
        state.skillEditor = editor
        window.projectStates[key] = state
        Task {
            await editor.refresh()
        }
    }

    /// Leaving the section with unsaved changes asks `Do you want to save the changes to
    /// “<name>”?`; Cancel, or a failed save, shows the Skills section again and Don't Save
    /// discards the changes (docs/skills.md › Saving). Switching project or device keeps the
    /// editor in the window's state, as every unsaved editor of a project
    /// (docs/ui.md › WindowState).
    private func sectionDidDisappear() {
        if window.sectionCommands === commands {
            window.sectionCommands = nil
        }
        guard window.section != .skills, window.app?.windows[window.id] != nil,
              let editor = viewState?.skillEditor, !editor.unsavedEditors.isEmpty else { return }
        let window = window
        let projectID = projectID
        Task {
            let unsaved = editor.unsavedEditors
            guard !unsaved.isEmpty else { return }
            if await UnsavedChangesPrompt.confirm(unsaved, in: window) {
                if !editor.unsavedEditors.isEmpty {
                    editor.discardChanges()
                }
            } else if window.projectID == projectID {
                window.section = .skills
            }
        }
    }
}

/// File ▸ Save (⌘S) in the Skills section: the form when it has changes and the open extra file
/// when it has changes (docs/ui.md › Menus and keyboard shortcuts, Save).
@MainActor @Observable
final class SkillsSectionCommands: SectionCommandHandler {
    @ObservationIgnored weak var window: WindowState?
    @ObservationIgnored var key: ProjectKey?

    private var editor: SkillEditorState? {
        guard let window, let key else { return nil }
        return window.projectStates[key]?.skillEditor
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

    // Go to Line, Toggle Comment and Find act on the focused embedded editor through the code
    // editor's forwarding API; Find reaches its text view through the responder chain.

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

/// `skills.get` failed for another reason than a missing skill.
// DOC-GAP: docs/skills.md › Empty and error states lists no failure of `skills.get`; the editor
// column shows the engine's message and Try Again, as a chat view's failed load
// (docs/ui.md › Empty states).
private struct SkillLoadFailedView: View {
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

// MARK: - Library list

/// The library list: a filter field, the skills sorted by name with the enabled mark, the
/// `Missing from Library` group and the bottom bar (docs/skills.md › Library list).
private struct SkillLibraryList: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    @Binding var filter: String
    let listError: String?

    private var key: ProjectKey {
        ProjectKey(deviceID: workspace.deviceID, projectID: projectID)
    }

    private var selectedName: String? {
        window.projectStates[key]?.selectedSkillName
    }

    /// The active project's enabled skills, in enabling order.
    private var enabledNames: [String] {
        workspace.details[projectID]?.project.skills ?? []
    }

    /// The skills whose name or description contains the filter, case-insensitively, by name.
    private var filteredSkills: [SkillSummary] {
        let skills = workspace.skills.sorted { $0.name < $1.name }
        guard !filter.isEmpty else { return skills }
        return skills.filter {
            $0.name.range(of: filter, options: .caseInsensitive) != nil
                || $0.description.range(of: filter, options: .caseInsensitive) != nil
        }
    }

    /// The enabled names the library lacks.
    private var missingNames: [String] {
        let library = Set(workspace.skills.map(\.name))
        return enabledNames.filter { !library.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // DOC-GAP: docs/skills.md › Library list gives the filter field no placeholder; it is
            // `Filter`, as the ticket list's (docs/tickets.md › Ticket list).
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

    @ViewBuilder
    private var content: some View {
        if let listError {
            Text(listError)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let skills = filteredSkills
            let missing = missingNames
            let enabled = Set(enabledNames)
            List(selection: selection) {
                if skills.isEmpty, !filter.isEmpty {
                    Text("No skills match “\(filter)”")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(skills, id: \.name) { skill in
                    SkillRow(skill: skill, isEnabled: enabled.contains(skill.name))
                        .tag(skill.name)
                }
                if !missing.isEmpty {
                    Section("Missing from Library") {
                        ForEach(missing, id: \.self) { name in
                            MissingSkillRow(name: name, workspace: workspace, window: window, projectID: projectID)
                                .selectionDisabled()
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(keys: [.delete]) { press in
                // ⌫ or ⌘⌫ with a list row selected (docs/skills.md › Keyboard).
                guard press.modifiers.isEmpty || press.modifiers == .command, let name = selectedName else {
                    return .ignored
                }
                trash(name)
                return .handled
            }
        }
    }

    /// The selection; choosing another skill asks first when the shown one has unsaved changes.
    private var selection: Binding<String?> {
        Binding(get: { selectedName }, set: { name in
            guard name != selectedName else { return }
            Task {
                await SkillActions.select(name, window: window, workspace: workspace, projectID: projectID)
            }
        })
    }

    /// `+` (New Skill…) and `−` (Move to Trash…, disabled without a selection).
    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                window.sheet = .newSkill(projectID: projectID)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 20)
            }
            .help("New Skill…")
            .accessibilityLabel("New Skill…")
            Button {
                if let selectedName {
                    trash(selectedName)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 22, height: 20)
            }
            .help("Move to Trash…")
            .accessibilityLabel("Move to Trash…")
            .disabled(selectedName == nil)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    private func trash(_ name: String) {
        Task {
            await SkillActions.trashSkill(name, window: window, workspace: workspace, projectID: projectID)
        }
    }
}

/// A skill of the library: `checkmark.circle.fill` when it is enabled in the active project, the
/// name and the description on one truncated line.
private struct SkillRow: View {
    let skill: SkillSummary
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .opacity(isEnabled ? 1 : 0)
                .accessibilityHidden(!isEnabled)
                .accessibilityLabel("Enabled")
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .lineLimit(1)
                Text(skill.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }
}

/// An enabled name the library lacks: `exclamationmark.triangle`, the name,
/// `Not found in the skills library` and `Disable` (`skills.setEnabled` with `enabled: false`).
private struct MissingSkillRow: View {
    let name: String
    let workspace: DeviceWorkspace
    let window: WindowState
    let projectID: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                Text("Not found in the skills library")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Disable") {
                Task {
                    do {
                        _ = try await workspace.call(SkillsSetEnabled.self,
                                                     .init(projectID: projectID, name: name, enabled: false))
                    } catch {
                        window.alert = .failure("Disable", error)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// `Library empty`: `No Skills`, where skills live and `New Skill…`; the names the active project
/// enables without a skill follow, so that they can be disabled (docs/skills.md › Empty and error
/// states).
private struct SkillsLibraryEmptyView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    private var missingNames: [String] {
        workspace.details[projectID]?.project.skills ?? []
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Skills")
                .font(.title2)
            Text("Skills are folders with a SKILL.md file in \(SkillLibraryLocation.displayPath(of: workspace)). Enable a skill in a project to let its chats use it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("New Skill…") {
                window.sheet = .newSkill(projectID: projectID)
            }
            .padding(.top, 4)
            if !missingNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Missing from Library")
                        .font(.headline)
                    ForEach(missingNames, id: \.self) { name in
                        MissingSkillRow(name: name, workspace: workspace, window: window, projectID: projectID)
                    }
                }
                .frame(maxWidth: 360)
                .padding(.top, 16)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
