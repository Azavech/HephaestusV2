import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/costs.md › Costs section and › Amount format: the groups of a project and its
/// descendants, the lines, their order, the deleted chats toggle and the amounts.
@Suite("Cost breakdown")
struct CostBreakdownTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    var projects: [ProjectSummary] {
        [
            ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["API"], ownCostUSD: 1.5, costUSD: 2.5),
            ProjectSummary(id: "API", name: "Api", rootPath: "/Users/example/Demo/api", parentID: "DEMO", subprojectIDs: ["DB"],
                           ownCostUSD: 0.75, costUSD: 1),
            ProjectSummary(id: "DB", name: "Db", rootPath: "/Users/example/Demo/api/db", parentID: "API", ownCostUSD: 0.25, costUSD: 0.25),
            ProjectSummary(id: "WEB", name: "Website", rootPath: "/Users/example/Web", ownCostUSD: 9, costUSD: 9),
        ]
    }

    func chat(_ project: String, _ title: String, _ cost: Double?, kind: ChatKind = .project, ticketID: String? = nil,
              updated: TimeInterval = 0) -> ChatMeta {
        ChatMeta(id: UUID(), title: title, kind: kind, ticketID: ticketID, created: created,
                 updated: created.addingTimeInterval(updated), projectID: project, costUSD: cost)
    }

    @Test("One group per project and descendant, with depths and subtotals; other projects are left out")
    func groups() throws {
        let breakdown = try #require(CostBreakdown(projectID: "DEMO", projects: projects, chats: [], deletedChats: [:], showDeleted: false))
        #expect(breakdown.totalUSD == 2.5)
        #expect(breakdown.groups.map(\.id) == ["DEMO", "API", "DB"])
        #expect(breakdown.groups.map(\.depth) == [0, 1, 2])
        #expect(breakdown.groups.map(\.subtotalUSD) == [1.5, 0.75, 0.25])
        let sub = try #require(CostBreakdown(projectID: "API", projects: projects, chats: [], deletedChats: [:], showDeleted: false))
        #expect(sub.groups.map(\.id) == ["API", "DB"])
        #expect(CostBreakdown(projectID: "NONE", projects: projects, chats: [], deletedChats: [:], showDeleted: false) == nil)
    }

    @Test("Lines: highest cost first, chats without a cost last by update; deleted chats only with the toggle")
    func lines() throws {
        let chats = [
            chat("DEMO", "Cheap", 0.25),
            chat("DEMO", "Dear", 1, kind: .ticket, ticketID: "DEMO-3"),
            chat("DEMO", "Old empty", nil, updated: 1),
            chat("DEMO", "New empty", nil, kind: .feedback, ticketID: "DEMO-4", updated: 2),
            chat("API", "Elsewhere", 0.75),
        ]
        let deleted = ["DEMO": [DeletedChat(id: UUID(), title: "Gone", kind: .bundle, bundleID: "DEMO-B1", costUSD: 0.5, deleted: created)]]
        let hidden = try #require(CostBreakdown(projectID: "DEMO", projects: projects, chats: chats, deletedChats: deleted,
                                                showDeleted: false))
        #expect(hidden.groups[0].lines.map(\.title) == ["Dear", "Cheap", "New empty", "Old empty"])
        #expect(hidden.groups[0].lines.map(\.kind) == ["Ticket DEMO-3", "Project", "Feedback DEMO-4", "Project"])
        #expect(hidden.groups[1].lines.map(\.title) == ["Elsewhere"])
        #expect(hidden.groups[1].loading)
        #expect(!hidden.groups[0].loading)
        let shown = try #require(CostBreakdown(projectID: "DEMO", projects: projects, chats: chats, deletedChats: deleted,
                                               showDeleted: true))
        #expect(shown.groups[0].lines.map(\.title) == ["Dear", "Gone", "Cheap", "New empty", "Old empty"])
        #expect(shown.groups[0].lines[1].deleted && shown.groups[0].lines[1].kind == "Bundle DEMO-B1")
        // The subtotal includes the deleted chats whether they are shown or not.
        #expect(shown.groups[0].subtotalUSD == hidden.groups[0].subtotalUSD)
        // Every line belongs to a cost source: Claude chats are the only one.
        #expect(shown.groups.flatMap(\.lines).allSatisfy { $0.source == .claudeChats })
        #expect(CostBreakdown.lines(.claudeChats, chats: chats.filter { $0.projectID == "DEMO" }, deletedChats: deleted["DEMO"]!,
                                    showDeleted: true).count == 5)
    }

    @Test("Amounts: $0.00 for 0, < $0.01 below a cent, else two decimals")
    func amounts() {
        #expect(CostBreakdown.amount(0) == "$0.00")
        #expect(CostBreakdown.amount(0.004) == "< $0.01")
        #expect(CostBreakdown.amount(12.345) == "$12.35" || CostBreakdown.amount(12.345) == "$12.34")
        #expect(CostBreakdown.amount(1.5) == "$1.50")
    }
}
