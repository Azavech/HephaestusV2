// OWNER: ui-shell — the Project Settings section (docs/projects.md › Project settings).
import AppKit
import HephaestusCore
import SwiftUI

/// Project Settings of the window's active project, in the centre column. Each field applies on
/// its own with `projects.update` and that field only; there is no Save.
struct ProjectSettingsView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    var body: some View {
        if let detail = workspace.details[projectID] {
            VStack(spacing: 0) {
                // The section's pane header stays at the top while the fields scroll
                // (docs/ui.md › Pane headers).
                ProjectSettingsHeader(project: detail.project)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 640, alignment: .leading)
                    .paneHeaderBar()
                Divider()
                ScrollView {
                    ProjectSettingsForm(window: window, workspace: workspace, detail: detail)
                        // A new active project starts from its own stored values.
                        .id(projectID)
                }
            }
        } else {
            LoadingStateView(text: "Loading \(workspace.project(projectID)?.name ?? projectID)…")
                .onAppear {
                    workspace.ensureProjectLoaded(projectID)
                }
        }
    }
}

/// The section's header: the project's name and identifier.
private struct ProjectSettingsHeader: View {
    let project: Project

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(project.name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(project.id)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// The fields of the section.
private struct ProjectSettingsForm: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let detail: ProjectDetail

    @State private var typeFailure: String?
    @State private var parentSettingsFailure: String?
    @State private var chatDefaultsFailure: String?

    private var project: Project { detail.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                row("Name") {
                    ProjectSettingsTextField(title: "Name", value: project.name,
                                             validate: { ProjectRules.nameMessage($0) },
                                             normalize: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) { name in
                        await update(ProjectsUpdate.Params(projectID: project.id, name: name))
                    }
                }
                row("Identifier") {
                    Text(project.id)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("The identifier is set at creation and cannot be changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                row("Project type") {
                    ProjectTypeMenu(selection: typeBinding)
                    FieldMessage(text: typeFailure)
                }
                row("Color") {
                    ProjectColorField(value: project.color) { color in
                        await update(ProjectsUpdate.Params(projectID: project.id, color: color.map { .set($0) } ?? .clear))
                    }
                }
                row("Icon") {
                    ProjectIconField(value: project.icon) { icon in
                        await update(ProjectsUpdate.Params(projectID: project.id, icon: icon.map { .set($0) } ?? .clear))
                    }
                }
                row("Folder") {
                    HStack(spacing: 8) {
                        PathText(path: detail.rootPath)
                        Spacer(minLength: 0)
                        if workspace.isLocal {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: detail.rootPath)])
                            }
                        }
                    }
                }
                if let parentID = detail.parentID {
                    row("Parent") {
                        Text("\(workspace.project(parentID)?.name ?? parentID) (\(parentID))")
                    }
                    row("") {
                        Toggle("Use parent settings", isOn: parentSettingsBinding)
                            .toggleStyle(.checkbox)
                        FieldMessage(text: parentSettingsFailure)
                    }
                }
                row("Docs folder") {
                    ProjectSettingsTextField(title: "Docs folder", prompt: "docs", monospaced: true, value: project.docsPath,
                                             validate: { ProjectRules.docsPathMessage($0) }) { path in
                        await update(ProjectsUpdate.Params(projectID: project.id, docsPath: path))
                    }
                }
                row("GitHub page") {
                    githubPageField
                }
                row("Chat defaults") {
                    chatDefaults
                }
                if project.type == .goService {
                    // The list has no text baseline: the label aligns with its top.
                    row("Environments", alignment: .top) {
                        ProjectEnvironmentsPart(window: window, projectID: project.id, environments: project.environments) { environments in
                            await update(ProjectsUpdate.Params(projectID: project.id, environments: environments))
                        }
                    }
                }
                if !detail.subprojects.isEmpty {
                    row("Sub projects") {
                        ForEach(detail.subprojects, id: \.id) { sub in
                            HStack(spacing: 8) {
                                Text(sub.name)
                                Text(sub.id)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(ProjectRules.relativePath(sub.rootPath, to: detail.rootPath))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Layout

    private func row<Content: View>(_ label: String, alignment: VerticalAlignment? = nil,
                                    @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: alignment) {
            Text(label)
                .gridColumnAlignment(.trailing)
                .padding(.top, alignment == .top ? 4 : 0)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// True for a sub project whose `Use parent settings` is on (docs/projects.md › Sub projects).
    private var usesParentSettings: Bool {
        detail.parentID != nil && project.useParentSettings
    }

    /// The GitHub page field in SF Mono, whose placeholder is the origin's page; an empty field
    /// removes the page. While the project uses its parent's settings it shows the parent's page,
    /// disabled (docs/projects.md › Project settings).
    @ViewBuilder private var githubPageField: some View {
        if usesParentSettings {
            TextField("GitHub page", text: .constant(detail.githubPage ?? ""), prompt: Text(""))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .disabled(true)
        } else {
            ProjectSettingsTextField(title: "GitHub page", prompt: detail.originGithubPage, monospaced: true,
                                     value: project.githubPage ?? "", writesBack: true,
                                     validate: { ProjectRules.githubPageMessage($0) },
                                     normalize: { ProjectRules.normalizedGithubPage($0) }) { page in
                await update(ProjectsUpdate.Params(projectID: project.id, githubPage: page.isEmpty ? .clear : .set(page)))
            }
        }
    }

    /// The toggle and, when it is off, the chat settings menus; each change applies `chatDefaults`.
    private var chatDefaults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use the defaults of \(workspace.deviceName)", isOn: Binding(get: { project.chatDefaults == nil }, set: { on in
                // Turning the toggle off starts from the device's `defaultChatSettings`.
                applyChatDefaults(on ? nil : workspace.settings?.defaultChatSettings ?? ChatSettings())
            }))
            if let settings = project.chatDefaults {
                let menus = ChatSettingsMenus(settings: settings, models: workspace.models) { applyChatDefaults($0) }
                HStack(spacing: 10) {
                    ChatModelMenuButton(menus: menus)
                    ChatEffortMenuButton(menus: menus)
                    ChatPermissionsMenuButton(menus: menus)
                }
                .fixedSize()
            }
            FieldMessage(text: chatDefaultsFailure)
        }
    }

    // MARK: Actions

    /// The menu applies its value as soon as it changes.
    private var typeBinding: Binding<ProjectType> {
        Binding(get: { project.type }, set: { type in
            guard type != project.type else { return }
            Task {
                typeFailure = await update(ProjectsUpdate.Params(projectID: project.id, type: type))
            }
        })
    }

    /// The `Use parent settings` checkbox applies its state as soon as it changes.
    private var parentSettingsBinding: Binding<Bool> {
        Binding(get: { project.useParentSettings }, set: { on in
            guard on != project.useParentSettings else { return }
            Task {
                parentSettingsFailure = await update(ProjectsUpdate.Params(projectID: project.id, useParentSettings: on))
            }
        })
    }

    /// `chatDefaults` as the chosen settings, or `null` for the device's defaults.
    private func applyChatDefaults(_ settings: ChatSettings?) {
        guard settings != project.chatDefaults else { return }
        Task {
            chatDefaultsFailure = await update(ProjectsUpdate.Params(projectID: project.id,
                                                                     chatDefaults: settings.map { .set($0) } ?? .clear))
        }
    }

    /// `projects.update`; returns the engine's message, or nil on success.
    private func update(_ params: ProjectsUpdate.Params) async -> String? {
        do {
            _ = try await workspace.call(ProjectsUpdate.self, params)
            return nil
        } catch {
            return errorMessage(error)
        }
    }
}

/// The Environments part of a Go service project: the list of its environments, then `+`, `Edit`
/// and `−`. The sheets apply their change themselves; `−` applies the list without the selected
/// environment at once (docs/projects.md › Environments).
private struct ProjectEnvironmentsPart: View {
    let window: WindowState
    let projectID: String
    let environments: [ProjectEnvironment]
    /// Applies a new list; returns the engine's message, or nil on success.
    let apply: ([ProjectEnvironment]) async -> String?

    /// The selected environment's name.
    @State private var selection: String?
    @State private var failure: String?

    /// The selected environment, while the list still has it.
    private var selected: ProjectEnvironment? {
        selection.flatMap { name in environments.first { $0.name == name } }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(environments.enumerated()), id: \.offset) { _, environment in
                    HStack(spacing: 8) {
                        Text(environment.name)
                        Text(environment.baseURL)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(environment.name)
                }
            }
            .listStyle(.inset)
            .frame(height: 112)
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { names in
                // A double-click on a row edits its environment.
                if let name = names.first {
                    edit(name)
                }
            }
            Divider()
            HStack(spacing: 2) {
                Button {
                    window.sheet = .environment(projectID: projectID, name: nil)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 20)
                }
                Button("Edit") {
                    if let selected {
                        edit(selected.name)
                    }
                }
                .disabled(selected == nil)
                Button {
                    remove()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 20)
                }
                .disabled(selected == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: 26)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
        FieldMessage(text: failure)
    }

    private func edit(_ name: String) {
        window.sheet = .environment(projectID: projectID, name: name)
    }

    /// `−`: the list without the selected environment applies at once.
    private func remove() {
        guard let selected, let list = ProjectRules.environments(environments, removing: selected.name) else { return }
        Task {
            failure = await apply(list)
        }
    }
}

/// The New Environment sheet, or the Edit Environment sheet of the environment named `name`:
/// Name, URL, Port, kubectl context, Namespace, Deployment, Argo CD application and Kubeconfig file
/// with their messages, then `Cancel` and `Create` or `Save`. The change applies at once with
/// `projects.update` (docs/projects.md › Environments).
struct EnvironmentSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String
    /// True for Edit Environment.
    private let edits: Bool

    /// The edited environment as the sheet opened; nil for New Environment. Kept while the sheet
    /// is open, whatever happens to the list meanwhile.
    @State private var original: ProjectEnvironment?
    @State private var name: String
    @State private var url: String
    @State private var port: String
    @State private var context: String
    @State private var namespace: String
    @State private var deployment: String
    @State private var argoCDApplication: String
    @State private var kubeconfig: String
    @State private var nameEdited = false
    @State private var urlEdited = false
    @State private var portEdited = false
    @State private var argoCDApplicationEdited = false
    @State private var kubeconfigEdited = false
    @State private var working = false
    @State private var failure: String?

    init(window: WindowState, workspace: DeviceWorkspace, projectID: String, name: String?) {
        self.window = window
        self.workspace = workspace
        self.projectID = projectID
        let original = name.flatMap { name in
            workspace.details[projectID]?.project.environments.first { $0.name == name }
        }
        edits = name != nil
        _original = State(initialValue: original)
        _name = State(initialValue: original?.name ?? "")
        _url = State(initialValue: original?.url ?? "")
        _port = State(initialValue: original?.port.map(String.init) ?? "")
        _context = State(initialValue: original?.context ?? "")
        _namespace = State(initialValue: original?.namespace ?? "")
        _deployment = State(initialValue: original?.deployment ?? "")
        _argoCDApplication = State(initialValue: original?.argoCDApplication ?? "")
        _kubeconfig = State(initialValue: original?.kubeconfig ?? "")
    }

    /// The project's environments as they are now, which the change applies to.
    private var current: [ProjectEnvironment] {
        workspace.details[projectID]?.project.environments ?? []
    }

    private var nameMessage: String? {
        ProjectRules.environmentNameMessage(name, otherNames: ProjectRules.otherEnvironmentNames(current, editing: original))
    }

    private var urlMessage: String? { ProjectRules.environmentURLMessage(url) }
    private var portMessage: String? { ProjectRules.environmentPortMessage(port) }
    private var argoCDApplicationMessage: String? { ProjectRules.environmentArgoCDApplicationMessage(argoCDApplication) }
    private var kubeconfigMessage: String? { ProjectRules.environmentKubeconfigMessage(kubeconfig) }

    private var canConfirm: Bool {
        nameMessage == nil && urlMessage == nil && portMessage == nil && argoCDApplicationMessage == nil
            && kubeconfigMessage == nil && !working
    }

    var body: some View {
        if edits && original == nil {
            // The environment to edit was removed before the sheet opened: it closes at once.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    window.sheet = nil
                }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(edits ? "Edit Environment" : "New Environment")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Name")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $name, prompt: Text(""))
                            .labelsHidden()
                            .onChange(of: name) { nameEdited = true }
                        FieldMessage(text: nameEdited ? nameMessage : nil)
                    }
                }
                GridRow {
                    label("URL")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("URL", text: $url, prompt: Text(""))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: url) { urlEdited = true }
                        FieldMessage(text: urlEdited ? urlMessage : nil)
                    }
                }
                GridRow {
                    label("Port")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Port", text: $port, prompt: Text(""))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 100)
                            .onChange(of: port) { portEdited = true }
                        FieldMessage(text: portEdited ? portMessage : nil)
                    }
                }
                // The Kubernetes fields are optional: an empty field means not set.
                GridRow {
                    label("kubectl context")
                    monospacedField("kubectl context", text: $context)
                }
                GridRow {
                    label("Namespace")
                    monospacedField("Namespace", text: $namespace)
                }
                GridRow {
                    label("Deployment")
                    monospacedField("Deployment", text: $deployment)
                }
                GridRow {
                    label("Argo CD application")
                    VStack(alignment: .leading, spacing: 4) {
                        monospacedField("Argo CD application", text: $argoCDApplication)
                            .onChange(of: argoCDApplication) { argoCDApplicationEdited = true }
                        FieldMessage(text: argoCDApplicationEdited ? argoCDApplicationMessage : nil)
                    }
                }
                GridRow {
                    label("Kubeconfig file")
                    VStack(alignment: .leading, spacing: 4) {
                        monospacedField("Kubeconfig file", text: $kubeconfig)
                            .onChange(of: kubeconfig) { kubeconfigEdited = true }
                        FieldMessage(text: kubeconfigEdited ? kubeconfigMessage : nil)
                    }
                }
            }
            FieldMessage(text: failure)
            SheetButtonRow(defaultTitle: edits ? "Save" : "Create", defaultEnabled: canConfirm,
                           cancel: { window.sheet = nil }, confirm: confirm) {
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
    }

    /// A text field in SF Mono that fills its row.
    private func monospacedField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(""))
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
    }

    /// Create appends the environment; Save replaces the edited one at its place, keeping its
    /// unknown keys, or appends it when no environment has its name any more (renamed or removed
    /// meanwhile). The whole list applies at once; the sheet closes on success and shows the
    /// engine's message otherwise.
    private func confirm() {
        guard canConfirm else { return }
        let environment = ProjectRules.environment(name: name, url: url, port: port, context: context, namespace: namespace,
                                                   deployment: deployment, argoCDApplication: argoCDApplication,
                                                   kubeconfig: kubeconfig, editing: original)
        let list = ProjectRules.environments(current, saving: environment, replacing: original?.name)
        working = true
        Task {
            do {
                _ = try await workspace.call(ProjectsUpdate.self, ProjectsUpdate.Params(projectID: projectID, environments: list))
                window.sheet = nil
            } catch {
                failure = errorMessage(error)
            }
            working = false
        }
    }
}

/// The Color field: a color well in its expanded style, then a hex field in SF Mono. A color
/// chosen in the well or the color panel applies at once; the hex field applies on Return or when
/// it loses the focus, and an empty field removes the color. The well shows the field's hex color
/// while the field holds one, otherwise the stored color, or the gray of the default project badge
/// when there is none.
private struct ProjectColorField: View {
    /// The stored color, `#RRGGBB`; nil for none.
    let value: String?
    /// Applies a color, or nil to remove it; returns the engine's message, or nil on success.
    let apply: (String?) async -> String?

    @State private var text = ""
    @State private var failure: String?
    /// The last color chosen in the well that is not applied yet.
    @State private var chosen: String?
    @State private var applyingChosen = false
    @FocusState private var focused: Bool

    static let message = "Enter a color as #RRGGBB, for example #34C759."

    var body: some View {
        HStack(spacing: 8) {
            ColorWellView(color: wellColor, interact: {}, change: choose)
                .fixedSize()
            TextField("Color", text: $text, prompt: Text(""))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .frame(width: 110)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused {
                        commit()
                    }
                }
                .onChange(of: text) {
                    failure = nil
                }
            Spacer(minLength: 0)
        }
        .onAppear {
            text = value ?? ""
        }
        .onChange(of: value) { _, newValue in
            if !focused {
                text = newValue ?? ""
            }
        }
        FieldMessage(text: Self.validationMessage(text) ?? failure)
    }

    /// The red message of a hex field's text: nil for an empty field or a hex color.
    static func validationMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || ProjectColor.isValid(trimmed) ? nil : message
    }

    private var wellColor: NSColor {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = ProjectColor.isValid(typed) ? typed : value
        return shown.flatMap(ColorSwatches.nsColor) ?? NSColor(StatusCapsule.color(of: .todo))
    }

    /// A color chosen in the well or the panel: shown in the field and applied at once. Colors
    /// chosen while one applies are applied one after the other, the last one last.
    private func choose(_ hex: String) {
        text = hex
        chosen = hex
        guard !applyingChosen else { return }
        applyingChosen = true
        Task {
            while let next = chosen {
                chosen = nil
                failure = await apply(next)
            }
            applyingChosen = false
        }
    }

    /// Applies the hex field: a hex color in uppercase, written back in uppercase; nil for an
    /// empty field. An invalid value, or one equal to the stored color, is not applied.
    private func commit() {
        guard Self.validationMessage(text) == nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = trimmed.isEmpty ? nil : trimmed.uppercased()
        text = color ?? ""
        guard color != value else { return }
        Task {
            failure = await apply(color)
        }
    }
}

/// The layout of the Icon popover's grid: the 36 pt cells of the symbol card, 8 columns, at most 6
/// rows visible (docs/projects.md › Project settings).
enum ProjectIconGrid {
    static let columns = 8
    static let visibleRows = 6

    /// The cells: `None` (nil) first, then the search results in their order.
    static func cells(results: [String]) -> [String?] {
        [nil] + results
    }

    /// The width of the grid: its columns and the spaces between them.
    static var width: CGFloat {
        CGFloat(columns) * SymbolGrid.cell + CGFloat(columns - 1) * SymbolGrid.spacing
    }

    /// The height of the grid's visible area: its rows, at most `visibleRows`.
    static func height(count: Int) -> CGFloat {
        let rows = min(visibleRows, max(1, (count + columns - 1) / columns))
        return CGFloat(rows) * SymbolGrid.cell + CGFloat(rows - 1) * SymbolGrid.spacing
    }
}

/// The Icon field: a button showing the project's icon, or `folder` without one, that opens the
/// icon popover. A click on a cell closes the popover and applies at once; a click on the cell of
/// the stored choice only closes it.
private struct ProjectIconField: View {
    /// The stored icon; nil for none.
    let value: String?
    /// Applies an icon, or nil to remove it; returns the engine's message, or nil on success.
    let apply: (String?) async -> String?

    @State private var showsPopover = false
    @State private var failure: String?

    var body: some View {
        Button {
            showsPopover = true
        } label: {
            Image(systemName: ProjectRules.iconSymbol(value))
                .frame(width: 24)
        }
        .accessibilityLabel("Icon")
        .accessibilityValue(value ?? "None")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            ProjectIconPopover(current: value) { choice in
                showsPopover = false
                guard choice != value else { return }
                failure = nil
                Task {
                    failure = await apply(choice)
                }
            }
        }
        .onChange(of: value) {
            failure = nil
        }
        FieldMessage(text: failure)
    }
}

/// The icon popover: the `Search symbols` field, then the grid of `None` and the results of the
/// symbol search over the catalogue of this Mac (docs/chats.md › Symbol search); the cell of the
/// stored choice has the accent background.
private struct ProjectIconPopover: View {
    /// The stored icon; nil for none.
    let current: String?
    /// Called with the clicked cell: a symbol's name, or nil for `None`.
    let choose: (String?) -> Void

    @State private var search = ""
    @State private var results: [String] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        let cells = ProjectIconGrid.cells(results: results)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search symbols", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(SymbolGrid.cell), spacing: SymbolGrid.spacing),
                                         count: ProjectIconGrid.columns),
                          alignment: .leading, spacing: SymbolGrid.spacing) {
                    ForEach(cells, id: \.self) { name in
                        cell(name)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: ProjectIconGrid.width, height: ProjectIconGrid.height(count: cells.count))
        }
        .padding(12)
        .onAppear {
            searchFocused = true
        }
        .task(id: search) {
            // Off the main actor; a result that arrives after the query changed is dropped.
            let query = search
            let found = await Task.detached { SFSymbolCatalog.system.search(query) }.value
            if query == search {
                results = found
            }
        }
    }

    /// `None`, or a symbol centered with its name as tooltip; the stored choice on the accent color.
    @ViewBuilder
    private func cell(_ name: String?) -> some View {
        let isCurrent = name == current
        let button = Button {
            choose(name)
        } label: {
            Group {
                if let name {
                    Image(systemName: name)
                        .font(.system(size: 17))
                } else {
                    Text("None")
                        .font(.caption)
                }
            }
            .foregroundStyle(isCurrent ? Color.white : Color.primary)
            .frame(width: SymbolGrid.cell, height: SymbolGrid.cell)
            .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? "None")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        if let name {
            button.help(name)
        } else {
            button
        }
    }
}

/// A text field of the section, applied on Return or when it loses the focus. Its validation
/// message shows under it while the text is invalid, and an invalid value is not applied; a value
/// equal to the stored one is not applied either. While it is not focused, it shows the stored
/// value again whenever that value changes. With `writesBack`, a valid value shows normalized as
/// soon as it applies. A field removed while it holds a new value applies it, as when it loses
/// the focus.
private struct ProjectSettingsTextField: View {
    let title: String
    var prompt: String?
    var monospaced = false
    let value: String
    var writesBack = false
    var validate: (String) -> String? = { _ in nil }
    var normalize: (String) -> String = { $0 }
    /// Applies the normalized value; returns the engine's message, or nil on success.
    let apply: (String) async -> String?

    @State private var text = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt ?? ""))
            .labelsHidden()
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    commit()
                }
            }
            .onChange(of: text) {
                failure = nil
            }
            .onAppear {
                text = value
            }
            .onChange(of: value) { _, newValue in
                if !focused {
                    text = newValue
                }
            }
            .onDisappear(perform: commit)
        FieldMessage(text: validate(text) ?? failure)
    }

    private func commit() {
        guard validate(text) == nil else { return }
        let normalized = normalize(text)
        if writesBack {
            text = normalized
        }
        guard normalized != value else { return }
        Task {
            failure = await apply(normalized)
        }
    }
}
