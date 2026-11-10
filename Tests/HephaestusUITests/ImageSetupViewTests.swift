import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/virtual-machines.md › Setup view, › Linked item and docs/ui.md › WindowState: the window
/// state of the setup view of an image, leaving it, the end of its setup and its linked item. No
/// test starts a virtual machine.
@MainActor
@Suite("Image setup view")
struct ImageSetupViewTests {
    static let imageID = UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!
    static let vmID = UUID(uuidString: "7D2C1A90-5E4B-4F3A-8B6C-1D0E9F8A7B6C")!

    @Test("Showing the setup view leaves the section unselected; selecting any section, the same one included, leaves it")
    func showAndLeave() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .tickets
        window.shownImageSetupID = Self.imageID
        #expect(window.shownSection == nil)
        #expect(window.section == .tickets)
        #expect(!window.isRowSelected(.tickets))
        window.section = .tickets
        #expect(window.shownImageSetupID == nil)
        #expect(window.shownSection == .tickets)
        window.shownImageSetupID = Self.imageID
        window.section = .costs
        #expect(window.shownImageSetupID == nil && window.shownSection == .costs)
    }

    @Test("The setup view leaves on the same events as the detail of a virtual machine, and the two leave each other")
    func otherViews() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.projectID = "DEMO"
        window.showsGlobalMemories = true
        window.shownImageSetupID = Self.imageID
        #expect(!window.showsGlobalMemories && window.shownImageSetupID == Self.imageID)
        window.showsGlobalMemories = true
        #expect(window.showsGlobalMemories && window.shownImageSetupID == nil)

        window.showsInternalSkills = true
        window.shownImageSetupID = Self.imageID
        #expect(!window.showsInternalSkills && !window.showsGlobalMemories)
        window.showsInternalSkills = true
        #expect(window.shownImageSetupID == nil)

        window.showSubProject("SUB")
        window.shownImageSetupID = Self.imageID
        #expect(window.subProjectDashboardID == nil)
        window.showSubProject("SUB")
        #expect(window.subProjectDashboardID == "SUB" && window.shownImageSetupID == nil)

        // The detail of a virtual machine and the setup view leave each other.
        window.shownImageSetupID = Self.imageID
        window.shownVirtualMachineID = Self.vmID
        #expect(window.shownImageSetupID == nil && window.shownVirtualMachineID == Self.vmID)
        window.shownImageSetupID = Self.imageID
        #expect(window.shownImageSetupID == Self.imageID && window.shownVirtualMachineID == nil)
        #expect(window.shownSection == nil)

        // A switch of project keeps the setup view; a switch of device leaves it.
        window.projectID = "OTHER"
        #expect(window.shownImageSetupID == Self.imageID)
        window.deviceID = "remote"
        #expect(window.shownImageSetupID == nil)
    }

    @Test("The setup view is encoded with the window's state and never persisted: a restored window shows its section")
    func coding() throws {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .docs
        window.shownImageSetupID = Self.imageID
        let json = String(decoding: try EngineJSON.encode(window), as: UTF8.self)
        #expect(json.contains(#""shownImageSetupID":"5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F""#))
        let decoded = try EngineJSON.decode(WindowState.self, from: Data(json.utf8))
        #expect(decoded.shownImageSetupID == Self.imageID && decoded.section == .docs && decoded.shownSection == nil)

        let persisted = try #require(window.persistedJSON)
        #expect(!persisted.contains("shownImageSetupID"))
        let restored = try #require(WindowState.restored(fromJSON: persisted))
        #expect(restored.shownImageSetupID == nil && restored.shownSection == .docs)
    }

    @Test("The end of the setup takes the window back to its section, after OK of the alert of a failure")
    func setupEnded() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .docs

        // A window that does not show the setup view keeps what it shows.
        #expect(!window.imageSetupEnded(Self.imageID, failure: nil))
        window.shownImageSetupID = Self.imageID
        #expect(!window.imageSetupEnded(UUID(), failure: nil))
        #expect(window.shownImageSetupID == Self.imageID)

        // Finish Setup, Stop, a guest that shut down or a deleted image: back to the section.
        #expect(window.imageSetupEnded(Self.imageID, failure: nil))
        #expect(window.shownImageSetupID == nil && window.shownSection == .docs && window.alert == nil)

        // A virtual machine that failed: the alert shows over the setup view, and OK leaves it.
        window.shownImageSetupID = Self.imageID
        let failure = WindowAlert(title: VMImagePresentation.setUpFailedTitle, message: "The virtual machine stopped.")
        #expect(window.imageSetupEnded(Self.imageID, failure: failure))
        #expect(window.alert == failure && window.shownImageSetupID == Self.imageID)
        window.alert = nil
        #expect(window.shownImageSetupID == nil && window.shownSection == .docs)

        // A window that left the setup view meanwhile: OK changes nothing more.
        window.shownImageSetupID = Self.imageID
        #expect(window.imageSetupEnded(Self.imageID, failure: failure))
        window.section = .costs
        window.shownImageSetupID = Self.imageID
        window.alert = nil
        #expect(window.shownImageSetupID == Self.imageID)
    }

    @Test("The setup view's header shows Running · <time> from Set Up… on")
    func runningText() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(VMImagePresentation.setupRunningText(since: started, now: started) == "Running · 0 min")
        #expect(VMImagePresentation.setupRunningText(since: started, now: started.addingTimeInterval(65 * 60)) == "Running · 1 h 05 min")
        #expect(VMImagePresentation.setupRunningText(since: started, now: started.addingTimeInterval(-30)) == "Running · 0 min")
    }

    @Test("The composer links the setup virtual machine, with display, Set Up macOS <version> and the image's id, and nothing else")
    func linkedItem() {
        var state = ProjectViewState()
        state.selectedTicketIDs = ["DEMO-1"]
        let ticket = Ticket(id: "DEMO-1", title: "T", created: Date())
        #expect(state.openItems(in: nil, imageSetupID: Self.imageID).map(\.key) == ["imageSetup:5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F"])
        func linked(_ versions: [UUID: String]) -> [LinkedItem] {
            LinkedItems.linked(state: state, section: nil, tickets: ["DEMO-1": ticket], bundles: [:], chats: [:], webTabs: [],
                               imageSetupID: Self.imageID, setupVersions: versions)
        }
        let text = "setup virtual machine of the image “macOS 26.6.2” (5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F)"
        let items = linked([UUID(): "27.2.1", Self.imageID: "26.6.2"])
        #expect(items.map(\.name) == ["Set Up macOS 26.6.2"])
        #expect(items.map(\.text) == [text])
        #expect(items.map(\.line) == ["Open in the app: \(text)"])
        #expect(items.first?.chatLinkedItem == ChatLinkedItem(kind: .virtualMachine, name: "Set Up macOS 26.6.2", text: text))
        #expect(items.first?.chatLinkedItem.kind.symbol == "display")
        // A setup that no longer runs is not linked.
        #expect(linked([:]).isEmpty)

        // × unlinks it while the setup view shows; it is linked again the next time.
        state.unlinkedItems = ["imageSetup:5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F"]
        #expect(linked([Self.imageID: "26.6.2"]).isEmpty)
        state.forgetClosedUnlinkedItems(in: nil, imageSetupID: Self.imageID)
        #expect(state.unlinkedItems.count == 1)
        state.forgetClosedUnlinkedItems(in: .tickets)
        #expect(state.unlinkedItems.isEmpty)
    }

    @Test("Without a project, the setup view shows the image's newest Auto Setup chat that belongs to no project; the inspector lists setup chats")
    func setupChatBesideTheView() {
        func chat(_ kind: ChatKind, image: UUID?, project: String, created: String) -> ChatMeta {
            ChatMeta(id: UUID(), kind: kind, imageID: image, created: ISODate.date(from: created)!, projectID: project)
        }
        let older = chat(.setup, image: Self.imageID, project: "", created: "2026-11-10T20:00:00Z")
        let newer = chat(.setup, image: Self.imageID, project: "", created: "2026-11-10T21:00:00Z")
        let inProject = chat(.setup, image: Self.imageID, project: "DEMO", created: "2026-11-10T22:00:00Z")
        let otherImage = chat(.setup, image: UUID(), project: "", created: "2026-11-10T23:00:00Z")
        let chats = Dictionary(uniqueKeysWithValues: [older, newer, inProject, otherImage].map { ($0.id.uuidString, $0) })
        #expect(ImageSetupWithChat.setupChat(of: Self.imageID, in: chats)?.id == newer.id)
        #expect(ImageSetupWithChat.setupChat(of: UUID(), in: chats) == nil)
        #expect(ProjectChatPanel.listedKinds == [.project, .setup])
        #expect(VMImagePresentation.setUpTitle == "Set Up…" && VMImagePresentation.manualSetupTitle == "Manual Setup"
            && VMImagePresentation.autoSetupTitle == "Auto Setup")
    }
}
