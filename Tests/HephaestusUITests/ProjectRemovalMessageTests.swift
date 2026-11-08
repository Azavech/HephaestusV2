import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Removing a project: the message of the confirmation names the folder and the
/// sub projects removed with the project, and ends with `Running chats of these projects are
/// stopped.` when the window's workspace knows a working chat among the removed projects.
@MainActor
@Suite("Project removal message")
struct ProjectRemovalMessageTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let demo = ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo")
    static let backend = ProjectSummary(id: "BACK", name: "Backend", rootPath: "/Users/example/Demo/Backend", parentID: "DEMO")
    static let frontend = ProjectSummary(id: "FRONT", name: "Frontend", rootPath: "/Users/example/Demo/Frontend", parentID: "DEMO")

    static func chat(_ state: ChatState, projectID: ProjectID) -> ChatMeta {
        ChatMeta(id: UUID(), kind: .project, created: created, projectID: projectID, state: state)
    }

    /// The message for removing Demo with its sub project Backend.
    static func message(_ workspace: DeviceWorkspace) -> String {
        ProjectFlows.removalMessage(project: demo, descendants: [backend], workspace: workspace, removedIDs: ["DEMO", "BACK"])
    }

    @Test("A working chat of a removed sub project adds the running chats sentence; a chat elsewhere or a chat that is not working does not")
    func workingChatAmongTheRemovedProjects() {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let withoutRunningChats = "The folder and its files stay on disk: /Users/example/Demo. Its sub project “Backend” is removed with it."
        #expect(Self.message(workspace) == withoutRunningChats)

        for meta in [Self.chat(.running, projectID: "OTHER"), Self.chat(.idle, projectID: "BACK"),
                     Self.chat(.waitingAnswers, projectID: "DEMO"), Self.chat(.error, projectID: "DEMO")] {
            workspace.chats[meta.id.uuidString] = meta
        }
        #expect(Self.message(workspace) == withoutRunningChats)

        let working = Self.chat(.waitingPermission, projectID: "BACK")
        workspace.chats[working.id.uuidString] = working
        #expect(Self.message(workspace) == withoutRunningChats + " Running chats of these projects are stopped.")
    }

    @Test("Several sub projects are counted; a project without sub projects names only its folder")
    func subProjects() {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let working = Self.chat(.starting, projectID: "FRONT")
        workspace.chats[working.id.uuidString] = working
        #expect(ProjectFlows.removalMessage(project: Self.demo, descendants: [Self.backend, Self.frontend], workspace: workspace,
                                            removedIDs: ["DEMO", "BACK", "FRONT"])
            == "The folder and its files stay on disk: /Users/example/Demo. Its 2 sub projects are removed with it. "
            + "Running chats of these projects are stopped.")
        #expect(ProjectFlows.removalMessage(project: Self.backend, descendants: [], workspace: workspace, removedIDs: ["BACK"])
            == "The folder and its files stay on disk: /Users/example/Demo/Backend.")
    }
}
