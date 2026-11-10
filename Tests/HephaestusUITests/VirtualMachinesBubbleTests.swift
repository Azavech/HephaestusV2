import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/virtual-machines.md › Bubble, › Popover, › Buttons: the number of the Virtual Machines
/// bubble, the rows of its popover with their texts and order, Stopped rows included, the running
/// time and the buttons. No test starts a virtual machine.
@MainActor
@Suite("Virtual Machines bubble")
struct VirtualMachinesBubbleTests {
    static let started = Date(timeIntervalSince1970: 1_800_000_000)
    static let chatID = UUID(uuidString: "3F1E2D4C-5B6A-4798-8A7B-6C5D4E3F2A1B")!
    static let imageID = UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!

    static func machine(_ name: String, _ state: VirtualMachineState = .running, startedBy: VMStarter = .user,
                        after seconds: TimeInterval = 0, createdAfter created: TimeInterval = -3600) -> VirtualMachine {
        VirtualMachine(id: UUID(), name: name, imageID: imageID, version: "27.2.1", build: "26B131", cores: 4, memoryGB: 8,
                       startedBy: startedBy, created: started.addingTimeInterval(created), state: state,
                       startedAt: state == .running ? started.addingTimeInterval(seconds) : nil)
    }

    static func setup(after seconds: TimeInterval = 0, imageID: UUID = imageID) -> VMPopoverSetup {
        VMPopoverSetup(imageID: imageID, version: "26.6.2", startedAt: started.addingTimeInterval(seconds))
    }

    @Test("The bubble shows the number beside the symbol, hidden at 0, with the tooltip Virtual Machines")
    func number() {
        #expect(VMPopoverPresentation.countText(0) == nil)
        #expect(VMPopoverPresentation.countText(1) == "1")
        #expect(VMPopoverPresentation.countText(2) == "2")
        #expect(VMPopoverPresentation.symbol == "display")
        #expect(VMPopoverPresentation.tooltip == "Virtual Machines")
        #expect(VMPopoverPresentation.emptyText == "No virtual machines")
    }

    @Test("The row of buttons reads New VM…, Add Image… and Virtual Machines Settings…; New VM… is disabled while 2 run")
    func buttons() {
        #expect(VMPopoverPresentation.newVMTitle == "New VM…")
        #expect(VMPopoverPresentation.addImageTitle == "Add Image…")
        #expect(VMPopoverPresentation.settingsTitle == "Virtual Machines Settings…")
        #expect(VirtualMachinePresentation.canCreate(nil))
        #expect(VirtualMachinePresentation.canCreate(VMList(machines: [], runningCount: 1)))
        #expect(!VirtualMachinePresentation.canCreate(VMList(machines: [], runningCount: 2)))
    }

    @Test("The number counts the Running virtual machines of the user and of Claude and the setup virtual machines, not an install")
    func counted() {
        let claude = Self.machine("Settings check", startedBy: .claude(projectID: "DEMO", chatID: Self.chatID))
        let list = VMList(machines: [Self.machine("Menu checks"), Self.machine("Old", .stopped), claude], runningCount: 2)
        #expect(VMPopoverPresentation.rows(nil, chats: [:], setups: []).isEmpty)
        #expect(VMPopoverPresentation.rows(VMList(machines: [], runningCount: 0), chats: [:], setups: []).isEmpty)
        // Every virtual machine has a row; the Stopped ones are not counted.
        let stoppedOnly = VMList(machines: [Self.machine("Old", .stopped)], runningCount: 0)
        #expect(VMPopoverPresentation.rows(stoppedOnly, chats: [:], setups: []).count == 1)
        #expect(VMPopoverPresentation.count(stoppedOnly, setups: []) == 0)
        #expect(VMPopoverPresentation.rows(list, chats: [:], setups: []).count == 3)
        #expect(VMPopoverPresentation.rows(list, chats: [:], setups: [Self.setup()]).count == 4)
        #expect(VMPopoverPresentation.count(list, setups: []) == 2)
        #expect(VMPopoverPresentation.count(list, setups: [Self.setup(), Self.setup(imageID: UUID())]) == 4)
        #expect(VMPopoverPresentation.count(nil, setups: []) == 0)
        // An install takes a place among the 2 running virtual machines but has no screen.
        let installing = VMList(machines: [Self.machine("Menu checks")], runningCount: 2)
        #expect(VMPopoverPresentation.rows(installing, chats: [:], setups: []).count == 1)
        #expect(VMPopoverPresentation.count(installing, setups: []) == 1)
    }

    @Test("A row shows the name, Started by you or <project id> · <chat name>, and a setup virtual machine Set Up macOS <version>")
    func rowTexts() throws {
        let chat = ChatMeta(id: Self.chatID, title: "Check the menus", kind: .project, created: Self.started, projectID: "DEMO")
        let claude = Self.machine("Settings check", startedBy: .claude(projectID: "DEMO", chatID: Self.chatID), after: 60)
        let user = Self.machine("Menu checks", after: 120)
        let list = VMList(machines: [user, claude], runningCount: 2)

        let rows = VMPopoverPresentation.rows(list, chats: [Self.chatID.uuidString: chat], setups: [Self.setup(after: 180)])
        #expect(rows.map(\.name) == ["Settings check", "Menu checks", "Set Up macOS 26.6.2"])
        #expect(rows.map(\.startedBy) == ["DEMO · Check the menus", "Started by you", "Started by you"])
        #expect(rows.map(\.source) == [.machine(claude.id), .machine(user.id), .setup(imageID: Self.imageID)])

        // The chat's current title; the project id alone once the chat no longer exists.
        var renamed = chat
        renamed.title = "Menus"
        #expect(VMPopoverPresentation.rows(list, chats: [Self.chatID.uuidString: renamed], setups: []).first?.startedBy == "DEMO · Menus")
        #expect(VMPopoverPresentation.rows(list, chats: [:], setups: []).first?.startedBy == "DEMO")

        // A setup virtual machine has its row whether a window shows its setup view or not.
        let setup = try #require(VMPopoverPresentation.rows(nil, chats: [:], setups: [Self.setup()]).first)
        #expect(setup.source == .setup(imageID: Self.imageID))
        #expect(setup.name == "Set Up macOS 26.6.2" && setup.startedBy == "Started by you")
    }

    @Test("The Running rows come first, the one that started first at the top, then the Stopped ones, the oldest created first")
    func order() {
        let late = Self.machine("Late", after: 600)
        let early = Self.machine("Early", after: 0)
        // Stopped virtual machines created before and after the Running ones still come last.
        let newer = Self.machine("Newer", .stopped, createdAfter: 1200)
        let older = Self.machine("Older", .stopped, createdAfter: -7200)
        let list = VMList(machines: [newer, late, older, early], runningCount: 2)
        let rows = VMPopoverPresentation.rows(list, chats: [:], setups: [Self.setup(after: 300)])
        #expect(rows.map(\.name) == ["Early", "Set Up macOS 26.6.2", "Late", "Older", "Newer"])
        #expect(rows.map(\.isStopped) == [false, false, false, true, true])
        #expect(VMPopoverPresentation.rows(list, chats: [:], setups: [Self.setup(after: -1)]).first?.name == "Set Up macOS 26.6.2")
    }

    @Test("A Stopped row shows its name, Started by you and Stopped; Start is disabled while 2 virtual machines run")
    func stoppedRow() throws {
        let machine = Self.machine("Menu checks", .stopped)
        let row = try #require(VMPopoverPresentation.rows(VMList(machines: [machine], runningCount: 0), chats: [:], setups: []).first)
        #expect(row.source == .machine(machine.id))
        #expect(row.name == "Menu checks")
        #expect(row.startedBy == "Started by you")
        #expect(row.isStopped && row.startedAt == nil)
        #expect(VMPopoverPresentation.runningTime(row, now: Self.started) == "Stopped")
        #expect(VMPopoverPresentation.canStart(VMList(machines: [machine], runningCount: 1)))
        #expect(!VMPopoverPresentation.canStart(VMList(machines: [machine], runningCount: 2)))
    }

    @Test("The running time reads <m> min under an hour and <h> h <mm> min after")
    func runningTime() throws {
        let row = try #require(VMPopoverPresentation.rows(VMList(machines: [Self.machine("Menu checks")], runningCount: 1),
                                                          chats: [:], setups: []).first)
        func text(after seconds: TimeInterval) -> String {
            VMPopoverPresentation.runningTime(row, now: Self.started.addingTimeInterval(seconds))
        }
        #expect(text(after: 0) == "0 min")
        #expect(text(after: 59) == "0 min")
        #expect(text(after: 12 * 60) == "12 min")
        #expect(text(after: 59 * 60 + 59) == "59 min")
        #expect(text(after: 3600) == "1 h 00 min")
        #expect(text(after: 3600 + 5 * 60) == "1 h 05 min")
        #expect(text(after: 26 * 3600 + 40 * 60) == "26 h 40 min")
        // A clock behind the start reads 0 min.
        #expect(text(after: -30) == "0 min")
        // A setup virtual machine counts from its start.
        let setup = try #require(VMPopoverPresentation.rows(nil, chats: [:], setups: [Self.setup(after: 60)]).first)
        #expect(VMPopoverPresentation.runningTime(setup, now: Self.started.addingTimeInterval(60 + 65 * 60)) == "1 h 05 min")
    }

    @Test("A preview is 160 × 100 points, taken every 2 seconds")
    func preview() {
        #expect(VMPopoverPresentation.previewSize == CGSize(width: 160, height: 100))
        #expect(VMPopoverPresentation.previewInterval == .seconds(2))
    }
}
