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
            ScrollView {
                ProjectSettingsForm(workspace: workspace, detail: detail)
                    // A new active project starts from its own stored values.
                    .id(projectID)
            }
        } else {
            LoadingStateView(text: "Loading \(workspace.project(projectID)?.name ?? projectID)…")
                .onAppear {
                    workspace.ensureProjectLoaded(projectID)
                }
        }
    }
}

/// The header and the fields of the section.
private struct ProjectSettingsForm: View {
    let workspace: DeviceWorkspace
    let detail: ProjectDetail

    @State private var typeFailure: String?
    @State private var chatDefaultsFailure: String?

    private var project: Project { detail.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
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
                }
                row("Docs folder") {
                    ProjectSettingsTextField(title: "Docs folder", prompt: "docs", monospaced: true, value: project.docsPath,
                                             validate: { ProjectRules.docsPathMessage($0) }) { path in
                        await update(ProjectsUpdate.Params(projectID: project.id, docsPath: path))
                    }
                }
                row("Build command") {
                    commandField(.build, placeholder: "make build")
                }
                row("Run command") {
                    commandField(.run, placeholder: "make run")
                }
                row("Test command") {
                    commandField(.test, placeholder: "make test")
                }
                row("Chat defaults") {
                    chatDefaults
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

    /// The project's name and identifier.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(project.name)
                .font(.title2.weight(.semibold))
            Text(project.id)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A single-line command field in SF Mono; empty means not set. It applies the whole
    /// `ProjectCommands` with the changed command and the two stored ones.
    private func commandField(_ kind: RunKind, placeholder: String) -> some View {
        ProjectSettingsTextField(title: placeholder, prompt: placeholder, monospaced: true,
                                 value: Self.command(kind, of: project.commands) ?? "",
                                 normalize: { ModelRules.normalizedCommand(Self.singleLine($0)) ?? "" }) { text in
            var commands = ProjectCommands(build: project.commands.build, run: project.commands.run, test: project.commands.test)
            let value = text.isEmpty ? nil : text
            switch kind {
            case .build: commands.build = value
            case .run: commands.run = value
            case .test: commands.test = value
            }
            return await update(ProjectsUpdate.Params(projectID: project.id, commands: commands))
        }
    }

    private static func command(_ kind: RunKind, of commands: ProjectCommands) -> String? {
        switch kind {
        case .build: return commands.build
        case .run: return commands.run
        case .test: return commands.test
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
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

/// A text field of the section, applied on Return or when it loses the focus. Its validation
/// message shows under it while the text is invalid, and an invalid value is not applied; a value
/// equal to the stored one is not applied either. While it is not focused, it shows the stored
/// value again whenever that value changes.
private struct ProjectSettingsTextField: View {
    let title: String
    var prompt: String?
    var monospaced = false
    let value: String
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
        FieldMessage(text: validate(text) ?? failure)
    }

    private func commit() {
        guard validate(text) == nil else { return }
        let normalized = normalize(text)
        guard normalized != value else { return }
        Task {
            failure = await apply(normalized)
        }
    }
}
