import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/ui.md › WindowState and › Persistence: a window state persisted by an earlier version still
/// restores when it holds keys that the window state no longer has.
@MainActor
@Suite("Persisted window state")
struct PersistedWindowStateTests {
    @Test("A window state persisted with consoleVisible, consoleHeight and consoleRunID restores its other properties")
    func earlierConsoleKeys() throws {
        let json = """
            {"consoleHeight":300,"consoleVisible":true,"deviceID":"device","id":"6F1C2D3E-4A5B-4C6D-8E7F-9A0B1C2D3E4F",
             "inspectorVisible":false,"inspectorWidth":420,"lastProjectByDevice":{"device":"DEMO"},"projectID":"DEMO",
             "projectStates":[{"deviceID":"device","projectID":"DEMO","state":{
               "consoleRunID":"0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","docMode":"split","editorTabs":[],"hidesClosedChats":false,
               "inspectorShowsDraft":false,"selectedChatIDs":["chat"],"selectedTicketIDs":[]}}],
             "section":"chats","sidebarVisible":true}
            """
        let restored = try #require(WindowState.restored(fromJSON: json))
        #expect(restored.id == UUID(uuidString: "6F1C2D3E-4A5B-4C6D-8E7F-9A0B1C2D3E4F"))
        #expect(restored.deviceID == "device")
        #expect(restored.projectID == "DEMO")
        #expect(restored.section == .chats)
        #expect(!restored.inspectorVisible)
        #expect(restored.inspectorWidth == 420)
        #expect(restored.lastProjectByDevice == ["device": "DEMO"])
        #expect(restored.viewState.selectedChatIDs == ["chat"])
        #expect(restored.viewState.docMode == .split)
        #expect(!restored.viewState.hidesClosedChats)

        // The restored state no longer writes the console keys.
        let persisted = try #require(restored.persistedJSON)
        #expect(!persisted.contains("console"))
    }
}
