// OWNER: ui-shell — the Project Settings sheet (docs/projects.md › Project settings).
import AppKit
import HephaestusCore
import SwiftUI

/// Project Settings of the window's active project; Save calls `projects.update` with the changed fields.
struct ProjectSettingsSheet: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let projectID: String

    /// The stored values the fields started from, replaced by each `project.updated`.
    private struct Stored: Equatable {
        var name: String
        var docsPath: String
        var build: String
        var run: String
        var test: String
        var chatDefaults: ChatSettings?

        init(_ project: Project) {
            name = project.name
            docsPath = project.docsPath
            build = project.commands.build ?? ""
            run = project.commands.run ?? ""
            test = project.commands.test ?? ""
            chatDefaults = project.chatDefaults
        }
    }

    @State private var stored: Stored?
    @State private var name = ""
    @State private var docsPath = ""
    @State private var build = ""
    @State private var run = ""
    @State private var test = ""
    @State private var usesDeviceDefaults = true
    @State private var chatSettings = ChatSettings()
    @State private var failure: String?
    @State private var working = false

    private var detail: ProjectDetail? {
        workspace.details[projectID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detail {
                header(detail)
                form(detail)
                FieldMessage(text: failure)
            } else {
                LoadingStateView(text: "Loading \(workspace.project(projectID)?.name ?? projectID)…")
                    .frame(height: 160)
            }
            SheetButtonRow(defaultTitle: "Save", defaultEnabled: canSave && !working, cancel: close, confirm: save) {
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            workspace.ensureProjectLoaded(projectID)
            refresh()
        }
        .onChange(of: detail?.project) {
            refresh()
        }
    }

    // MARK: Layout

    /// The project's name and identifier.
    private func header(_ detail: ProjectDetail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(detail.project.name)
                .font(.headline)
            Text(detail.project.id)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func form(_ detail: ProjectDetail) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                label("Name")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $name)
                        .labelsHidden()
                    FieldMessage(text: ProjectRules.nameMessage(name))
                }
            }
            GridRow {
                label("Identifier")
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.project.id)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("The identifier is set at creation and cannot be changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                label("Folder")
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
                GridRow {
                    label("Parent")
                    Text("\(workspace.project(parentID)?.name ?? parentID) (\(parentID))")
                }
            }
            GridRow {
                label("Docs folder")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Docs folder", text: $docsPath, prompt: Text("docs"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    FieldMessage(text: ProjectRules.docsPathMessage(docsPath))
                }
            }
            GridRow {
                label("Build command")
                commandField($build, placeholder: "make build")
            }
            GridRow {
                label("Run command")
                commandField($run, placeholder: "make run")
            }
            GridRow {
                label("Test command")
                commandField($test, placeholder: "make test")
            }
            GridRow {
                label("Chat defaults")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use the defaults of \(workspace.deviceName)", isOn: usesDeviceDefaultsBinding)
                    if !usesDeviceDefaults {
                        ChatSettingsMenus(settings: chatSettings, models: workspace.models) { chatSettings = $0 }
                    }
                }
            }
            if !detail.subprojects.isEmpty {
                GridRow {
                    label("Sub projects")
                    VStack(alignment: .leading, spacing: 4) {
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
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
    }

    /// A single-line command field in SF Mono; empty means not set.
    private func commandField(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: Binding(get: { text.wrappedValue }, set: { value in
            text.wrappedValue = value.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }), prompt: Text(placeholder))
        .labelsHidden()
        .font(.system(.body, design: .monospaced))
    }

    /// The toggle is on when `chatDefaults` is absent; turning it off starts from the device's
    /// `defaultChatSettings`.
    private var usesDeviceDefaultsBinding: Binding<Bool> {
        Binding(get: { usesDeviceDefaults }, set: { value in
            usesDeviceDefaults = value
            if !value {
                chatSettings = workspace.settings?.defaultChatSettings ?? ChatSettings()
            }
        })
    }

    // MARK: Values

    /// The chat defaults the fields describe: nil while the toggle is on.
    private var chosenChatDefaults: ChatSettings? {
        usesDeviceDefaults ? nil : chatSettings
    }

    private var nameChanged: Bool { stored.map { name != $0.name } ?? false }
    private var docsPathChanged: Bool { stored.map { docsPath != $0.docsPath } ?? false }
    private var commandsChanged: Bool { stored.map { build != $0.build || run != $0.run || test != $0.test } ?? false }
    private var chatDefaultsChanged: Bool { stored.map { chosenChatDefaults != $0.chatDefaults } ?? false }

    /// Save is enabled when a field changed and every field is valid.
    private var canSave: Bool {
        guard stored != nil, nameChanged || docsPathChanged || commandsChanged || chatDefaultsChanged else { return false }
        return ProjectRules.nameMessage(name) == nil && ProjectRules.docsPathMessage(docsPath) == nil
    }

    /// While the sheet is open, `project.updated` refreshes the fields the user has not edited;
    /// the edited fields keep the user's values.
    private func refresh() {
        guard let project = detail?.project else { return }
        let new = Stored(project)
        guard new != stored else { return }
        let old = stored
        if old == nil || name == old?.name { name = new.name }
        if old == nil || docsPath == old?.docsPath { docsPath = new.docsPath }
        if old == nil || (build == old?.build && run == old?.run && test == old?.test) {
            build = new.build
            run = new.run
            test = new.test
        }
        if old == nil || chosenChatDefaults == old?.chatDefaults {
            usesDeviceDefaults = new.chatDefaults == nil
            chatSettings = new.chatDefaults ?? workspace.settings?.defaultChatSettings ?? ChatSettings()
        }
        stored = new
    }

    // MARK: Actions

    private func close() {
        window.sheet = nil
    }

    /// `projects.update` with `projectID` and only the changed fields.
    private func save() {
        guard canSave, !working else { return }
        var params = ProjectsUpdate.Params(projectID: projectID)
        if nameChanged {
            params.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if docsPathChanged {
            params.docsPath = docsPath
        }
        if commandsChanged {
            params.commands = ProjectCommands(build: ModelRules.normalizedCommand(build), run: ModelRules.normalizedCommand(run),
                                              test: ModelRules.normalizedCommand(test))
        }
        if chatDefaultsChanged {
            params.chatDefaults = chosenChatDefaults.map { .set($0) } ?? .clear
        }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                _ = try await workspace.call(ProjectsUpdate.self, params)
                window.sheet = nil
            } catch {
                failure = errorMessage(error)
            }
        }
    }
}
