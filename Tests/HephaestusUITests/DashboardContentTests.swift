import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/dashboard.md › Cards: the Recent chats and Running commands lists.
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

    @Test("Running commands: only the runs that are running, newest first")
    func runningRuns() {
        func run(_ kind: RunKind, _ offset: Double) -> RunState {
            RunState(info: RunInfo(runID: UUID(), projectID: "DEMO", kind: kind, command: "make \(kind.rawValue)",
                                   started: start.addingTimeInterval(offset)), starter: nil)
        }
        var finished = run(.test, 3)
        finished.exitCode = 0
        let running = DashboardContent.runningRuns([run(.build, 1), finished, run(.run, 2)])
        #expect(running.map(\.info.kind) == [.run, .build])
    }
}
