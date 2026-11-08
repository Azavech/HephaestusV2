import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/memories.md › Global Memories view and docs/ui.md › WindowState: the window state of the
/// view, the sidebar selection, the linked items, the unsaved editors and the workspace's list.
@MainActor
@Suite("Global Memories view")
struct GlobalMemoriesViewTests {
    @Test("Showing the view leaves the section unselected; selecting any section, the same one included, leaves the view")
    func showAndLeave() {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .tickets
        window.showsGlobalMemories = true
        #expect(window.shownSection == nil)
        #expect(window.section == .tickets)
        window.section = .tickets
        #expect(!window.showsGlobalMemories)
        #expect(window.shownSection == .tickets)
        window.showsGlobalMemories = true
        window.section = .costs
        #expect(!window.showsGlobalMemories && window.shownSection == .costs)
    }

    @Test("The composer links no item while the view shows")
    func linkedItems() {
        var state = ProjectViewState()
        state.selectedTicketIDs = ["DEMO-1"]
        #expect(state.openItems(in: .tickets).map(\.key) == ["ticket:DEMO-1"])
        #expect(state.openItems(in: nil).isEmpty)
        let ticket = Ticket(id: "DEMO-1", title: "T", created: Date())
        #expect(LinkedItems.linked(state: state, section: .tickets, tickets: ["DEMO-1": ticket], bundles: [:], chats: [:], webTabs: []).count == 1)
        #expect(LinkedItems.linked(state: state, section: nil, tickets: ["DEMO-1": ticket], bundles: [:], chats: [:], webTabs: []).isEmpty)
        // An item unlinked with × is no longer open while the view shows, so it is linked again later.
        state.unlinkedItems = ["ticket:DEMO-1"]
        state.forgetClosedUnlinkedItems(in: nil)
        #expect(state.unlinkedItems.isEmpty)
    }

    @Test("The view's state is kept per device; the persisted state holds the view and the selected row of the window's device")
    func coding() throws {
        let window = WindowState(id: UUID(), deviceID: "device")
        window.section = .memories
        window.showsGlobalMemories = true
        window.updateMemoryViewState(.global, deviceID: "device") {
            $0.selectedMemoryFile = "short-answers.md"
            $0.memoryBodyMode = .edit
        }
        window.updateMemoryViewState(.global, deviceID: "other") { $0.selectedMemoryFile = "MEMORY.md" }
        window.updateMemoryViewState(.project("DEMO"), deviceID: "device") { $0.selectedMemoryFile = "user-role.md" }
        #expect(window.memoryViewState(.global, deviceID: "device").selectedMemoryFile == "short-answers.md")
        #expect(window.memoryViewState(.global, deviceID: "other").selectedMemoryFile == "MEMORY.md")
        #expect(window.projectStates[ProjectKey(deviceID: "device", projectID: "DEMO")]?.selectedMemoryFile == "user-role.md")
        #expect(window.memoryViewState(.project("DEMO"), deviceID: "device").selectedMemoryFile == "user-role.md")

        let persisted = try #require(window.persistedJSON)
        let restored = try #require(WindowState.restored(fromJSON: persisted))
        #expect(restored.showsGlobalMemories)
        #expect(restored.section == .memories)
        #expect(restored.globalMemoryStates.keys.sorted() == ["device"])
        #expect(restored.memoryViewState(.global, deviceID: "device").selectedMemoryFile == "short-answers.md")
        // The mode and the editor are never encoded.
        #expect(restored.memoryViewState(.global, deviceID: "device").memoryBodyMode == .preview)

        // debug_ui_state encodes every device's entry.
        let data = try EngineJSON.encoder().encode(window)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""globalMemoryStates":{"device":{"selectedMemoryFile":"short-answers.md"},"other":{"selectedMemoryFile":"MEMORY.md"}}"#))
        #expect(json.contains(#""showsGlobalMemories":true"#))
    }

    @Test("Closing the window counts the view's unsaved editor; removing a project does not")
    func unsavedEditors() {
        let window = WindowState(id: UUID(), deviceID: "device")
        let editor = MemoryEditorState(target: .index, scope: .global)
        editor.index.diskText = "- [a](a.md) — A\n"
        editor.index.text = "- [a](a.md) — B\n"
        window.updateMemoryViewState(.global, deviceID: "device") { $0.memoryEditor = editor }
        #expect(window.unsavedEditors().count == 1)
        #expect(window.unsavedEditors(deviceID: "device").count == 1)
        #expect(window.unsavedEditors(deviceID: "other").isEmpty)
        #expect(window.unsavedEditors(deviceID: "device", projectIDs: ["DEMO"]).isEmpty)
    }

    @Test("memories.changed without projectID replaces the workspace's global memories once a view listed them")
    func workspaceEvents() {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let folder = MemoryFolder(projectID: nil, path: "/Users/example/.claude/memory", hasIndex: true,
                                  memories: [MemorySummary(file: "a.md", name: "a", description: "A", type: "user")])
        var event = WorkspaceEvent(origin: .system, event: .memoriesChanged(folder))
        workspace.apply(&event)
        #expect(workspace.globalMemories == nil)
        workspace.setMemoryFolder(MemoryFolder(projectID: nil, path: folder.path, hasIndex: false, memories: []), for: .global)
        workspace.apply(&event)
        #expect(workspace.globalMemories == folder)
        #expect(workspace.memoryFolder(.global) == folder)
        #expect(workspace.memoryFolders.isEmpty)
        // A project's event leaves the global memories alone.
        workspace.setMemoryFolder(MemoryFolder(projectID: "DEMO", path: "/p", hasIndex: false, memories: []), for: .project("DEMO"))
        var projectEvent = WorkspaceEvent(origin: .system, event: .memoriesChanged(MemoryFolder(projectID: "DEMO", path: "/p", hasIndex: true, memories: [])))
        workspace.apply(&projectEvent)
        #expect(workspace.memoryFolders["DEMO"]?.hasIndex == true)
        #expect(workspace.globalMemories == folder)
    }

    @Test("The New Memory sheet of the view has no projectID and belongs to no project")
    func sheet() {
        #expect(WindowSheet.newMemory(projectID: nil).projectID == nil)
        #expect(WindowSheet.newMemory(projectID: "DEMO").projectID == "DEMO")
        #expect(MemoryScope(projectID: nil) == .global)
        #expect(MemoryScope.project("DEMO").projectID == "DEMO")
    }
}
