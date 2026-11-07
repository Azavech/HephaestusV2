import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Tickets section, › Ticket list: the tickets of the loaded descendants in a
/// project's list, the grouped ID sort, the Project column and its sort, the project name in the
/// text filter, and Create Bundle from Selection.
@MainActor
@Suite("Ticket list with sub projects")
struct TicketListSubprojectsTests {
    let created = Date(timeIntervalSince1970: 1_800_000_000)

    /// DEMO with the sub projects MUS, whose sub project is API, and SHR: `projects.list` order
    /// DEMO, MUS, API, SHR; WEB is another top-level project.
    private func workspace() -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.projects = [
            ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["MUS", "SHR"]),
            ProjectSummary(id: "MUS", name: "yc-music", rootPath: "/Users/example/Demo/music", parentID: "DEMO", subprojectIDs: ["API"]),
            ProjectSummary(id: "API", name: "Api", rootPath: "/Users/example/Demo/music/api", parentID: "MUS"),
            ProjectSummary(id: "SHR", name: "Shared", rootPath: "/Users/example/Demo/shared", parentID: "DEMO"),
            ProjectSummary(id: "WEB", name: "Website", rootPath: "/Users/example/Web"),
        ]
        let tickets = [
            ticket("DEMO-1", "Delta", minutes: 0), ticket("DEMO-2", "Alpha", minutes: 5),
            ticket("MUS-1", "Charlie", minutes: 1), ticket("MUS-2", "Bravo", minutes: 3),
            ticket("API-1", "Echo", minutes: 2), ticket("API-2", "Foxtrot", .done, minutes: 6),
            ticket("SHR-1", "Alpha", minutes: 4),
            ticket("WEB-1", "Website ticket", minutes: 7),
        ]
        for ticket in tickets {
            workspace.tickets[ticket.projectID ?? "", default: [:]][ticket.id] = ticket
        }
        return workspace
    }

    private func ticket(_ id: String, _ title: String, _ status: TicketStatus = .todo, minutes: Double) -> Ticket {
        Ticket(id: id, title: title, status: status, created: created.addingTimeInterval(minutes * 60))
    }

    /// The ids the list shows with `state`, in its order.
    private func shown(_ state: TicketListState, projectID: String = "DEMO", in workspace: DeviceWorkspace) -> [String] {
        let projects = TicketListProjects(projectID: projectID, workspace: workspace)
        let tickets = projects.tickets(in: workspace).values.filter { state.matches($0, projectName: projects.name(of: $0)) }
        return state.sorted(tickets, projects: projects).map(\.id)
    }

    @Test("A project lists its tickets and those of all its descendants, in projects.list order; a project without sub projects its own")
    func scope() {
        let workspace = workspace()
        let demo = TicketListProjects(projectID: "DEMO", workspace: workspace)
        #expect(demo.ids == ["DEMO", "MUS", "API", "SHR"])
        #expect(demo.names == ["DEMO": "Demo", "MUS": "yc-music", "API": "Api", "SHR": "Shared"])
        #expect(Set(demo.tickets(in: workspace).keys) == ["DEMO-1", "DEMO-2", "MUS-1", "MUS-2", "API-1", "API-2", "SHR-1"])
        #expect(TicketListProjects(projectID: "MUS", workspace: workspace).ids == ["MUS", "API"])
        let api = TicketListProjects(projectID: "API", workspace: workspace)
        #expect(api.ids == ["API"])
        #expect(Set(api.tickets(in: workspace).keys) == ["API-1", "API-2"])
    }

    @Test("The Project column follows ID only while the active project has a loaded sub project")
    func projectColumn() {
        let workspace = workspace()
        let demo = TicketListProjects(projectID: "DEMO", workspace: workspace)
        #expect(demo.showsProjectColumn)
        #expect(TicketListView.columns(tickets: [:], projects: demo).map(\.id) == ["id", "project", "title", "status", "created"])
        let project = TicketListView.columns(tickets: [:], projects: demo)[1]
        #expect(project.title == "Project")
        #expect(project.sizing == .shrinkableContent)
        #expect(project.minWidth == 40)

        let api = TicketListProjects(projectID: "API", workspace: workspace)
        #expect(!api.showsProjectColumn)
        #expect(TicketListView.columns(tickets: [:], projects: api).map(\.id) == ["id", "title", "status", "created"])
        #expect(!TicketListProjects(projectID: "WEB", workspace: workspace).showsProjectColumn)
    }

    @Test("Project badges: each listed project's color, gray with white text without one, black or white text by contrast")
    func projectBadges() {
        let workspace = workspace()
        workspace.projects[1].color = "#FFD60A"
        workspace.projects[3].color = "#13284D"
        let demo = TicketListProjects(projectID: "DEMO", workspace: workspace)
        #expect(demo.colors == ["MUS": "#FFD60A", "SHR": "#13284D"])
        #expect(demo.color(of: ticket("MUS-1", "Charlie", minutes: 1)) == "#FFD60A")
        #expect(demo.color(of: ticket("DEMO-1", "Delta", minutes: 0)) == nil)
        // A color change makes a new value, so that the table makes its columns again.
        workspace.projects[1].color = "#34C759"
        #expect(TicketListProjects(projectID: "DEMO", workspace: workspace) != demo)

        #expect(ProjectBadge.fill(of: nil) == StatusCapsule.color(of: .todo))
        #expect(ProjectBadge.textColor(of: nil) == .white)
        #expect(ProjectBadge.usesBlackText("#FFD60A"))
        #expect(ProjectBadge.usesBlackText("#FFFFFF"))
        #expect(!ProjectBadge.usesBlackText("#13284D"))
        #expect(!ProjectBadge.usesBlackText("#000000"))
        #expect(ProjectBadge.textColor(of: "#FFD60A") == .black)
        #expect(ProjectBadge.textColor(of: "#13284D") == .white)
        #expect(ProjectBadge.width(of: "yc-music") > ProjectBadge.width(of: "Api"))
    }

    @Test("ID: grouped by project, the active project first, newest first; reversed, each group oldest first in the same group order")
    func groupedIDSort() {
        let workspace = workspace()
        var state = TicketListState()
        #expect(shown(state, in: workspace) == ["DEMO-2", "DEMO-1", "MUS-2", "MUS-1", "API-1", "SHR-1"])
        state.sortAscending = true
        #expect(shown(state, in: workspace) == ["DEMO-1", "DEMO-2", "MUS-1", "MUS-2", "API-1", "SHR-1"])
        // The active project's group comes first, also for a sub project.
        state.sortAscending = false
        #expect(shown(state, projectID: "MUS", in: workspace) == ["MUS-2", "MUS-1", "API-1"])
    }

    @Test("Project sorts by project name, equal names in ID order; Title, Status and Created sort every ticket together")
    func otherSorts() {
        let workspace = workspace()
        var state = TicketListState()
        state.sortColumn = .project
        state.sortAscending = true
        #expect(shown(state, in: workspace) == ["API-1", "DEMO-2", "DEMO-1", "SHR-1", "MUS-2", "MUS-1"])
        state.sortAscending = false
        #expect(shown(state, in: workspace) == ["MUS-2", "MUS-1", "SHR-1", "DEMO-2", "DEMO-1", "API-1"])

        state.sortColumn = .title
        state.sortAscending = true
        // The two Alpha tickets keep the ID order: DEMO's group before SHR's.
        #expect(shown(state, in: workspace) == ["DEMO-2", "SHR-1", "MUS-2", "MUS-1", "DEMO-1", "API-1"])

        state.sortColumn = .created
        state.sortAscending = false
        #expect(shown(state, in: workspace) == ["DEMO-2", "SHR-1", "MUS-2", "API-1", "MUS-1", "DEMO-1"])
    }

    @Test("The text filter matches the project name; the status filter applies to every project")
    func filters() {
        let workspace = workspace()
        var state = TicketListState()
        state.textFilter = "yc-music"
        #expect(shown(state, in: workspace) == ["MUS-2", "MUS-1"])
        state.textFilter = "YC-MUSIC charlie"
        #expect(shown(state, in: workspace) == ["MUS-1"])
        #expect(TicketListState.matches(ticket("MUS-1", "Charlie", minutes: 0), text: "music", projectName: "yc-music"))
        #expect(!TicketListState.matches(ticket("MUS-1", "Charlie", minutes: 0), text: "music"))

        // API-2 is done: hidden until Show Done is on.
        state.textFilter = ""
        #expect(!shown(state, in: workspace).contains("API-2"))
        state.showDone = true
        #expect(shown(state, in: workspace).contains("API-2"))

        // A navigation target clears a text filter that only the project name would match.
        var target = TicketListState()
        target.textFilter = "yc-music"
        target.clearFilters(hiding: ticket("MUS-1", "Charlie", minutes: 0), projectName: "yc-music")
        #expect(target.textFilter == "yc-music")
        target.clearFilters(hiding: ticket("DEMO-1", "Delta", minutes: 0), projectName: "Demo")
        #expect(target.textFilter.isEmpty)
    }

    @Test("Create Bundle from Selection needs at least one ticket, all of one project, where the bundle is made")
    func bundleFromSelection() {
        #expect(TicketListProjects.bundleProject(of: ["MUS-1", "MUS-2"]) == "MUS")
        #expect(TicketListProjects.bundleProject(of: ["DEMO-1"]) == "DEMO")
        #expect(TicketListProjects.bundleProject(of: ["DEMO-1", "MUS-1"]) == nil)
        #expect(TicketListProjects.bundleProject(of: []) == nil)
    }

    @Test("The feedback item of the Tickets section is the first selected ticket in the list's order, sub project tickets included")
    func feedbackItem() {
        let workspace = workspace()
        let window = WindowState(deviceID: "device")
        window.projectID = "DEMO"
        window.section = .tickets
        var state = ProjectViewState()
        state.selectedTicketIDs = ["API-1", "MUS-1"]
        window.viewState = state
        #expect(FeedbackController.selectedItem(of: window, in: workspace, projectID: "DEMO") == "MUS-1")
        state.ticketList.sortColumn = .title
        state.ticketList.sortAscending = false
        window.viewState = state
        #expect(FeedbackController.selectedItem(of: window, in: workspace, projectID: "DEMO") == "API-1")
    }
}
