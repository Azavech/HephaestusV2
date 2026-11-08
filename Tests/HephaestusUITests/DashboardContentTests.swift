import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/dashboard.md › Cards: the list of the Recent chats card.
@MainActor
@Suite("Dashboard content")
struct DashboardContentTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Recent chats: the project's 5 most recently updated chats, newest first")
    func recentChats() {
        let chats = (0..<7).map { index in
            ChatMeta(id: UUID(), title: "Chat \(index)", kind: .project, created: start,
                     updated: start.addingTimeInterval(Double(index)), projectID: "DEMO")
        } + [ChatMeta(id: UUID(), title: "Other", kind: .project, created: start, updated: start.addingTimeInterval(99), projectID: "WEB")]
        let recent = DashboardContent.recentChats(of: "DEMO", in: chats.shuffled())
        #expect(recent.map(\.title) == ["Chat 6", "Chat 5", "Chat 4", "Chat 3", "Chat 2"])
        #expect(DashboardContent.recentChats(of: "NONE", in: chats).isEmpty)
    }
}
