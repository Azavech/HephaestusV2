// OWNER: ui-shell — the Virtual Machines tab of the Settings window (docs/ui.md › Virtual Machines;
// docs/virtual-machines.md).
import AppKit
import HephaestusCore
import SwiftUI

/// The texts of the images of virtual machines (docs/ui.md › Virtual Machines,
/// docs/virtual-machines.md › Image states, › Setup view).
enum VMImagePresentation {
    /// The text of the State column: `Downloading… 42%`, `Installing… 63%`, `Needs setup`, `Ready`
    /// or `Failed: <message>`.
    static func stateText(_ image: VMImage) -> String {
        switch image.state {
        case .downloading: return "Downloading… \(image.percentage)%"
        case .installing: return "Installing… \(image.percentage)%"
        case .needsSetup: return "Needs setup"
        case .ready: return "Ready"
        case .failed:
            guard let failure = image.failure, !failure.isEmpty else { return "Failed" }
            return "Failed: \(failure)"
        }
    }

    /// The text of the macOS column and of the Version pop-up: `27.2.1 (26B131)`.
    static func versionText(_ image: VMImage) -> String {
        MacOSVersion.title(version: image.version, build: image.build)
    }

    /// The text of the Disk column: the space the image uses on disk, as a file size.
    static func diskText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }

    /// The title of the setup view and the name of its setup virtual machine: `Set Up macOS <version>`.
    static func setupTitle(version: String) -> String {
        "Set Up macOS \(version)"
    }

    /// The running time of the header of the setup view at `now`: `Running · 12 min`.
    static func setupRunningText(since startedAt: Date, now: Date) -> String {
        "Running · \(VMRunningTime.text(since: startedAt, now: max(now, startedAt)))"
    }

    /// The status line of the setup view.
    static func agentStatusText(_ agent: GuestAgentStatus?) -> String {
        guard let agent else { return "Waiting for the agent…" }
        return agent.sip == .disabled ? "Agent connected · SIP off" : "Agent connected · SIP on"
    }

    /// The title of the Delete… alert.
    static func deleteTitle(version: String) -> String {
        "Delete the image “macOS \(version)”?"
    }

    static let deleteMessage = "Its virtual machines are deleted too."

    /// The title of the alert of a setup that failed: `Set Up…` that cannot boot the image, and a
    /// setup virtual machine that fails while it runs.
    static let setUpFailedTitle = "Set Up failed"
    /// `Set Up…` of the Images table and the items of its menu (docs/virtual-machines.md › Setup).
    static let setUpTitle = "Set Up…"
    static let manualSetupTitle = "Manual Setup"
    static let autoSetupTitle = "Auto Setup"
    /// The title of the alert of a `Restart in Recovery` that cannot start the virtual machine.
    static let restartFailedTitle = "Restart in Recovery failed"

    /// The title of the alert of a setup that ended with a failure.
    @MainActor
    static func failureTitle(of session: VMSetupSession) -> String {
        session.restartFailed ? restartFailedTitle : setUpFailedTitle
    }

    /// The failure alert of docs/ui.md › Principles, on a window.
    @MainActor
    static func showFailure(_ title: String, _ message: String, on window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await AlertPresenter.present(alert, on: window)
    }
}

/// The texts and the button rules of the virtual machines (docs/ui.md › Virtual Machines,
/// docs/virtual-machines.md › Lifecycle, › Virtual machine states, › Detail).
enum VirtualMachinePresentation {
    /// The text of the Started by column: `You`, or `<project id> · <chat name>` for a virtual
    /// machine that Claude started, with the chat's current title; `<project id>` alone when the
    /// chat no longer exists.
    static func startedByText(_ machine: VirtualMachine, chats: [String: ChatMeta]) -> String {
        switch machine.startedBy {
        case .user:
            return "You"
        case .claude(let projectID, let chatID):
            guard let chat = chats[chatID.uuidString] else { return projectID }
            return "\(projectID) · \(chat.title)"
        }
    }

    /// The text of the State column at `now`: `Running · 12 min` or `Stopped`.
    static func stateText(_ machine: VirtualMachine, now: Date) -> String {
        guard machine.state == .running else { return "Stopped" }
        return "Running · \(VMRunningTime.text(since: machine.startedAt ?? now, now: now))"
    }

    /// The text that takes the place of a stopped virtual machine's screen.
    static let stoppedText = "Stopped"

    /// `macOS <version>`, in the header of the detail.
    static func systemText(_ machine: VirtualMachine) -> String {
        "macOS \(machine.version)"
    }

    /// The title of the Delete… alert of a virtual machine.
    static func deleteTitle(name: String) -> String {
        "Delete “\(name)”?"
    }

    static let deleteMessage = "Its disk is deleted."

    /// `New VM…` is disabled while 2 virtual machines run; before the list is known, none runs
    /// that the app knows of.
    static func canCreate(_ list: VMList?) -> Bool {
        list?.canStartOne ?? true
    }

    /// `Start` is enabled while the virtual machine is Stopped and fewer than 2 virtual machines
    /// run.
    static func canStart(_ machine: VirtualMachine?, in list: VMList?) -> Bool {
        guard let machine, machine.state == .stopped else { return false }
        return canCreate(list)
    }

    /// `Stop` is enabled while the virtual machine is Running.
    static func canStop(_ machine: VirtualMachine?) -> Bool {
        machine?.state == .running
    }

    /// `Edit…` is enabled while the virtual machine is Stopped (docs/virtual-machines.md › Editing).
    static func canEdit(_ machine: VirtualMachine?) -> Bool {
        machine?.state == .stopped
    }

    static let editTitle = "Edit…"

    /// The disk size the Edit VM sheet starts with, the smallest it accepts: the virtual machine's
    /// `diskGB`; without one, the disk size of its image.
    static func currentDiskGB(_ machine: VirtualMachine, images: [VMImage]?) -> Int {
        machine.diskGB ?? images?.first { $0.id == machine.imageID }?.diskGB ?? VMImageLimits.imageDiskGB
    }

    /// `Save` of the Edit VM sheet is enabled once the name is not empty.
    static func canSave(name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The image the New VM sheet selects when it opens: the default image, else the first Ready
    /// image.
    static func initialImage(_ readyImages: [VMImage], defaultImageID: UUID?) -> VMImage? {
        readyImages.first { $0.id == defaultImageID } ?? readyImages.first
    }

    /// The values of the New VM sheet when it opens: the default values of Settings, brought into
    /// this Mac's ranges, and a disk of at least the image's (docs/ui.md › Virtual Machines).
    static func initialValues(settings: HostSettings, image: VMImage?,
                              limits: VMImageLimits = .host) -> (cores: Int, memoryGB: Int, diskGB: Int) {
        let defaults = settings.vmDefaults(limits)
        return (defaults.cores, defaults.memoryGB, max(defaults.diskGB, image?.diskGB ?? 0))
    }

    /// `Start` of the New VM sheet is enabled once the name is not empty and an image is selected.
    static func canSubmit(name: String, imageID: UUID?) -> Bool {
        imageID != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a failure of `vms.create` shows in the New VM sheet, which stays open: a value the
    /// engine refuses. Any other failure is a failed start, shown under the table.
    static func staysInSheet(_ error: Error) -> Bool {
        (error as? EngineError)?.code == .invalid
    }
}

/// The fields of the New VMs section, the default values of new virtual machines (docs/ui.md ›
/// Virtual Machines, docs/virtual-machines.md › Default values).
enum NewVMsPresentation {
    enum Field: CaseIterable {
        case cores, memory, disk

        var label: String {
            switch self {
            case .cores: return "Default cores"
            case .memory: return "Default memory (GB)"
            case .disk: return "Default disk (GB)"
            }
        }

        /// The key of `settings.yml`.
        var key: String {
            switch self {
            case .cores: return "defaultVMCores"
            case .memory: return "defaultVMMemoryGB"
            case .disk: return "defaultVMDiskGB"
            }
        }

        func range(_ limits: VMImageLimits) -> ClosedRange<Int> {
            switch self {
            case .cores: return limits.cores
            case .memory: return limits.memoryGB
            case .disk: return limits.diskGB
            }
        }

        func stored(_ settings: HostSettings) -> Int {
            switch self {
            case .cores: return settings.defaultVMCores
            case .memory: return settings.defaultVMMemoryGB
            case .disk: return settings.defaultVMDiskGB
            }
        }

        func update(_ value: Int) -> SettingsUpdate.Params {
            switch self {
            case .cores: return SettingsUpdate.Params(defaultVMCores: value)
            case .memory: return SettingsUpdate.Params(defaultVMMemoryGB: value)
            case .disk: return SettingsUpdate.Params(defaultVMDiskGB: value)
            }
        }
    }

    /// The number of a field; a text that is not a whole number gets the engine's message for a
    /// value outside the range.
    static func value(_ text: String, _ field: Field, limits: VMImageLimits = .host) -> Result<Int, ValidationError> {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            let range = field.range(limits)
            return .failure(.invalid(field.key, "use a number from \(range.lowerBound) to \(range.upperBound)"))
        }
        return .success(value)
    }
}

/// The New VMs section: three number fields, each a `settings.yml` key applied with
/// `settings.update` on Return or when it loses the focus.
struct NewVMsSection: View {
    @Environment(AppModel.self) private var app
    @State private var messages: [NewVMsPresentation.Field: String] = [:]

    private var settings: HostSettings { app.localWorkspace.settings ?? HostSettings() }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(NewVMsPresentation.Field.allCases, id: \.self) { field in
                GridRow {
                    Text(field.label)
                        .gridColumnAlignment(.trailing)
                    CommitTextField(title: field.label, value: String(field.stored(settings))) { text in
                        commit(field, text)
                    }
                    .frame(width: 60)
                }
                if let message = messages[field] {
                    GridRow {
                        Color.clear
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                        FieldMessage(text: message)
                    }
                }
            }
        }
    }

    private func commit(_ field: NewVMsPresentation.Field, _ text: String) {
        switch NewVMsPresentation.value(text, field) {
        case .failure(let error):
            messages[field] = error.message
        case .success(let value):
            guard value != field.stored(settings) else {
                messages[field] = nil
                return
            }
            Task {
                messages[field] = await updateLocalSettings(app, field.update(value))
            }
        }
    }
}

/// The texts and the values of the Claude section (docs/ui.md › Virtual Machines).
enum ClaudeVMPresentation {
    static let idleLabel = "Stop Claude's idle VMs after"
    static let idleUnit = "minutes"
    static let tokenLabel = "Claude token"
    static let tokenCaption = "Create it with claude setup-token. Each VM gets it when it starts."

    /// The minutes of the idle field; a text that is not a whole number gets the engine's message
    /// for a value outside the range.
    static func idleMinutes(_ text: String) -> Result<Int, ValidationError> {
        guard let minutes = Int(text.trimmingCharacters(in: .whitespaces)) else {
            return .failure(.invalid("claudeVMIdleMinutes", "use a number from 1 to 1440"))
        }
        return .success(minutes)
    }
}

/// The Claude section: the idle minutes of Claude's virtual machines, a `settings.yml` key, and
/// the Claude token, through the Claude VM token service of This Mac (docs/ui.md › Virtual
/// Machines, docs/virtual-machines.md › Idle stop, › Claude token).
struct ClaudeVMSection: View {
    @Environment(AppModel.self) private var app
    @State private var idleMessage: String?
    @State private var token = ""
    @State private var showsToken = false
    @State private var tokenMessage: String?
    @FocusState private var tokenFocused: Bool

    private var storedMinutes: Int { app.localWorkspace.settings?.claudeVMIdleMinutes ?? HostSettings.defaultClaudeVMIdleMinutes }

    var body: some View {
        HStack(spacing: 6) {
            Text(ClaudeVMPresentation.idleLabel)
            CommitTextField(title: ClaudeVMPresentation.idleUnit, value: String(storedMinutes)) { text in
                commitMinutes(text)
            }
            .frame(width: 60)
            Text(ClaudeVMPresentation.idleUnit)
        }
        FieldMessage(text: idleMessage)
        HStack(spacing: 8) {
            Text(ClaudeVMPresentation.tokenLabel)
            Group {
                if showsToken {
                    TextField(ClaudeVMPresentation.tokenLabel, text: $token)
                } else {
                    SecureField(ClaudeVMPresentation.tokenLabel, text: $token)
                }
            }
            .labelsHidden()
            .focused($tokenFocused)
            .onSubmit(commitToken)
            Button {
                showsToken.toggle()
            } label: {
                Image(systemName: showsToken ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
        .onAppear {
            token = app.engine.claudeVMToken ?? ""
        }
        .onChange(of: tokenFocused) { _, focused in
            if !focused {
                commitToken()
            }
        }
        FieldMessage(text: tokenMessage)
        Text(ClaudeVMPresentation.tokenCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Return or the loss of the focus applies the minutes with `settings.update`.
    private func commitMinutes(_ text: String) {
        switch ClaudeVMPresentation.idleMinutes(text) {
        case .failure(let error):
            idleMessage = error.message
        case .success(let minutes):
            guard minutes != storedMinutes else {
                idleMessage = nil
                return
            }
            Task {
                idleMessage = await updateLocalSettings(app, SettingsUpdate.Params(claudeVMIdleMinutes: minutes))
            }
        }
    }

    /// Return or the loss of the focus stores the token, trimmed; an empty field removes it.
    private func commitToken() {
        guard token != (app.engine.claudeVMToken ?? "") else {
            tokenMessage = nil
            return
        }
        do {
            try app.engine.setClaudeVMToken(token)
            token = app.engine.claudeVMToken ?? ""
            tokenMessage = nil
        } catch {
            tokenMessage = errorMessage(error)
        }
    }
}

/// The State cell of a virtual machine: its text changes when the minute of its running time does.
struct VirtualMachineStateText: View {
    let machine: VirtualMachine

    var body: some View {
        if machine.state == .running, let startedAt = machine.startedAt {
            TimelineView(.periodic(from: startedAt, by: 60)) { context in
                Text(VirtualMachinePresentation.stateText(machine, now: max(context.date, startedAt)))
            }
        } else {
            Text(VirtualMachinePresentation.stateText(machine, now: Date()))
        }
    }
}

/// The Virtual Machines tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the
/// image setup service).
struct VirtualMachinesSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var showsAddImage = false
    @State private var machineSelection: UUID?
    @State private var showsNewVM = false
    /// The virtual machine whose Edit VM sheet shows.
    @State private var editedMachineID: UUID?
    /// The message of the last failed start, the red line under the Virtual Machines table.
    @State private var startFailure: String?
    @State private var hostWindow = HostWindow()

    private var images: [VMImage] { app.localWorkspace.vmImages ?? [] }
    private var defaultImageID: UUID? { app.localWorkspace.settings?.defaultVMImage }
    private var selected: VMImage? { images.first { $0.id == selection } }
    private var machineList: VMList? { app.localWorkspace.virtualMachines }
    private var machines: [VirtualMachine] { machineList?.machines ?? [] }
    private var selectedMachine: VirtualMachine? { machines.first { $0.id == machineSelection } }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "Images") {
                Table(images, selection: $selection) {
                    TableColumn("Default") { image in
                        // The radio of the questions cards; the mark moves when `settings.updated`
                        // arrives.
                        RadioButton(selected: defaultImageID == image.id) {
                            if defaultImageID != image.id {
                                setDefault(image)
                            }
                        }
                        .disabled(image.state != .ready)
                        .accessibilityLabel("Default")
                    }
                    .width(52)
                    TableColumn("macOS") { image in
                        Text(VMImagePresentation.versionText(image))
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("State") { image in
                        let text = VMImagePresentation.stateText(image)
                        Text(text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(text)
                    }
                    TableColumn("Disk") { image in
                        Text(VMImagePresentation.diskText(image.diskBytes))
                            .monospacedDigit()
                    }
                    .width(80)
                }
                .frame(height: 150)
                HStack(spacing: 8) {
                    Button("Add Image…") {
                        showsAddImage = true
                    }
                    // A click on the button starts the manual setup; its arrow opens the menu of the
                    // two setups (docs/virtual-machines.md › Setup).
                    Menu(VMImagePresentation.setUpTitle) {
                        Button(VMImagePresentation.manualSetupTitle, action: setUp)
                        Button(VMImagePresentation.autoSetupTitle, action: autoSetUp)
                    } primaryAction: {
                        setUp()
                    }
                    .fixedSize()
                    .disabled(selected?.state != .needsSetup)
                    Button("Delete…", action: delete)
                        .disabled(selected == nil)
                }
            }
            SettingsRow(label: GuestAccountPresentation.sectionLabel) {
                GuestAccountSection(image: selected)
            }
            SettingsRow(label: "Virtual Machines") {
                // Widths that fit the pane: a table wider than its place loses the inset look of
                // its rows and cuts its last column.
                Table(machines, selection: $machineSelection) {
                    TableColumn("Name") { machine in
                        Text(machine.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(machine.name)
                    }
                    .width(min: 60, ideal: 90)
                    TableColumn("macOS") { machine in
                        Text(machine.version)
                    }
                    .width(48)
                    TableColumn("Started by") { machine in
                        let text = VirtualMachinePresentation.startedByText(machine, chats: app.localWorkspace.chats)
                        Text(text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(text)
                    }
                    .width(min: 60, ideal: 86)
                    TableColumn("State") { machine in
                        VirtualMachineStateText(machine: machine)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .monospacedDigit()
                    }
                    .width(134)
                }
                .frame(height: 130)
                FieldMessage(text: startFailure)
                HStack(spacing: 8) {
                    Button("New VM…") {
                        startFailure = nil
                        showsNewVM = true
                    }
                    .disabled(!VirtualMachinePresentation.canCreate(machineList))
                    Button("Start", action: startMachine)
                        .disabled(!VirtualMachinePresentation.canStart(selectedMachine, in: machineList))
                    Button("Stop", action: stopMachine)
                        .disabled(!VirtualMachinePresentation.canStop(selectedMachine))
                    Button(VirtualMachinePresentation.editTitle) {
                        editedMachineID = selectedMachine?.id
                    }
                    .disabled(!VirtualMachinePresentation.canEdit(selectedMachine))
                    Button("Show", action: showMachine)
                        .disabled(selectedMachine == nil)
                    Button("Delete…", action: deleteMachine)
                        .disabled(selectedMachine == nil)
                }
            }
            SettingsRow(label: "New VMs") {
                NewVMsSection()
            }
            SettingsRow(label: "Claude") {
                ClaudeVMSection()
            }
        }
        .readsHostWindow(hostWindow)
        .task {
            await app.localWorkspace.loadVMImages()
            await app.localWorkspace.loadVirtualMachines()
        }
        .onChange(of: images.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
            }
        }
        .onChange(of: machines.map(\.id)) { _, ids in
            if let machineSelection, !ids.contains(machineSelection) {
                self.machineSelection = nil
            }
        }
        .sheet(isPresented: Binding(get: { showsAddImage && !app.sheetsEnded }, set: { showsAddImage = $0 })) {
            AddImageSheet()
                .environment(app)
        }
        .sheet(isPresented: Binding(get: { showsNewVM && !app.sheetsEnded }, set: { showsNewVM = $0 })) {
            NewVMSheet { message in
                startFailure = message
            }
            .environment(app)
        }
        .sheet(isPresented: Binding(get: { editedMachineID != nil && !app.sheetsEnded }, set: { if !$0 { editedMachineID = nil } })) {
            if let editedMachineID {
                EditVMSheet(vmID: editedMachineID)
                    .environment(app)
            }
        }
    }

    // MARK: Virtual machines

    /// Start boots the selected virtual machine again; a failed start shows as the red line under
    /// the table.
    private func startMachine() {
        guard let machine = selectedMachine else { return }
        startFailure = nil
        Task {
            do {
                _ = try await app.localWorkspace.call(VMsStart.self, VMParams(vmID: machine.id))
            } catch {
                startFailure = errorMessage(error)
            }
        }
    }

    /// Stop shuts the selected virtual machine down.
    private func stopMachine() {
        guard let machine = selectedMachine else { return }
        let window = hostWindow.window
        Task {
            do {
                _ = try await app.localWorkspace.call(VMsStop.self, VMParams(vmID: machine.id))
            } catch {
                await VMImagePresentation.showFailure("Stop failed", errorMessage(error), on: window)
            }
        }
    }

    /// Show opens the selected virtual machine's detail in the frontmost main window that shows
    /// This Mac.
    private func showMachine() {
        guard let machine = selectedMachine else { return }
        app.showVirtualMachine(machine.id)
    }

    /// Delete… asks for confirmation, then deletes the selected virtual machine with its disk.
    private func deleteMachine() {
        guard let machine = selectedMachine else { return }
        let window = hostWindow.window
        Task {
            guard await ShellPanels.confirmDestructive(title: VirtualMachinePresentation.deleteTitle(name: machine.name),
                                                       message: VirtualMachinePresentation.deleteMessage,
                                                       action: "Delete", on: window) else { return }
            do {
                _ = try await app.localWorkspace.call(VMsDelete.self, VMParams(vmID: machine.id))
            } catch {
                await VMImagePresentation.showFailure("Delete failed", errorMessage(error), on: window)
            }
        }
    }

    // MARK: Images

    /// Turning a radio on calls `settings.update` with `defaultVMImage`; the mark moves when
    /// `settings.updated` arrives.
    private func setDefault(_ image: VMImage) {
        let window = hostWindow.window
        Task {
            if let message = await updateLocalSettings(app, SettingsUpdate.Params(defaultVMImage: .set(image.id))) {
                await VMImagePresentation.showFailure("Default failed", message, on: window)
            }
        }
    }

    /// Set Up… boots the selected image, or takes its setup that runs, and shows its setup view in
    /// a main window.
    private func setUp() {
        guard let image = selected else { return }
        let window = hostWindow.window
        Task {
            do {
                try await app.openImageSetup(image.id)
            } catch {
                await VMImagePresentation.showFailure(VMImagePresentation.setUpFailedTitle, errorMessage(error), on: window)
            }
        }
    }

    /// Auto Setup shows the setup as Set Up… does, then starts the Auto Setup chat beside it.
    private func autoSetUp() {
        guard let image = selected else { return }
        let window = hostWindow.window
        Task {
            do {
                try await app.openAutoSetup(image.id)
            } catch {
                await VMImagePresentation.showFailure(VMImagePresentation.setUpFailedTitle, errorMessage(error), on: window)
            }
        }
    }

    /// Delete… asks for confirmation, then deletes the selected image.
    private func delete() {
        guard let image = selected else { return }
        let window = hostWindow.window
        Task {
            guard await ShellPanels.confirmDestructive(title: VMImagePresentation.deleteTitle(version: image.version),
                                                       message: VMImagePresentation.deleteMessage,
                                                       action: "Delete", on: window) else { return }
            do {
                _ = try await app.localWorkspace.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: image.id))
            } catch {
                await VMImagePresentation.showFailure("Delete failed", errorMessage(error), on: window)
            }
        }
    }
}
