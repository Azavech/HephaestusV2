// OWNER: ui-shell — the Environments section of Project Settings (docs/projects.md ›
// Environments, › Inherited environments).
import AppKit
import HephaestusCore
import SwiftUI

/// The Environments section at the bottom of Project Settings of a Go service: a separator, the
/// `Environments` heading, then the rows of the selected environment, which edit it in place. Its
/// rows join the grid of the form, so that they use its label column. Each field applies on its
/// own; `+` and `−` apply at once (docs/projects.md › Environments). For an environment the
/// project inherits, Deployment, URL, Port and `Allow invalid certificates` change it for the
/// project only, and the other fields show the parent's values, disabled (docs/projects.md ›
/// Inherited environments).
struct ProjectEnvironmentsSection: View {
    let workspace: DeviceWorkspace
    let detail: ProjectDetail
    /// The name of the parent the inherited environments come from.
    let parentName: String
    /// `projects.update`; returns the engine's message, or nil on success.
    let update: (ProjectsUpdate.Params) async -> String?

    /// The name of the selected environment.
    @State private var selection: String?
    /// The environment to select once the project's environments have its name: the one `+`
    /// added, or the selected one after a rename.
    @State private var pending: PendingSelection?
    /// Changes whenever another environment is selected, so that its fields start from its
    /// values; a rename keeps it.
    @State private var identity = UUID()
    /// Set when `+` added an environment: its Name field takes the keyboard focus.
    @State private var focusesName = false
    @State private var listFailure: String?
    @State private var nameMessage: String?
    @State private var kubeconfigMessage: String?
    @State private var browseFailure: String?
    @State private var namespaceMessage: String?
    @State private var deploymentMessage: String?
    @State private var urlMessage: String?
    @State private var portMessage: String?
    @State private var certificatesMessage: String?
    @State private var connection = KubeconfigConnection.none
    @State private var namespaces: [String] = []
    @State private var deployments: [String] = []
    @State private var hostWindow = HostWindow()

    private var projectID: String { detail.project.id }

    /// The project's detail as the workspace holds it now: the code that runs after a call reads
    /// it there, not in the copy of the view that started the call.
    private var current: ProjectDetail { workspace.details[projectID] ?? detail }

    /// The project's environments as they apply, the inherited ones first.
    private var environments: [ProjectEnvironment] { current.environments }

    private var names: [String] { environments.map(\.name) }

    private var inheritedNames: Set<String> { Set(current.inheritedEnvironments.map(\.name)) }

    /// The selected environment: the one of `selection`, else the pending one, else the project's
    /// current working environment, which the section opens on.
    private var selected: ProjectEnvironment? {
        for name in [selection, pending?.name].compactMap({ $0 }) {
            if let match = environments.first(where: { $0.name == name }) {
                return match
            }
        }
        return current.currentWorkingEnvironment
    }

    private func isInherited(_ environment: ProjectEnvironment) -> Bool {
        inheritedNames.contains(environment.name)
    }

    /// The project's own environments as they are now, which a change applies to.
    private var currentOwn: [ProjectEnvironment] { current.project.environments }

    var body: some View {
        Divider()
            .padding(.top, 8)
        Text("Environments")
            .font(.headline)
        row("Environment", message: listFailure) {
            environmentRow
        }
        if let environment = selected {
            if isInherited(environment) {
                inheritedRows(environment)
            } else {
                ownRows(environment)
            }
        }
    }

    // MARK: Layout

    private func row<Content: View>(_ label: String, message: String? = nil, topPadding: CGFloat = 0,
                                    @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .padding(.top, topPadding)
            VStack(alignment: .leading, spacing: 4) {
                content()
                FieldMessage(text: message)
            }
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The additional vertical space before API Access.
    private static let apiAccessSpace: CGFloat = 10

    /// The pop-up of the environments by name, `+` and `−`, and the mark of an inherited
    /// environment. The section's selection and kubectl work hang on this row, which always shows.
    private var environmentRow: some View {
        let environment = selected
        let inherited = environment.map(isInherited) ?? false
        return HStack(spacing: 6) {
            Picker("Environment", selection: Binding(get: { environment?.name }, set: { name in
                guard let name, name != environment?.name else { return }
                select(name)
            })) {
                ForEach(names, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
                if names.isEmpty {
                    // The empty pop-up's selection, so that it has a tag.
                    Text("").tag(String?.none)
                }
            }
            .labelsHidden()
            // Sized to its longest name, so that `+` and `−` follow it.
            .fixedSize()
            .disabled(names.isEmpty)
            Group {
                Button(action: add) {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 18)
                }
                .accessibilityLabel("+")
                Button(action: remove) {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 18)
                }
                .accessibilityLabel("−")
                .disabled(environment == nil || inherited)
            }
            .buttonStyle(.borderless)
            if inherited {
                Text("Inherited from \(parentName)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: syncSelection)
        .onChange(of: names) { syncSelection() }
        .onChange(of: identity) {
            // The combo boxes of another environment start without the failures of this one.
            browseFailure = nil
            listFailure = nil
            namespaceMessage = nil
            deploymentMessage = nil
            certificatesMessage = nil
        }
        .task(id: ConnectionKey(identity: identity, kubeconfig: environment?.kubeconfig)) {
            await checkConnection(environment?.kubeconfig)
        }
        .task(id: DeploymentsKey(identity: identity, kubeconfig: environment?.kubeconfig, namespace: environment?.namespace,
                                 connected: connection == .connected)) {
            await readDeployments(kubeconfig: environment?.kubeconfig, namespace: environment?.namespace)
        }
        .readsHostWindow(hostWindow)
    }

    /// The rows of an environment of the project's own.
    @ViewBuilder
    private func ownRows(_ environment: ProjectEnvironment) -> some View {
        let name = environment.name
        row("Name", message: nameMessage) {
            EnvironmentTextField(title: "Name", monospaced: false, value: name,
                                 validate: { ProjectRules.environmentNameMessage($0, otherNames: otherNames(name)) },
                                 message: $nameMessage, focusRequest: $focusesName) { text in
                await applyOwn(name, renamingTo: text) { $0.name = text }
            }
            .id(identity)
        }
        row("Kubeconfig file", message: kubeconfigMessage ?? browseFailure ?? connection.failure) {
            HStack(spacing: 8) {
                EnvironmentTextField(title: "Kubeconfig file", value: environment.kubeconfig ?? "",
                                     validate: ProjectRules.environmentKubeconfigMessage, message: $kubeconfigMessage) { text in
                    await applyOwn(name) { $0.kubeconfig = ModelRules.trimmedOrNil(text) }
                }
                .id(identity)
                if workspace.isLocal {
                    Button("Browse…") {
                        browse(for: name, stored: environment.kubeconfig)
                    }
                }
                connectionDot(environment)
            }
        }
        row("Namespace", message: namespaceMessage) {
            EnvironmentComboBox(title: "Namespace", value: environment.namespace ?? "", items: namespaces,
                                message: $namespaceMessage) { text in
                await applyOwn(name) { $0.namespace = ModelRules.trimmedOrNil(text) }
            }
            .id(identity)
        }
        row("Deployment", message: deploymentMessage) {
            EnvironmentComboBox(title: "Deployment", value: environment.deployment ?? "", items: deployments,
                                message: $deploymentMessage) { text in
                await applyOwn(name) { $0.deployment = ModelRules.trimmedOrNil(text) }
            }
            .id(identity)
        }
        row("API Access", message: urlMessage ?? portMessage, topPadding: Self.apiAccessSpace) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                EnvironmentTextField(title: "URL", value: environment.url ?? "", validate: ProjectRules.environmentURLMessage,
                                     message: $urlMessage) { text in
                    await applyOwn(name) { $0.url = ModelRules.trimmedOrNil(text) }
                }
                .id(identity)
                Text(":")
                EnvironmentTextField(title: "Port", value: environment.port.map(String.init) ?? "",
                                     validate: ProjectRules.environmentPortMessage,
                                     normalize: ProjectRules.normalizedEnvironmentPort, message: $portMessage) { text in
                    await applyOwn(name) { $0.port = ProjectRules.environmentPort(text) }
                }
                .frame(width: 80)
                .id(identity)
            }
        }
        certificatesRow(isOn: environment.allowInvalidCertificates) { on in
            await applyOwn(name) { $0.allowInvalidCertificates = on }
        }
    }

    /// The rows of an inherited environment: Name, Kubeconfig file and Namespace show the parent's
    /// values, disabled; Deployment, URL and Port show the project's change, with the parent's
    /// value as placeholder, and apply `environmentOverrides`.
    @ViewBuilder
    private func inheritedRows(_ environment: ProjectEnvironment) -> some View {
        let name = environment.name
        let parent = current.inheritedEnvironments.first { $0.name == name } ?? environment
        let change = current.project.environmentOverrides[name]
        row("Name") {
            TextField("Name", text: .constant(parent.name), prompt: Text(""))
                .labelsHidden()
                .disabled(true)
        }
        row("Kubeconfig file", message: connection.failure) {
            HStack(spacing: 8) {
                TextField("Kubeconfig file", text: .constant(parent.kubeconfig ?? ""), prompt: Text(""))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .disabled(true)
                if workspace.isLocal {
                    Button("Browse…") {}
                        .disabled(true)
                }
                connectionDot(environment)
            }
        }
        row("Namespace") {
            EnvironmentComboBox(title: "Namespace", value: parent.namespace ?? "", items: [], isEnabled: false,
                                message: .constant(nil)) { _ in nil }
                .id(identity)
        }
        row("Deployment", message: deploymentMessage) {
            EnvironmentComboBox(title: "Deployment", value: change?.deployment ?? "", items: deployments,
                                placeholder: parent.deployment ?? "", message: $deploymentMessage) { text in
                await applyOverride(name) { $0.deployment = ModelRules.trimmedOrNil(text) }
            }
            .id(identity)
        }
        row("API Access", message: urlMessage ?? portMessage, topPadding: Self.apiAccessSpace) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                EnvironmentTextField(title: "URL", prompt: parent.url, value: change?.url ?? "",
                                     validate: ProjectRules.environmentURLMessage, message: $urlMessage) { text in
                    await applyOverride(name) { $0.url = ModelRules.trimmedOrNil(text) }
                }
                .id(identity)
                Text(":")
                EnvironmentTextField(title: "Port", prompt: parent.port.map(String.init), value: change?.port.map(String.init) ?? "",
                                     validate: ProjectRules.environmentPortMessage,
                                     normalize: ProjectRules.normalizedEnvironmentPort, message: $portMessage) { text in
                    await applyOverride(name) { $0.port = ProjectRules.environmentPort(text) }
                }
                .frame(width: 80)
                .id(identity)
            }
        }
        certificatesRow(isOn: change?.allowInvalidCertificates ?? parent.allowInvalidCertificates) { on in
            await applyOverride(name) {
                $0.allowInvalidCertificates = ProjectRules.allowInvalidCertificatesChange(on, parent: parent.allowInvalidCertificates)
            }
        }
    }

    /// The `Allow invalid certificates` checkbox, on its own line in the field column under API
    /// Access; it applies at once when toggled, and an engine failure shows under it.
    private func certificatesRow(isOn: Bool, apply: @escaping (Bool) async -> String?) -> some View {
        row("", message: certificatesMessage) {
            Toggle("Allow invalid certificates", isOn: Binding(get: { isOn }, set: { on in
                guard on != isOn else { return }
                Task {
                    certificatesMessage = await apply(on)
                }
            }))
            .toggleStyle(.checkbox)
        }
    }

    /// Nothing without a kubeconfig file; a small spinner while the connection is checked, then a
    /// green or a red dot, as the Claude CLI status of Settings › General.
    @ViewBuilder
    private func connectionDot(_ environment: ProjectEnvironment) -> some View {
        if environment.kubeconfig != nil {
            switch connection {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking the connection")
            case .connected:
                StatusDot(color: .green)
                    .accessibilityLabel("Connected")
            case .failed:
                StatusDot(color: .red)
                    .accessibilityLabel("Not connected")
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: Selection

    /// Keeps the selection on an environment the project has: the pending one once it is there,
    /// else the first one when the selected one was removed or renamed elsewhere. The section
    /// opens on the project's current working environment; the pop-up does not change it
    /// (docs/projects.md › Environments).
    private func syncSelection() {
        if let pending, names.contains(pending.name) {
            selection = pending.name
            if pending.newIdentity {
                identity = UUID()
            }
            if pending.focusesName {
                focusesName = true
            }
            self.pending = nil
            return
        }
        guard pending == nil else { return }
        if let selection, names.contains(selection) { return }
        if selection != nil {
            identity = UUID()
            selection = names.first
        } else {
            selection = current.currentWorkingEnvironment?.name
        }
    }

    /// An environment chosen in the pop-up.
    private func select(_ name: String) {
        selection = name
        identity = UUID()
    }

    // MARK: Actions

    /// `+`: a new environment at the end of the project's own, named `New Environment` or the
    /// first free numbered name; once it is there it is selected and its Name field focused.
    private func add() {
        let own = currentOwn
        let name = ProjectRules.newEnvironmentName(taken: own.map(\.name) + current.inheritedEnvironments.map(\.name))
        pending = PendingSelection(name: name, newIdentity: true, focusesName: true)
        Task {
            listFailure = await update(ProjectsUpdate.Params(projectID: projectID,
                                                             environments: ProjectRules.environments(own, adding: name)))
            finishPending(failed: listFailure != nil)
        }
    }

    /// `−`: the list without the selected environment applies at once; the first of the other
    /// environments is then selected.
    private func remove() {
        guard let environment = selected, !isInherited(environment),
              let list = ProjectRules.environments(currentOwn, removing: environment.name) else { return }
        Task {
            listFailure = await update(ProjectsUpdate.Params(projectID: projectID, environments: list))
            if listFailure == nil {
                selection = names.first { $0 != environment.name }
                identity = UUID()
            }
        }
    }

    /// The pending selection after its call: dropped when the call failed, applied when the
    /// environments already have its name.
    private func finishPending(failed: Bool) {
        if failed {
            pending = nil
        } else {
            syncSelection()
        }
    }

    /// The names the Name field of the environment `name` must not take.
    private func otherNames(_ name: String) -> [String] {
        let own = currentOwn
        return ProjectRules.otherEnvironmentNames(own, inherited: current.inheritedEnvironments,
                                                  editing: own.first { $0.name == name })
    }

    /// A field of an environment of the project's own: the whole list of its own environments with
    /// the change applied. A rename keeps the environment selected under its new name.
    private func applyOwn(_ name: String, renamingTo newName: String? = nil,
                          _ change: (inout ProjectEnvironment) -> Void) async -> String? {
        guard let list = ProjectRules.environments(currentOwn, changing: name, change) else { return nil }
        let renamed = newName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0 == name ? nil : $0 }
        if let renamed, selection == name || selection == nil {
            pending = PendingSelection(name: renamed, newIdentity: false, focusesName: false)
        }
        let failure = await update(ProjectsUpdate.Params(projectID: projectID, environments: list))
        if renamed != nil, pending?.name == renamed {
            finishPending(failed: failure != nil)
        }
        return failure
    }

    /// A field of an inherited environment: all the project's changes, with this environment's
    /// change made of the stored one and the field's value.
    private func applyOverride(_ name: String, _ change: (inout EnvironmentOverride) -> Void) async -> String? {
        let stored = current.project.environmentOverrides
        let overrides = ProjectRules.environmentOverrides(stored, changing: name, change)
        guard overrides != stored else { return nil }
        return await update(ProjectsUpdate.Params(projectID: projectID, environmentOverrides: overrides))
    }

    /// `Browse…`: an open panel for one file, starting in `~/.kube`, or in the home folder when
    /// `~/.kube` does not exist; the chosen file applies at once as its absolute path.
    private func browse(for name: String, stored: String?) {
        Task {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let kube = (home as NSString).appendingPathComponent(".kube")
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: kube, isDirectory: &isDirectory) && isDirectory.boolValue
            guard let path = await ShellPanels.chooseFile(on: hostWindow.window, directory: exists ? kube : home),
                  path != stored else { return }
            browseFailure = nil
            browseFailure = await applyOwn(name) { $0.kubeconfig = path }
        }
    }

    // MARK: kubectl (docs/engine-api.md › Kubeconfig methods)

    /// The connection check of the kubeconfig file, then, once kubectl reaches the cluster, its
    /// namespaces; a list that cannot be read stays empty.
    private func checkConnection(_ kubeconfig: String?) async {
        namespaces = []
        guard let kubeconfig else {
            connection = .none
            return
        }
        connection = .checking
        do {
            _ = try await workspace.call(KubernetesCheck.self, KubernetesCheck.Params(projectID: projectID, kubeconfig: kubeconfig))
        } catch {
            if !Task.isCancelled {
                connection = .failed(errorMessage(error))
            }
            return
        }
        guard !Task.isCancelled else { return }
        connection = .connected
        let found = try? await workspace.call(KubernetesNamespaces.self,
                                              KubernetesNamespaces.Params(projectID: projectID, kubeconfig: kubeconfig))
        if !Task.isCancelled {
            namespaces = found ?? []
        }
    }

    /// The deployments of the environment's namespace, or of the file's current context without
    /// one, once kubectl reaches the cluster; a list that cannot be read stays empty.
    private func readDeployments(kubeconfig: String?, namespace: String?) async {
        deployments = []
        guard connection == .connected, let kubeconfig else { return }
        let found = try? await workspace.call(KubernetesDeployments.self,
                                              KubernetesDeployments.Params(projectID: projectID, kubeconfig: kubeconfig,
                                                                           namespace: namespace))
        if !Task.isCancelled {
            deployments = found ?? []
        }
    }
}

/// The environment the section selects once the project's environments have its name.
private struct PendingSelection: Equatable {
    var name: String
    /// True when its fields start anew: an environment `+` added, not a rename.
    var newIdentity: Bool
    var focusesName: Bool
}

/// The state of the connection dot.
private enum KubeconfigConnection: Equatable {
    case none
    case checking
    case connected
    /// The engine's message, with kubectl's error.
    case failed(String)

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private struct ConnectionKey: Hashable {
    var identity: UUID
    var kubeconfig: String?
}

private struct DeploymentsKey: Hashable {
    var identity: UUID
    var kubeconfig: String?
    var namespace: String?
    var connected: Bool
}

/// A text field of the Environments section, applied on Return or when it loses the focus, or when
/// it is removed while it holds a new value. Its message, the validation message of its text or
/// the engine's failure, goes to its row through `message`. An invalid value, or one equal to the
/// stored one, is not applied. While it is not focused, it shows the stored value again whenever
/// that value changes.
private struct EnvironmentTextField: View {
    let title: String
    var prompt: String?
    var monospaced = true
    let value: String
    var validate: (String) -> String? = { _ in nil }
    var normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    @Binding var message: String?
    /// When it is true as the field appears, the field takes the keyboard focus and sets it false.
    var focusRequest: Binding<Bool>?
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
                publish()
            }
            .onChange(of: failure) { publish() }
            .onAppear {
                text = value
                publish()
                if focusRequest?.wrappedValue == true {
                    focusRequest?.wrappedValue = false
                    Task { @MainActor in
                        focused = true
                    }
                }
            }
            .onChange(of: value) { _, newValue in
                if !focused {
                    text = newValue
                }
            }
            .onDisappear(perform: commit)
    }

    private func publish() {
        message = validate(text) ?? failure
    }

    private func commit() {
        guard validate(text) == nil else { return }
        let normalized = normalize(text)
        text = normalized
        guard normalized != value else { return }
        Task {
            failure = await apply(normalized)
        }
    }
}

/// A combo box of the Environments section in SF Mono: the user picks a listed name, which applies
/// at once, or types any name, which applies on Return or when it loses the focus, or when it is
/// removed while it holds a new value. A value equal to the stored one is not applied; the
/// engine's failure goes to its row through `message`. While it is not being edited, it shows the
/// stored value again whenever that value changes.
private struct EnvironmentComboBox: NSViewRepresentable {
    let title: String
    let value: String
    let items: [String]
    var placeholder = ""
    var isEnabled = true
    @Binding var message: String?
    /// Applies the trimmed value; returns the engine's message, or nil on success.
    let apply: (String) async -> String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        box.usesDataSource = false
        box.completes = true
        box.numberOfVisibleItems = 12
        box.delegate = context.coordinator
        box.setAccessibilityLabel(title)
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        box.stringValue = value
        context.coordinator.shownValue = value
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.items != items {
            coordinator.items = items
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.placeholderAttributedString?.string != placeholder {
            box.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor,
            ])
        }
        box.isEnabled = isEnabled
        // A new stored value shows unless the box is being edited.
        if coordinator.shownValue != value {
            coordinator.shownValue = value
            coordinator.committed = nil
            if box.currentEditor() == nil {
                box.stringValue = value
            }
        }
    }

    static func dismantleNSView(_ box: NSComboBox, coordinator: Coordinator) {
        coordinator.commit(box.stringValue)
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: EnvironmentComboBox?
        var items: [String] = []
        /// The stored value the box last showed.
        var shownValue = ""

        func controlTextDidChange(_ notification: Notification) {
            parent?.message = nil
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            commit(box.stringValue)
        }

        /// An item picked in the list applies when the list closes, so that moving through the list
        /// with the arrow keys applies nothing.
        func comboBoxWillDismiss(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let item = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            commit(item)
        }

        /// The last value applied, so that a pick followed by the end of editing applies once.
        var committed: String?

        /// Applies the trimmed text when it differs from the stored value.
        func commit(_ text: String) {
            guard let parent, parent.isEnabled else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != parent.value, trimmed != committed else { return }
            committed = trimmed
            Task {
                let failure = await parent.apply(trimmed)
                parent.message = failure
                if failure != nil {
                    committed = nil
                }
            }
        }
    }
}
