// OWNER: ui-shell — the New Project and New Sub Project sheets (docs/projects.md › Creating a project, › Sub projects).
import HephaestusCore
import SwiftUI

/// The New Project sheet, or the New Sub Project sheet when `parentID` is set; Create calls `projects.create`.
struct NewProjectSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    /// The parent preselected by New Sub Project…; nil for New Project.
    let parentID: String?
    /// The folder of `Create Project Here…`: the sheet opens in Existing Folder mode with it.
    var existingFolder: String?

    private enum FolderMode: Hashable {
        case newFolder, existingFolder
    }

    /// The folder field a remote Choose Folder sheet fills.
    private enum FolderField: Identifiable {
        case parentFolder, existingFolder

        var id: Self { self }
    }

    @State private var name = ""
    @State private var nameEdited = false
    @State private var identifier = ""
    @State private var identifierEdited = false
    @State private var mode = FolderMode.newFolder
    @State private var parentFolder = ""
    @State private var folderName = ""
    @State private var folderNameEdited = false
    @State private var chosenFolder = ""
    @State private var selectedParentID: String?
    @State private var failure: String?
    @State private var offersOpen = false
    @State private var working = false
    @State private var remotePicker: FolderField?
    @State private var prepared = false
    @State private var hostWindow = HostWindow()

    private var isSubProject: Bool { parentID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isSubProject ? "New Sub Project" : "New Project")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                if isSubProject {
                    GridRow {
                        label("Parent project")
                        IndentedPopUpButton(items: parentItems, selection: selectedParentID ?? "") { id in
                            selectParent(id)
                        }
                        .fixedSize()
                    }
                }
                GridRow {
                    label("Name")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: nameBinding, prompt: Text(""))
                            .labelsHidden()
                        FieldMessage(text: nameEdited ? ProjectRules.nameMessage(name) : nil)
                    }
                }
                GridRow {
                    label("Identifier")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Identifier", text: identifierBinding, prompt: Text(""))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 140)
                        FieldMessage(text: showsIdentifierMessage ? identifierMessage : nil)
                    }
                }
                GridRow {
                    label("Folder")
                    Picker("Folder", selection: $mode) {
                        Text("New Folder").tag(FolderMode.newFolder)
                        Text("Existing Folder").tag(FolderMode.existingFolder)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if mode == .newFolder {
                    GridRow {
                        label("Parent folder")
                        HStack(spacing: 8) {
                            PathText(path: parentFolder)
                            Spacer(minLength: 0)
                            Button("Choose…") {
                                choose(.parentFolder)
                            }
                        }
                    }
                    GridRow {
                        label("Folder name")
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Folder name", text: folderNameBinding, prompt: Text(""))
                                .labelsHidden()
                            FieldMessage(text: folderNameEdited || nameEdited ? ProjectRules.folderNameMessage(folderName) : nil)
                        }
                    }
                } else {
                    GridRow {
                        label("Folder")
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                PathText(path: chosenFolder)
                                Spacer(minLength: 0)
                                Button("Choose…") {
                                    choose(.existingFolder)
                                }
                            }
                            FieldMessage(text: chosenFolder.isEmpty ? "Choose a folder." : nil)
                        }
                    }
                }
                GridRow {
                    label("Project folder")
                    PathText(path: projectFolder)
                }
            }
            if let note = insideNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FieldMessage(text: parentConstraintMessage)
            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FieldMessage(text: failure)
                    if offersOpen {
                        Button("Open It", action: openExisting)
                    }
                }
            }
            SheetButtonRow(defaultTitle: "Create", defaultEnabled: canCreate && !working, cancel: close, confirm: create) {
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
        .readsHostWindow(hostWindow)
        .task {
            await prepare()
        }
        .sheet(item: $remotePicker) { field in
            ChooseFolderSheet(window: window, workspace: workspace, purpose: .projectFolder,
                              initialPath: field == .parentFolder ? parentFolder : chosenFolder) { path in
                if field == .parentFolder {
                    parentFolder = path
                } else {
                    chosenFolder = path
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
    }

    // MARK: Fields

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { value in
            guard value != name else { return }
            name = value
            nameEdited = true
            followName()
        })
    }

    private var identifierBinding: Binding<String> {
        Binding(get: { identifier }, set: { value in
            guard value.uppercased() != identifier else { return }
            identifier = value.uppercased()
            identifierEdited = true
        })
    }

    private var folderNameBinding: Binding<String> {
        Binding(get: { folderName }, set: { value in
            guard value != folderName else { return }
            folderName = value
            folderNameEdited = true
        })
    }

    /// The identifier and the folder name follow the name until the user edits them.
    private func followName() {
        if !identifierEdited {
            identifier = ProjectRules.identifierSuggestion(from: name)
        }
        if !folderNameEdited {
            folderName = ProjectRules.folderNameSuggestion(from: name)
        }
    }

    private var identifierMessage: String? {
        ProjectRules.identifierMessage(identifier, projects: workspace.projects)
    }

    private var showsIdentifierMessage: Bool {
        identifierEdited || nameEdited || !identifier.isEmpty
    }

    /// The parent folder + `/` + the folder name, or the existing folder.
    private var projectFolder: String {
        switch mode {
        case .newFolder:
            return parentFolder.isEmpty ? "" : ProjectRules.join(parentFolder, folderName)
        case .existingFolder:
            return chosenFolder
        }
    }

    // MARK: Parent project (New Sub Project)

    private var selectedParent: ProjectSummary? {
        selectedParentID.flatMap { workspace.project($0) }
    }

    /// The active project's top-level project and all its descendants, indented by depth.
    private var parentItems: [IndentedPopUpButton.Item] {
        guard let parentID, let top = workspace.topLevelProject(of: parentID) else { return [] }
        return [IndentedPopUpButton.Item(tag: top.id, title: top.name)]
            + workspace.descendants(of: top.id).map { IndentedPopUpButton.Item(tag: $0.project.id, title: $0.project.name, indentation: $0.depth) }
    }

    /// In New Folder mode the parent folder starts at the parent project's root, and choosing
    /// another parent moves it to that parent's root (docs/projects.md › Sub projects).
    private func selectParent(_ id: String) {
        guard id != selectedParentID else { return }
        selectedParentID = id
        if let root = workspace.project(id)?.rootPath {
            parentFolder = root
        }
    }

    /// `Choose a folder inside “<parent name>”.` while the folder breaks the sub project
    /// constraint: in New Folder mode the parent folder is the parent's root or inside it; in
    /// Existing Folder mode the folder is strictly inside the parent's root.
    private var parentConstraintMessage: String? {
        guard let parent = selectedParent else { return nil }
        switch mode {
        case .newFolder:
            guard !parentFolder.isEmpty, !ProjectRules.isInside(parentFolder, root: parent.rootPath, strictly: false) else { return nil }
        case .existingFolder:
            guard !chosenFolder.isEmpty, !ProjectRules.isInside(chosenFolder, root: parent.rootPath, strictly: true) else { return nil }
        }
        return "Choose a folder inside “\(parent.name)”."
    }

    /// The note of a project folder inside a loaded project; the New Sub Project sheet shows none
    /// (docs/projects.md › Creating a project).
    private var insideNote: String? {
        guard !isSubProject, !projectFolder.isEmpty,
              let owner = ProjectRules.innermostProject(containing: projectFolder, in: workspace.projects) else { return nil }
        return "This folder is inside “\(owner.name)”: the new project becomes its sub project."
    }

    // MARK: Validity

    private var canCreate: Bool {
        guard ProjectRules.nameMessage(name) == nil, identifierMessage == nil, parentConstraintMessage == nil else { return false }
        if isSubProject, selectedParent == nil { return false }
        switch mode {
        case .newFolder:
            return !parentFolder.isEmpty && ProjectRules.folderNameMessage(folderName) == nil
        case .existingFolder:
            return !chosenFolder.isEmpty
        }
    }

    // MARK: Actions

    /// Initial values (docs/projects.md › Creating a project): the parent folder is the folder that
    /// contains the root of the active project's top-level project, or the device's home folder;
    /// for a sub project, the parent project's root.
    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        selectedParentID = parentID
        if let existingFolder {
            mode = .existingFolder
            chosenFolder = existingFolder
            name = ProjectRules.lastComponent(of: existingFolder)
            followName()
        }
        if let parentID, let parent = workspace.project(parentID) {
            parentFolder = parent.rootPath
        } else if let active = window.projectID, let top = workspace.topLevelProject(of: active) {
            parentFolder = ProjectRules.parentFolder(of: top.rootPath)
        } else if workspace.isLocal {
            parentFolder = NSHomeDirectory()
        } else {
            do {
                parentFolder = try await workspace.call(FSBrowse.self, FSBrowse.Params()).path
            } catch {
                failure = errorMessage(error)
            }
        }
    }

    /// `Choose…`: an open panel as a sheet of this sheet on This Mac, the Choose Folder sheet on a
    /// remote device.
    private func choose(_ field: FolderField) {
        guard workspace.isLocal else {
            remotePicker = field
            return
        }
        let current = field == .parentFolder ? parentFolder : chosenFolder
        Task {
            guard let path = await ShellPanels.chooseFolder(on: hostWindow.window, prompt: "Choose", canCreateDirectories: true,
                                                            directory: current.isEmpty ? nil : current) else { return }
            if field == .parentFolder {
                parentFolder = path
            } else {
                chosenFolder = path
            }
        }
    }

    private func close() {
        window.sheet = nil
    }

    private func create() {
        guard canCreate, !working else { return }
        let params = ProjectsCreate.Params(rootPath: projectFolder, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                           identifier: identifier, parentID: selectedParentID,
                                           createDirectory: mode == .newFolder)
        run {
            try await workspace.call(ProjectsCreate.self, params)
        }
    }

    /// `Open It` after the conflict of a folder that already contains a project.
    private func openExisting() {
        let path = projectFolder
        run {
            try await workspace.call(ProjectsOpen.self, ProjectsOpen.Params(rootPath: path))
        }
    }

    /// Runs a call that creates or opens a project: on success the sheet closes and the window
    /// activates the project; on failure the message shows under the fields.
    private func run(_ call: @escaping () async throws -> ProjectDetail) {
        working = true
        failure = nil
        offersOpen = false
        Task {
            defer { working = false }
            do {
                let detail = try await call()
                window.sheet = nil
                window.activate(projectID: detail.project.id)
            } catch {
                let message = errorMessage(error)
                failure = message
                offersOpen = (error as? EngineError)?.code == .conflict && message.hasSuffix("already contains a project; open it instead.")
            }
        }
    }
}

/// A read-only path in SF Mono, truncated in the middle.
struct PathText: View {
    let path: String

    var body: some View {
        Text(path.isEmpty ? " " : path)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
    }
}
