// OWNER: ui-skills-feedback — the Skills section and the Internal Skills view: library list and
// editor (docs/skills.md › Skills section, › Internal Skills view).
import HephaestusCore
import SwiftUI

/// The skills library with the active project's enablement (`ProjectViewState.selectedSkillName`,
/// `skillEditor`), or the internal skills of the window's device (`SkillViewState`): the library
/// list and the editor of the selected skill, in two columns (docs/skills.md › Skills section, ›
/// Internal Skills view). A selected skill that does not exist, or that the view does not list,
/// shows `NotFoundView(kind: "Skill", id:)`.
struct SkillsSectionView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let scope: SkillsScope

    @State private var commands = SkillsSectionCommands()
    @State private var filter = ""
    /// The message of a failed `skills.list`.
    @State private var listError: String?
    /// True once a `skills.list` call of this view answered.
    @State private var listLoaded = false

    private var viewState: SkillViewState {
        window.skillViewState(scope, deviceID: workspace.deviceID)
    }

    private var selectedName: String? {
        viewState.selectedSkillName
    }

    var body: some View {
        Group {
            if let projectID = scope.projectID, showsLibraryEmptyState {
                SkillsLibraryEmptyView(window: window, workspace: workspace, projectID: projectID)
            } else {
                HSplitView {
                    SkillLibraryList(window: window, workspace: workspace, scope: scope, filter: $filter,
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
            commands.scope = scope
            commands.deviceID = workspace.deviceID
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
            await viewState.skillEditor?.refresh()
        }
        .task {
            for await event in workspace.events() {
                guard case .skillsChanged = event.event else { continue }
                listError = nil
                listLoaded = true
                await viewState.skillEditor?.refresh()
            }
        }
    }

    /// `Library empty`: the library has no skill that the list shows and no skill is selected. The
    /// Internal Skills view has no such state: its empty list shows no row.
    private var showsLibraryEmptyState: Bool {
        listError == nil && (listLoaded || workspace.hasSnapshot)
            && SkillsVisibility.listed(workspace.skills, in: scope).isEmpty && selectedName == nil
    }

    // MARK: Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let name = selectedName {
            if !SkillsVisibility.isListed(name, in: scope) {
                // An internal skill is shown only in the Internal Skills view, which shows nothing
                // else (docs/skills.md › Availability).
                NotFoundView(kind: "Skill", id: name)
            } else if let editor = viewState.skillEditor, editor.skillName == name {
                if editor.isMissing {
                    NotFoundView(kind: "Skill", id: name)
                } else if editor.hasLoaded {
                    SkillEditorView(editor: editor, form: editor.form, window: window, workspace: workspace,
                                    scope: scope)
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
        let state = viewState
        state.skillEditor?.attach(window: window, workspace: workspace)
        guard let name = state.selectedSkillName else {
            if state.skillEditor != nil {
                window.updateSkillViewState(scope, deviceID: workspace.deviceID) { $0.skillEditor = nil }
            }
            return
        }
        guard state.skillEditor?.skillName != name else { return }
        let editor = SkillEditorState(skillName: name, scope: scope, bodyMode: state.skillEditor?.bodyMode ?? .preview)
        editor.attach(window: window, workspace: workspace)
        window.updateSkillViewState(scope, deviceID: workspace.deviceID) { $0.skillEditor = editor }
        Task {
            await editor.refresh()
        }
    }

    /// The window still shows this view: the project's Skills section, or the Internal Skills
    /// view.
    private var isShown: Bool {
        switch scope {
        case .project: return window.shownSection == .skills
        case .internalSkills: return window.showsInternalSkills
        }
    }

    /// Cancel of the unsaved changes prompt shows the view again.
    private func showAgain() {
        switch scope {
        case .project(let projectID):
            if window.projectID == projectID {
                window.section = .skills
            }
        case .internalSkills:
            window.showsInternalSkills = true
        }
    }

    /// Leaving the section, or the Internal Skills view, with unsaved changes asks `Do you want to
    /// save the changes to “<name>”?`; Cancel, or a failed save, shows it again and Don't Save
    /// discards the changes (docs/skills.md › Saving, › Internal Skills view). Switching project or
    /// device keeps the editor in the window's state, as every unsaved editor of a project
    /// (docs/ui.md › WindowState).
    private func sectionDidDisappear() {
        if window.sectionCommands === commands {
            window.sectionCommands = nil
        }
        guard !isShown, window.app?.windows[window.id] != nil,
              let editor = viewState.skillEditor, !editor.unsavedEditors.isEmpty else { return }
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

/// File ▸ Save (⌘S) in the Skills section and the Internal Skills view: the form when it has
/// changes and the open extra file when it has changes (docs/ui.md › Menus and keyboard shortcuts,
/// Save).
@MainActor @Observable
final class SkillsSectionCommands: SectionCommandHandler {
    @ObservationIgnored weak var window: WindowState?
    @ObservationIgnored var scope: SkillsScope?
    @ObservationIgnored var deviceID: String?

    private var editor: SkillEditorState? {
        guard let window, let scope, let deviceID else { return nil }
        return window.skillViewState(scope, deviceID: deviceID).skillEditor
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

/// `skills.get` failed for another reason than a missing skill: the engine's message and Try Again
/// (docs/skills.md › Empty and error states).
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

/// The library list: its title row, a filter field, the skills sorted by name with the enabled
/// mark, the `Missing from Library` group and the bottom bar; in the Internal Skills view, the
/// internal skills only, without group and bottom bar (docs/skills.md › Library list, › Internal
/// Skills view).
private struct SkillLibraryList: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let scope: SkillsScope
    @Binding var filter: String
    let listError: String?

    private var selectedName: String? {
        window.skillViewState(scope, deviceID: workspace.deviceID).selectedSkillName
    }

    /// The active project's enabled skills, in enabling order; none in the Internal Skills view.
    private var enabledNames: [String] {
        scope.projectID.flatMap { workspace.details[$0]?.project.skills } ?? []
    }

    /// The skills the list shows whose name or description contains the filter,
    /// case-insensitively, by name.
    private var filteredSkills: [SkillSummary] {
        let skills = SkillsVisibility.listed(workspace.skills, in: scope).sorted { $0.name < $1.name }
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
            titleRow
            // docs/skills.md › Library list: the filter field in the list's header bar, under the
            // title row.
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .paneHeaderBar()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The internal skills are never created or moved to the Trash: no `+` or `−`.
            if let projectID = scope.projectID {
                Divider()
                bottomBar(projectID)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The list's pane header (docs/ui.md › Pane headers): `Skills` in the section, `Internal
    /// Skills` in the view.
    @ViewBuilder
    private var titleRow: some View {
        switch scope {
        case .project:
            PaneTitleRow(section: .skills)
        case .internalSkills:
            PaneTitleRow(title: PaneTitle.internalSkills)
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
                    // An internal skill is always enabled (docs/skills.md › Internal Skills view).
                    SkillRow(skill: skill, isEnabled: enabled.contains(skill.name) || InternalSkills.isInternal(skill.name))
                        .tag(skill.name)
                }
                if let projectID = scope.projectID, !missing.isEmpty {
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
                guard press.modifiers.isEmpty || press.modifiers == .command, let projectID = scope.projectID,
                      let name = selectedName, !InternalSkills.isInternal(name) else {
                    return .ignored
                }
                trash(name, projectID: projectID)
                return .handled
            }
        }
    }

    /// The selection; choosing another skill asks first when the shown one has unsaved changes.
    private var selection: Binding<String?> {
        Binding(get: { selectedName }, set: { name in
            guard name != selectedName else { return }
            Task {
                await SkillActions.select(name, window: window, workspace: workspace, scope: scope)
            }
        })
    }

    /// `+` (New Skill…) and `−` (Move to Trash…, disabled without a selection and for an internal
    /// skill).
    private func bottomBar(_ projectID: String) -> some View {
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
                    trash(selectedName, projectID: projectID)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 22, height: 20)
            }
            .help("Move to Trash…")
            .accessibilityLabel("Move to Trash…")
            .disabled(selectedName.map(InternalSkills.isInternal) ?? true)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    private func trash(_ name: String, projectID: String) {
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

/// The internal skills are listed and edited only in the Internal Skills view, which lists nothing
/// else; the Skills section of every project, the HephaestusV2 project included, leaves them out
/// (docs/skills.md › Availability).
enum SkillsVisibility {
    /// True when the view of `scope` lists the skill `name`.
    static func isListed(_ name: String, in scope: SkillsScope) -> Bool {
        switch scope {
        case .project: return !InternalSkills.isInternal(name)
        case .internalSkills: return InternalSkills.isInternal(name)
        }
    }

    /// The skills of the library that the view of `scope` lists.
    static func listed(_ skills: [SkillSummary], in scope: SkillsScope) -> [SkillSummary] {
        skills.filter { isListed($0.name, in: scope) }
    }
}
