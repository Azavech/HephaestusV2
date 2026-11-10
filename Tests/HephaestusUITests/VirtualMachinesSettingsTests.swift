import Foundation
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/ui.md › Virtual Machines and docs/virtual-machines.md › Image states, › Setup view: the
/// tab, the texts of the Images table and of the setup view, and the workspace's images.
@Suite("Virtual Machines settings")
@MainActor
struct VirtualMachinesSettingsTests {
    static func image(_ state: VMImageState, progress: Double? = nil, failure: String? = nil) -> VMImage {
        VMImage(id: UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!, version: "27.2.1", build: "26B131", state: state,
                failure: failure, created: Date(timeIntervalSince1970: 1_800_000_000), progress: progress, diskGB: 32)
    }

    @Test("The Virtual Machines tab is the last one, after Editor, with display")
    func settingsTab() {
        let tabs = SettingsTab.allCases
        #expect(tabs.last == .virtualMachines)
        #expect(tabs.dropLast().last == .editor)
        #expect(SettingsTab.virtualMachines.title == "Virtual Machines")
        #expect(SettingsTab.virtualMachines.symbol == "display")
    }

    @Test("The State column shows the texts of the image states")
    func stateTexts() {
        #expect(VMImagePresentation.stateText(Self.image(.downloading, progress: 0.42)) == "Downloading… 42%")
        #expect(VMImagePresentation.stateText(Self.image(.downloading, progress: 0.429)) == "Downloading… 42%")
        #expect(VMImagePresentation.stateText(Self.image(.downloading)) == "Downloading… 0%")
        #expect(VMImagePresentation.stateText(Self.image(.installing, progress: 0.63)) == "Installing… 63%")
        #expect(VMImagePresentation.stateText(Self.image(.installing, progress: 1)) == "Installing… 100%")
        #expect(VMImagePresentation.stateText(Self.image(.needsSetup)) == "Needs setup")
        #expect(VMImagePresentation.stateText(Self.image(.ready)) == "Ready")
        #expect(VMImagePresentation.stateText(Self.image(.failed, failure: "The download failed: HTTP 404."))
            == "Failed: The download failed: HTTP 404.")
        #expect(VMImagePresentation.stateText(Self.image(.failed)) == "Failed")
    }

    @Test("The macOS column shows the version and the build, and the Disk column a file size")
    func versionAndDisk() {
        #expect(VMImagePresentation.versionText(Self.image(.ready)) == "27.2.1 (26B131)")
        #expect(VMImagePresentation.diskText(23_410_000_000) == ByteCountFormatter.string(fromByteCount: 23_410_000_000, countStyle: .file))
        #expect(VMImagePresentation.diskText(23_410_000_000).hasSuffix("GB"))
        #expect(VMImagePresentation.diskText(-1) == VMImagePresentation.diskText(0))
    }

    @Test("The setup view's title, running time, status line and the Delete alert")
    func setupTexts() {
        #expect(VMImagePresentation.setupTitle(version: "27.2.1") == "Set Up macOS 27.2.1")
        #expect(VMImagePresentation.agentStatusText(nil) == "Waiting for the agent…")
        #expect(VMImagePresentation.agentStatusText(GuestAgentStatus(version: "1.0", sip: .disabled)) == "Agent connected · SIP off")
        #expect(VMImagePresentation.agentStatusText(GuestAgentStatus(version: "1.0", sip: .enabled)) == "Agent connected · SIP on")
        #expect(VMImagePresentation.agentStatusText(GuestAgentStatus(version: "1.0", sip: .unknown)) == "Agent connected · SIP on")
        #expect(VMImagePresentation.deleteTitle(version: "27.2.1") == "Delete the image “macOS 27.2.1”?")
        #expect(VMImagePresentation.deleteMessage == "Its virtual machines are deleted too.")
        #expect(GuestTools.installCommand == #"sh "/Volumes/My Shared Files/install.sh""#)
        #expect(VMImagePresentation.setUpFailedTitle == "Set Up failed")
        #expect(VMImagePresentation.restartFailedTitle == "Restart in Recovery failed")
    }

    @Test("vmImages.changed gives the workspace its images, also before the tab loaded them")
    func workspaceImages() {
        let workspace = DeviceWorkspace(deviceID: "D1", connection: OfflineConnection(), isLocal: true)
        #expect(workspace.vmImages == nil)
        #expect(!workspace.hasImageWork)
        var event = WorkspaceEvent(origin: .system, event: .vmImagesChanged([Self.image(.ready)]))
        #expect(event.kind == .state)
        workspace.apply(&event)
        #expect(workspace.vmImages == [Self.image(.ready)])
        #expect(!workspace.hasImageWork)
        var emptied = WorkspaceEvent(origin: .system, event: .vmImagesChanged([]))
        workspace.apply(&emptied)
        #expect(workspace.vmImages == [])
    }

    @Test("An image that downloads or installs is image work, which keeps the app from being idle")
    func imageWork() {
        let workspace = DeviceWorkspace(deviceID: "D1", connection: OfflineConnection(), isLocal: true)
        for (state, works) in [(VMImageState.downloading, true), (.installing, true), (.needsSetup, false), (.ready, false), (.failed, false)] {
            workspace.vmImages = [Self.image(.ready), Self.image(state)]
            #expect(workspace.hasImageWork == works)
        }
    }

    // MARK: Virtual machines (docs/ui.md › Virtual Machines, docs/virtual-machines.md › Lifecycle)

    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static func machine(_ state: VirtualMachineState = .stopped, startedBy: VMStarter = .user, id: UUID = UUID()) -> VirtualMachine {
        VirtualMachine(id: id, name: "Menu checks", imageID: UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!, version: "27.2.1",
                       build: "26B131", cores: 4, memoryGB: 8, startedBy: startedBy, created: started, state: state,
                       startedAt: state == .running ? started : nil)
    }

    @Test("Started by reads You, or the project and the chat's current title for a virtual machine that Claude started")
    func startedBy() {
        let chat = ChatMeta(id: Self.chatID, title: "Check the menus", kind: .project, created: Self.started, projectID: "DEMO")
        let claudes = Self.machine(.running, startedBy: .claude(projectID: "DEMO", chatID: Self.chatID))
        #expect(VirtualMachinePresentation.startedByText(Self.machine(), chats: [Self.chatID.uuidString: chat]) == "You")
        #expect(VirtualMachinePresentation.startedByText(claudes, chats: [Self.chatID.uuidString: chat]) == "DEMO · Check the menus")
        var renamed = chat
        renamed.title = "Menus"
        #expect(VirtualMachinePresentation.startedByText(claudes, chats: [Self.chatID.uuidString: renamed]) == "DEMO · Menus")
        // The chat no longer exists.
        #expect(VirtualMachinePresentation.startedByText(claudes, chats: [:]) == "DEMO")
    }

    @Test("State reads Running with the running time, <m> min under an hour and <h> h <mm> min after, or Stopped")
    func machineStateTexts() {
        let running = Self.machine(.running)
        func text(after seconds: TimeInterval) -> String {
            VirtualMachinePresentation.stateText(running, now: Self.started.addingTimeInterval(seconds))
        }
        #expect(text(after: 0) == "Running · 0 min")
        #expect(text(after: 59) == "Running · 0 min")
        #expect(text(after: 12 * 60) == "Running · 12 min")
        #expect(text(after: 59 * 60 + 59) == "Running · 59 min")
        #expect(text(after: 3600) == "Running · 1 h 00 min")
        #expect(text(after: 3600 + 5 * 60) == "Running · 1 h 05 min")
        #expect(text(after: 26 * 3600 + 40 * 60) == "Running · 26 h 40 min")
        #expect(VirtualMachinePresentation.stateText(Self.machine(), now: Self.started) == "Stopped")
        #expect(VirtualMachinePresentation.stoppedText == "Stopped")
        #expect(VirtualMachinePresentation.systemText(running) == "macOS 27.2.1")
        #expect(VirtualMachinePresentation.deleteTitle(name: "Menu checks") == "Delete “Menu checks”?")
        #expect(VirtualMachinePresentation.deleteMessage == "Its disk is deleted.")
    }

    @Test("New VM… and Start are disabled while 2 virtual machines run, whichever they are; Stop needs a running virtual machine")
    func twoRunningDisablesStarts() {
        let stopped = Self.machine()
        let running = Self.machine(.running)
        // Before the list is known, none runs that the app knows of.
        #expect(VirtualMachinePresentation.canCreate(nil))
        #expect(VirtualMachinePresentation.canStart(stopped, in: nil))
        for count in 0...1 {
            let list = VMList(machines: [stopped, running], runningCount: count)
            #expect(VirtualMachinePresentation.canCreate(list))
            #expect(VirtualMachinePresentation.canStart(stopped, in: list))
        }
        // 2 run: the user's, Claude's, a setup virtual machine or an install, all in `runningCount`.
        for machines in [[stopped, running, Self.machine(.running, startedBy: .claude(projectID: "DEMO", chatID: Self.chatID))],
                         [stopped, running], [stopped]] {
            let list = VMList(machines: machines, runningCount: 2)
            #expect(!VirtualMachinePresentation.canCreate(list))
            #expect(!VirtualMachinePresentation.canStart(stopped, in: list))
        }
        let free = VMList(machines: [stopped, running], runningCount: 1)
        #expect(!VirtualMachinePresentation.canStart(running, in: free))
        #expect(!VirtualMachinePresentation.canStart(nil, in: free))
        #expect(VirtualMachinePresentation.canStop(running))
        #expect(!VirtualMachinePresentation.canStop(stopped))
        #expect(!VirtualMachinePresentation.canStop(nil))
    }

    @Test("Edit… needs a Stopped virtual machine; the Edit VM sheet starts with its disk size and saves once the name is not empty")
    func editVM() {
        #expect(VirtualMachinePresentation.editTitle == "Edit…")
        #expect(VirtualMachinePresentation.canEdit(Self.machine()))
        #expect(!VirtualMachinePresentation.canEdit(Self.machine(.running)))
        #expect(!VirtualMachinePresentation.canEdit(nil))
        var machine = Self.machine()
        machine.diskGB = 100
        #expect(VirtualMachinePresentation.currentDiskGB(machine, images: nil) == 100)
        // Without diskGB, the disk size of its image.
        machine.diskGB = nil
        var image = Self.image(.ready)
        image.diskGB = 40
        #expect(VirtualMachinePresentation.currentDiskGB(machine, images: [image]) == 40)
        #expect(VirtualMachinePresentation.currentDiskGB(machine, images: nil) == VMImageLimits.imageDiskGB)
        #expect(VirtualMachinePresentation.canSave(name: "Menu checks"))
        #expect(!VirtualMachinePresentation.canSave(name: " \n "))
    }

    @Test("The New VM sheet selects the default image, starts with the New VMs values, enables Start with a name and an image, and keeps only refused values")
    func newVMSheet() {
        let first = Self.image(.ready)
        var second = Self.image(.ready)
        second.id = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
        second.diskGB = 100
        #expect(VirtualMachinePresentation.initialImage([first, second], defaultImageID: second.id) == second)
        // Without a default image, the first Ready image.
        #expect(VirtualMachinePresentation.initialImage([first, second], defaultImageID: nil) == first)
        #expect(VirtualMachinePresentation.initialImage([first, second], defaultImageID: UUID()) == first)
        #expect(VirtualMachinePresentation.initialImage([], defaultImageID: second.id) == nil)

        // The values of the New VMs section; the disk is at least the image's.
        let limits = VMImageLimits(processorCount: 10, physicalMemory: 16 * VMImageLimits.bytesPerGB)
        let settings = HostSettings(defaultVMCores: 4, defaultVMMemoryGB: 8, defaultVMDiskGB: 64)
        #expect(VirtualMachinePresentation.initialValues(settings: settings, image: first, limits: limits) == (4, 8, 64))
        #expect(VirtualMachinePresentation.initialValues(settings: settings, image: second, limits: limits) == (4, 8, 100))
        #expect(VirtualMachinePresentation.initialValues(settings: settings, image: nil, limits: limits) == (4, 8, 64))
        #expect(VirtualMachinePresentation.initialValues(settings: HostSettings(), image: first, limits: limits) == (2, 4, 64))
        // A value of a larger Mac's file is brought into this Mac's range.
        let larger = HostSettings(defaultVMCores: 24, defaultVMMemoryGB: 64, defaultVMDiskGB: 64)
        #expect(VirtualMachinePresentation.initialValues(settings: larger, image: first, limits: limits) == (10, 16, 64))

        #expect(VirtualMachinePresentation.canSubmit(name: "Menu checks", imageID: first.id))
        #expect(!VirtualMachinePresentation.canSubmit(name: "  ", imageID: first.id))
        #expect(!VirtualMachinePresentation.canSubmit(name: "Menu checks", imageID: nil))

        // A refused value shows in the sheet; any other failure is a failed start, shown under the table.
        #expect(VirtualMachinePresentation.staysInSheet(EngineError(.invalid, "name: use 1 to 100 characters on one line.")))
        #expect(!VirtualMachinePresentation.staysInSheet(EngineError(.conflict, "2 virtual machines are already running.")))
        #expect(!VirtualMachinePresentation.staysInSheet(EngineError(.internal, "The virtual machine could not be created: No space left on device.")))
        #expect(!VirtualMachinePresentation.staysInSheet(EngineError(.unavailable, "The virtual machine failed to start.")))
        #expect(!VirtualMachinePresentation.staysInSheet(CocoaError(.fileWriteOutOfSpace)))
    }

    @Test("vms.changed gives the workspace the virtual machines, also before the tab loaded them")
    func workspaceMachines() {
        let workspace = DeviceWorkspace(deviceID: "D1", connection: OfflineConnection(), isLocal: true)
        #expect(workspace.virtualMachines == nil)
        #expect(!workspace.hasRunningVirtualMachines)
        let running = Self.machine(.running)
        var event = WorkspaceEvent(origin: .system, event: .vmsChanged(VMList(machines: [running], runningCount: 1)))
        #expect(event.kind == .state)
        workspace.apply(&event)
        #expect(workspace.virtualMachines == VMList(machines: [running], runningCount: 1))
        #expect(workspace.virtualMachine(running.id) == running)
        #expect(workspace.virtualMachine(UUID()) == nil)
        #expect(workspace.hasRunningVirtualMachines)
        // A setup virtual machine alone: no virtual machine of the list runs.
        var setup = WorkspaceEvent(origin: .system, event: .vmsChanged(VMList(machines: [Self.machine()], runningCount: 1)))
        workspace.apply(&setup)
        #expect(!workspace.hasRunningVirtualMachines)
    }

    /// The pixels of a view drawn on a background of the given prominence.
    static func render(_ view: some View, _ prominence: BackgroundProminence) throws -> Data {
        let renderer = ImageRenderer(content: view.environment(\.backgroundProminence, prominence).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data) as Data
    }

    /// The symbol of a radio button that is on, in a style, laid out as `RadioButton` lays it out.
    static func mark(_ style: some ShapeStyle) -> some View {
        Button(action: {}) {
            Image(systemName: "largecircle.fill.circle")
                .foregroundStyle(style)
                .padding(.top, 1)
        }
        .buttonStyle(.plain)
    }

    @Test("The radio that is on is drawn in the primary colour on the fill of a selected row, in the accent colour elsewhere")
    func radioOnSelectedRow() throws {
        let onRow = try Self.render(RadioButton(selected: true) {}, .increased)
        let elsewhere = try Self.render(RadioButton(selected: true) {}, .standard)
        #expect(onRow == (try Self.render(Self.mark(.primary), .increased)))
        #expect(elsewhere == (try Self.render(Self.mark(Color.accentColor), .standard)))
        // On the accent-coloured fill the accent colour would not show.
        #expect(onRow != (try Self.render(Self.mark(Color.accentColor), .increased)))
        // A radio that is off keeps the secondary colour.
        #expect(try Self.render(RadioButton(selected: false) {}, .standard)
            == (try Self.render(Button(action: {}) { Image(systemName: "circle").foregroundStyle(Color.secondary).padding(.top, 1) }
                .buttonStyle(.plain), .standard)))
    }

    @Test("The Claude section: its texts, and the idle minutes read from the field")
    func claudeSection() throws {
        #expect(ClaudeVMPresentation.idleLabel == "Stop Claude's idle VMs after")
        #expect(ClaudeVMPresentation.idleUnit == "minutes")
        #expect(ClaudeVMPresentation.tokenLabel == "Claude token")
        #expect(ClaudeVMPresentation.tokenCaption == "Create it with claude setup-token. Each VM gets it when it starts.")
        #expect(try ClaudeVMPresentation.idleMinutes(" 12 ").get() == 12)
        guard case .failure(let error) = ClaudeVMPresentation.idleMinutes("ten") else {
            Issue.record("a text that is not a number was read")
            return
        }
        #expect(error.message == "claudeVMIdleMinutes: use a number from 1 to 1440.")
    }

    @Test("The New VMs section: its labels, keys and values, and the message of a text that is not a number")
    func newVMsSection() throws {
        typealias Field = NewVMsPresentation.Field
        #expect(Field.allCases.map(\.label) == ["Default cores", "Default memory (GB)", "Default disk (GB)"])
        #expect(Field.allCases.map(\.key) == ["defaultVMCores", "defaultVMMemoryGB", "defaultVMDiskGB"])
        #expect(Field.allCases.map { $0.stored(HostSettings()) } == [2, 4, 64])
        #expect(Field.disk.update(100) == SettingsUpdate.Params(defaultVMDiskGB: 100))
        let limits = VMImageLimits(processorCount: 14, physicalMemory: 36 * VMImageLimits.bytesPerGB)
        #expect(try NewVMsPresentation.value(" 8 ", .cores, limits: limits).get() == 8)
        for (field, message) in [(Field.cores, "defaultVMCores: use a number from 2 to 14."),
                                 (.memory, "defaultVMMemoryGB: use a number from 4 to 36."),
                                 (.disk, "defaultVMDiskGB: use a number from 32 to 2048.")] {
            guard case .failure(let error) = NewVMsPresentation.value("many", field, limits: limits) else {
                Issue.record("a text that is not a number was read")
                continue
            }
            #expect(error.message == message)
        }
    }
}
