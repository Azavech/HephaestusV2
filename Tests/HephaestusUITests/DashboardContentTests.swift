import Foundation
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/dashboard.md › Widgets and Settings: what each widget shows.
@MainActor
@Suite("Dashboard content")
struct DashboardContentTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func chat(_ title: String, _ kind: ChatKind, at offset: Double, project: String = "DEMO") -> ChatMeta {
        ChatMeta(id: UUID(), title: title, kind: kind, ticketID: kind == .ticket ? "\(project)-1" : nil,
                 bundleID: kind == .bundle ? "\(project)-B1" : nil, created: start, updated: start.addingTimeInterval(offset), projectID: project)
    }

    @Test("Recent chats: the project's most recently updated chats of the checked kinds, newest first, at most the number of chats")
    func recentChats() {
        let chats = (0..<7).map { chat("Chat \($0)", .project, at: Double($0)) }
            + (0..<5).map { chat("Ticket \($0)", .ticket, at: Double(10 + $0)) }
            + [chat("Bundle", .bundle, at: 20), chat("Other", .project, at: 99, project: "WEB")]
        let defaults = DashboardWidget(kind: .recentChats)
        #expect(DashboardContent.recentChats(of: "DEMO", in: chats.shuffled(), widget: defaults).map(\.title)
            == ["Bundle", "Ticket 4", "Ticket 3", "Ticket 2", "Ticket 1"])
        let tickets = DashboardWidget(kind: .recentChats, chatCount: 3, chatKinds: [.ticket])
        #expect(DashboardContent.recentChats(of: "DEMO", in: chats.shuffled(), widget: tickets).map(\.title)
            == ["Ticket 4", "Ticket 3", "Ticket 2"])
        let projectChats = DashboardWidget(kind: .recentChats, chatCount: 20, chatKinds: [.project, .feedback])
        #expect(DashboardContent.recentChats(of: "DEMO", in: chats, widget: projectChats).count == 7)
        #expect(DashboardContent.recentChats(of: "NONE", in: chats, widget: defaults).isEmpty)
        #expect(DashboardContent.recentChats(of: "DEMO", in: chats, widget: DashboardWidget(kind: .recentChats, chatKinds: [])).isEmpty)
    }

    @Test("A number of chats outside 1–20, which only a hand edit gives, lists 1 or 20 chats")
    func chatLimit() {
        #expect(DashboardContent.chatLimit(of: DashboardWidget(kind: .recentChats)) == 5)
        #expect(DashboardContent.chatLimit(of: DashboardWidget(kind: .recentChats, chatCount: 0)) == 1)
        #expect(DashboardContent.chatLimit(of: DashboardWidget(kind: .recentChats, chatCount: -3)) == 1)
        #expect(DashboardContent.chatLimit(of: DashboardWidget(kind: .recentChats, chatCount: 50)) == 20)
        #expect(DashboardContent.chatLimit(of: DashboardWidget(kind: .recentChats, chatCount: 12)) == 12)
    }

    @Test("A widget's title is its Title setting, or the title of its kind when that is empty")
    func titles() {
        #expect(DashboardWidget.defaultList.map(DashboardContent.title(of:)) == ["Project", "Tickets", "Recent Chats", "Cost"])
        #expect(DashboardContent.title(of: DashboardWidget(kind: .cost, title: "Spend")) == "Spend")
        #expect(DashboardContent.title(of: DashboardWidget(kind: .cost, title: "  ")) == "Cost")
    }

    @Test("Tickets and Cost show the project and its descendants, or the project's own values without sub projects")
    func ownValues() {
        let project = ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo", subprojectIDs: ["SUB"],
                                     ticketCounts: TicketCounts(todo: 5, inProgress: 2, review: 1, done: 4),
                                     ownTicketCounts: TicketCounts(todo: 3, inProgress: 1, done: 4), ownCostUSD: 1.25, costUSD: 3.5)
        let tickets = DashboardWidget(kind: .tickets)
        #expect(DashboardContent.ticketCounts(of: project, widget: tickets) == project.ticketCounts)
        let own = DashboardWidget(kind: .tickets, includeSubprojects: false)
        #expect(DashboardContent.ticketCounts(of: project, widget: own) == project.ownTicketCounts)
        #expect(TicketStatus.allCases.map { DashboardContent.count($0, in: project.ownTicketCounts) } == [3, 1, 0, 4])
        #expect(DashboardContent.costUSD(of: project, widget: DashboardWidget(kind: .cost)) == 3.5)
        #expect(DashboardContent.costUSD(of: project, widget: DashboardWidget(kind: .cost, includeSubprojects: false)) == 1.25)
    }

    @Test("Fields and statuses show in the order of the settings, whatever the stored order")
    func order() {
        #expect(DashboardContent.fields(of: DashboardWidget(kind: .project, fields: [.folder, .name])) == [.name, .folder])
        #expect(DashboardContent.statuses(of: DashboardWidget(kind: .tickets, statuses: [.done, .todo, .done])) == [.todo, .done])
        #expect(DashboardContent.fields(of: DashboardWidget(kind: .project, fields: [])).isEmpty)
    }
}

/// docs/dashboard.md › Grid, Content and Edit mode: the cells in points, the widget that follows
/// the pointer and the scrolling.
@MainActor
@Suite("Dashboard grid metrics")
struct DashboardGridMetricsTests {
    /// A widget area 1088 points wide: cells of 30 points, 46 points from one to the next.
    let metrics = DashboardGridMetrics(width: 1088)

    func cells(_ column: Int, _ row: Int, _ width: Int, _ height: Int) -> DashboardCells {
        DashboardCells(column: column, row: row, width: width, height: height)
    }

    @Test("A cell is (width of the area − 23 × 16 points) / 24 wide, down to 5.5 points at the centre column's minimum width")
    func cell() {
        #expect(DashboardGridMetrics.gap == 16)
        #expect(metrics.cell == 30)
        #expect(metrics.pitch == 46)
        // The centre column at its minimum width of 540 points, without its margins of 20 points.
        #expect(DashboardGridMetrics(width: 500).cell == 5.5)
        #expect(DashboardGridMetrics(width: 368).cell == 0)
        #expect(DashboardGridMetrics(width: 0).cell == 0)
    }

    @Test("A widget's frame starts column and row × (cell + 16) points in, and is width × cell + (width − 1) × 16 points wide, its height alike")
    func frames() {
        #expect(metrics.length(0) == 0)
        #expect(metrics.length(1) == 30)
        #expect(metrics.length(12) == 536)
        #expect(metrics.length(24) == 1088)
        #expect(metrics.frame(of: cells(0, 0, 24, 1)) == CGRect(x: 0, y: 0, width: 1088, height: 30))
        #expect(metrics.frame(of: cells(12, 2, 12, 3)) == CGRect(x: 552, y: 92, width: 536, height: 122))
        // Two neighbouring widgets are 16 points apart.
        #expect(metrics.frame(of: cells(12, 0, 12, 1)).minX - metrics.frame(of: cells(0, 0, 12, 1)).maxX == 16)
        #expect(metrics.frame(of: cells(0, 3, 12, 1)).minY - metrics.frame(of: cells(0, 0, 12, 3)).maxY == 16)
        // The same cells at the minimum width: the arrangement stays, the cells are smaller.
        #expect(DashboardGridMetrics(width: 500).frame(of: cells(12, 2, 12, 3)) == CGRect(x: 258, y: 43, width: 242, height: 48.5))
    }

    @Test("The rows a content needs are the fewest that hold it; the cells of a dragged size and corner are the nearest")
    func counts() {
        #expect(metrics.cells(holding: 0) == 1)
        #expect(metrics.cells(holding: 30) == 1)
        #expect(metrics.cells(holding: 31) == 2)
        #expect(metrics.cells(holding: 122) == 3)
        #expect(metrics.cells(holding: 123) == 4)
        #expect(metrics.cells(holding: .infinity) == 1)
        // The same content needs more rows of smaller cells.
        #expect(DashboardGridMetrics(width: 500).cells(holding: 122) == 7)
        #expect(metrics.cells(nearest: 122) == 3)
        #expect(metrics.cells(nearest: 100) == 3)
        #expect(metrics.cells(nearest: 90) == 2)
        #expect(metrics.cells(nearest: -400) == 1)
        #expect(metrics.cell(nearest: 552) == 12)
        #expect(metrics.cell(nearest: 574) == 12)
        #expect(metrics.cell(nearest: 576) == 13)
        #expect(metrics.cell(nearest: -90) == 0)
    }

    @Test("A moved widget asks for the cells nearest to its top-left corner, inside the 24 columns and at row 0 or below")
    func moved() {
        let widget = cells(0, 0, 12, 4)
        #expect(metrics.cells(of: widget, movedTo: CGPoint(x: 50, y: 230)) == cells(1, 5, 12, 4))
        #expect(metrics.cells(of: widget, movedTo: CGPoint(x: 700, y: -50)) == cells(12, 0, 12, 4))
        #expect(metrics.cells(of: widget, movedTo: CGPoint(x: -300, y: 20)) == cells(0, 0, 12, 4))
        #expect(metrics.cells(of: cells(3, 3, 24, 2), movedTo: CGPoint(x: 400, y: 100)) == cells(0, 2, 24, 2))
        // A row under widgets stored at the row limit is not held to that limit.
        #expect(metrics.cells(of: widget, movedTo: CGPoint(x: 0, y: 46 * 150_000)) == cells(0, 150_000, 12, 4))
        #expect(metrics.cells(of: widget, movedTo: CGPoint(x: 0, y: CGFloat.infinity)) == cells(0, 0, 12, 4))
    }

    @Test("A resized widget asks for the nearest whole cells, not past column 24 nor smaller than its title row")
    func resized() {
        let widget = cells(6, 2, 6, 3)
        let smallest = DashboardSmallestSize(columns: 4, rows: 2)
        #expect(metrics.cells(of: widget, resizedTo: CGSize(width: 400, height: 260), smallest: smallest) == cells(6, 2, 9, 6))
        // The width never goes past column 24, and the height has no limit.
        #expect(metrics.cells(of: widget, resizedTo: CGSize(width: 1500, height: 2000), smallest: smallest) == cells(6, 2, 18, 44))
        // Not smaller than the title row.
        #expect(metrics.cells(of: widget, resizedTo: CGSize(width: 10, height: 10), smallest: smallest) == cells(6, 2, 4, 2))
        #expect(metrics.cells(of: widget, resizedTo: CGSize(width: -200, height: -200), smallest: DashboardSmallestSize()) == cells(6, 2, 1, 1))
        // Column 24 comes first: a title row that needs more columns than are left takes those.
        #expect(metrics.cells(of: cells(20, 0, 2, 2), resizedTo: CGSize(width: 10, height: 10), smallest: DashboardSmallestSize(columns: 6, rows: 2))
            == cells(20, 0, 4, 2))
    }

    @Test("The smallest size holds the title row at full width with its padding, at most 24 columns, at the cell size of the window")
    func smallestSize() {
        #expect(metrics.smallestSize(titleRow: CGSize(width: 125, height: 45)) == DashboardSmallestSize(columns: 4, rows: 2))
        #expect(DashboardGridMetrics(width: 500).smallestSize(titleRow: CGSize(width: 125, height: 45)) == DashboardSmallestSize(columns: 7, rows: 3))
        #expect(metrics.smallestSize(titleRow: CGSize(width: 2000, height: 45)) == DashboardSmallestSize(columns: 24, rows: 2))
        #expect(DashboardGridMetrics(width: 2000).smallestSize(titleRow: CGSize(width: 60, height: 45)) == DashboardSmallestSize(columns: 1, rows: 1))
    }

    @Test("A moved widget follows the pointer and the scroll of the Dashboard; a resized one keeps its corner and its smallest size")
    func dragTargets() {
        let slot = DashboardSlot(id: UUID(), occurrence: 0)
        let widget = cells(0, 0, 12, 4)
        var drag = DashboardDrag(slot: slot, kind: .move, start: CGPoint(x: 100, y: 100), location: CGPoint(x: 150, y: 130),
                                 startOffset: 20, offset: 220, arrangement: DashboardArrangement())
        #expect(drag.translation == CGSize(width: 50, height: 230))
        var target = drag.target(from: widget, metrics: metrics, smallest: DashboardSmallestSize())
        #expect(target.frame == CGRect(x: 50, y: 230, width: 536, height: 168))
        #expect(target.cells == cells(1, 5, 12, 4))
        // The widget follows the pointer outside the grid; its cells stay inside.
        drag.location = CGPoint(x: -400, y: -300)
        drag.offset = 20
        target = drag.target(from: widget, metrics: metrics, smallest: DashboardSmallestSize())
        #expect(target.frame.origin == CGPoint(x: -500, y: -400))
        #expect(target.cells == widget)

        drag = DashboardDrag(slot: slot, kind: .resize, start: CGPoint(x: 500, y: 150), location: CGPoint(x: 700, y: 250),
                             startOffset: 0, offset: 0, arrangement: DashboardArrangement())
        let smallest = DashboardSmallestSize(columns: 4, rows: 2)
        target = drag.target(from: widget, metrics: metrics, smallest: smallest)
        #expect(target.frame == CGRect(x: 0, y: 0, width: 736, height: 268))
        #expect(target.cells == cells(0, 0, 16, 6))
        // Past the right edge of the grid and under the smallest size, the widget stops.
        drag.location = CGPoint(x: 2000, y: -900)
        target = drag.target(from: widget, metrics: metrics, smallest: smallest)
        #expect(target.frame == CGRect(x: 0, y: 0, width: 1088, height: 76))
        #expect(target.cells == cells(0, 0, 24, 2))
        drag.location = CGPoint(x: -900, y: 150)
        target = drag.target(from: widget, metrics: metrics, smallest: smallest)
        #expect(target.frame == CGRect(x: 0, y: 0, width: 168, height: 168))
        #expect(target.cells == cells(0, 0, 4, 4))
    }

    @Test("The Dashboard scrolls within 40 points of the top or the bottom edge, faster nearer the edge, at 600 points per second at the edge and beyond")
    func autoScroll() {
        #expect(DashboardAutoScroll.velocity(pointer: 300, visibleHeight: 600) == 0)
        #expect(DashboardAutoScroll.velocity(pointer: 40, visibleHeight: 600) == 0)
        #expect(DashboardAutoScroll.velocity(pointer: 560, visibleHeight: 600) == 0)
        #expect(DashboardAutoScroll.velocity(pointer: 20, visibleHeight: 600) == -300)
        #expect(DashboardAutoScroll.velocity(pointer: 0, visibleHeight: 600) == -600)
        #expect(DashboardAutoScroll.velocity(pointer: -80, visibleHeight: 600) == -600)
        #expect(DashboardAutoScroll.velocity(pointer: 580, visibleHeight: 600) == 300)
        #expect(DashboardAutoScroll.velocity(pointer: 600, visibleHeight: 600) == 600)
        #expect(DashboardAutoScroll.velocity(pointer: 900, visibleHeight: 600) == 600)
    }

    @Test("An added widget is measured at its width: its title row, its content and its padding; a map counts 260 points and a chart 120")
    func neededHeight() {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let project = ProjectSummary(id: "DEMO", name: "A project with a name long enough to take several lines in a narrow widget",
                                     rootPath: "/Users/example/Demo")
        workspace.projects = [project]
        let window = WindowState(id: UUID(), deviceID: "device")
        let feed = DashboardGraphFeed()
        func height(_ kind: DashboardWidgetKind, width: CGFloat = 536) -> CGFloat {
            DashboardWidgetCard.neededHeight(of: DashboardWidget(kind: kind), width: width, window: window, workspace: workspace,
                                             project: project, graphFeed: feed)
        }
        let padding = 2 * DashboardGridMetrics.padding
        // The title row and the space under it, from a widget whose content is one line.
        let chrome = height(.recentChats) - NSHostingView(rootView: Text("No chats yet.")).fittingSize.height
        #expect(chrome > padding + DashboardWidgetCard.spacing + 10 && chrome < padding + DashboardWidgetCard.spacing + 30)
        let cost = height(.cost)
        #expect(cost > chrome + 40 && cost < chrome + 90)
        #expect(height(.cost) == cost)
        // Narrower, the name of the project wraps onto more lines: the widget needs more height.
        #expect(height(.project, width: 200) > height(.project))
        // Without a graph to show yet, the map and the chart count their height all the same.
        #expect(height(.serviceGraph) == chrome + DashboardGraph.mapHeight)
        #expect(height(.serviceGraph, width: 200) == chrome + DashboardGraph.mapHeight)
        let chart = height(.requestsPerMinute)
        #expect(chart > chrome + DashboardGraph.chartHeight + 30 && chart < chrome + DashboardGraph.chartHeight + 70)
        // The rows of an added widget hold that height at the cell size of the window.
        #expect(metrics.cells(holding: height(.serviceGraph)) == Int(((chrome + DashboardGraph.mapHeight + 16) / 46).rounded(.up)))
    }

    @Test("The content of a widget scrolls in the directions where it cannot be as small as the space under the title row")
    func overflow() {
        let visible = CGSize(width: 200, height: 150)
        #expect(DashboardOverflow.axes(smallest: CGSize(width: 0, height: 100), visible: visible) == [])
        #expect(DashboardOverflow.axes(smallest: CGSize(width: 200, height: 150), visible: visible) == [])
        #expect(DashboardOverflow.axes(smallest: CGSize(width: 0, height: 151), visible: visible) == .vertical)
        #expect(DashboardOverflow.axes(smallest: CGSize(width: 274, height: 68), visible: visible) == .horizontal)
        #expect(DashboardOverflow.axes(smallest: CGSize(width: 274, height: 300), visible: visible) == [.horizontal, .vertical])
    }
}

/// docs/dashboard.md › Instances widget: its columns and the colour of the dot before each STATUS.
@MainActor
@Suite("Instances widget")
struct DashboardInstancesTests {
    func pod(_ status: String, ready: Int = 1, containers: Int = 1) -> PodStatus {
        PodStatus(name: "orders-api-1", phase: "Running", readyContainers: ready, containers: containers, restarts: 0, status: status, age: "5m")
    }

    @Test("The column headers of kubectl get pods -o wide, and Ready as ready containers over containers")
    func columns() {
        #expect(DashboardInstances.headers == ["Name", "Ready", "Status", "Restarts", "Age", "Node"])
        #expect(DashboardInstances.ready(pod("Running", ready: 1, containers: 2)) == "1/2")
        #expect(DashboardInstances.interval == .seconds(10))
        #expect(DashboardInstances.noEnvironmentMessage == "Add an environment in Project Settings.")
        #expect(KubernetesPods.noDeploymentMessage(environment: "staging") == "Environment “staging” has no deployment.")
    }

    @Test("Green when running with every container ready, orange while it starts or stops, red when it fails, grey otherwise")
    func dots() {
        #expect(DashboardInstances.dot(pod("Running")) == .green)
        #expect(DashboardInstances.dot(pod("Running", ready: 2, containers: 2)) == .green)
        #expect(DashboardInstances.dot(pod("Running", ready: 1, containers: 2)) == .orange)
        #expect(DashboardInstances.dot(pod("Running", ready: 0, containers: 1)) == .orange)
        for status in ["Pending", "ContainerCreating", "PodInitializing", "Init:0/2", "Init:1/2", "Init:12/13", "Terminating"] {
            #expect(DashboardInstances.dot(pod(status, ready: 0)) == .orange, "\(status)")
        }
        for status in ["Failed", "Error", "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "OOMKilled",
                       "Evicted", "Init:CrashLoopBackOff", "Init:Error", "Init:ImagePullBackOff", "Init:OOMKilled"] {
            #expect(DashboardInstances.dot(pod(status, ready: 0)) == .red, "\(status)")
        }
        for status in ["Completed", "Succeeded", "Unknown", "NotReady", "SchedulingGated", "ExitCode:2", "Init:ExitCode:3", "Init:/2", "Init:a/2",
                       "Init:1/", "running"] {
            #expect(DashboardInstances.dot(pod(status, ready: 0)) == .gray, "\(status)")
        }
    }

    @Test("The Add Widget menu lists Instances after Cost in a Go service only; the default list has no Instances widget")
    func addable() {
        #expect(DashboardWidgetKind.addable(for: .goService) == [.project, .tickets, .recentChats, .cost, .instances])
        #expect(DashboardWidgetKind.addable(for: .swiftApplication) == [.project, .tickets, .recentChats, .cost])
        #expect(DashboardWidgetKind.addable(for: .none) == [.project, .tickets, .recentChats, .cost])
        #expect(!DashboardWidget.defaultList.contains { $0.kind == .instances })
        #expect(DashboardContent.title(of: DashboardWidget(kind: .instances)) == "Instances")
        #expect(DashboardContent.title(of: DashboardWidget(kind: .instances, title: "Pods")) == "Pods")
    }
}

/// docs/dashboard.md › Edit mode and Settings: the changes of the widget list.
@MainActor
@Suite("Dashboard edits")
struct DashboardEditsTests {
    let list = DashboardWidget.defaultList

    func slot(_ index: Int, in widgets: [DashboardWidget]? = nil) -> DashboardSlot {
        DashboardSlot.slots(of: widgets ?? list)[index]
    }

    /// The rows the content of the default widgets needs: Project 5, Tickets 4, Recent Chats 6 and
    /// Cost 3, so the Dashboard shows Project and Tickets on row 0, Recent Chats under Project and
    /// Cost risen under Tickets.
    var arrangement: DashboardArrangement {
        DashboardArrangement(graphEnabled: false, rows: Dictionary(uniqueKeysWithValues: zip(DashboardSlot.slots(of: list), [5, 4, 6, 3])))
    }

    func cells(_ column: Int, _ row: Int, _ width: Int, _ height: Int) -> DashboardCells {
        DashboardCells(column: column, row: row, width: width, height: height)
    }

    @Test("The arrangement of the default list: two widgets per row, each as high as its content needs, risen")
    func shownCells() {
        #expect(arrangement.cells(of: list) == [cells(0, 0, 12, 5), cells(12, 0, 12, 4), cells(0, 5, 12, 6), cells(12, 4, 12, 3)])
        // A widget whose rows are not known yet counts one row.
        #expect(DashboardArrangement().cells(of: list) == [cells(0, 0, 12, 1), cells(12, 0, 12, 1), cells(0, 1, 12, 1), cells(12, 1, 12, 1)])
    }

    @Test("Add Widget appends the kind at column 0 under every widget, 12 columns wide and as high as its content needs, and stores the shown positions")
    func appending() {
        let id = UUID()
        let added = DashboardEdits.appending(.recentChats, rows: 4, to: list, arrangement: arrangement, id: id)
        #expect(added.count == 5)
        #expect(added.map(\.cells) == [cells(0, 0, 12, 5), cells(12, 0, 12, 4), cells(0, 5, 12, 6), cells(12, 4, 12, 3), cells(0, 11, 12, 4)])
        // The first change stores the positions of the list; the settings and the ids stay.
        var expected = list
        for (index, cell) in arrangement.cells(of: list).enumerated() {
            expected[index].cells = cell
        }
        #expect(Array(added.prefix(4)) == expected)
        #expect(added[4] == DashboardWidget(id: id, kind: .recentChats, column: 0, row: 11, width: 12, height: 4))
        // Added under the lowest widget, it rises under the widget above its columns.
        let twice = DashboardEdits.appending(.cost, rows: 2, to: added, arrangement: arrangement)
        #expect(twice.map(\.kind) == [.project, .tickets, .recentChats, .cost, .recentChats, .cost])
        #expect(twice[5].cells == cells(0, 15, 12, 2))
        #expect(Set(twice.map(\.id)).count == 6)
        let short = [DashboardWidget(kind: .project, column: 0, row: 0, width: 6, height: 2),
                     DashboardWidget(kind: .tickets, column: 12, row: 0, width: 12, height: 9)]
        #expect(DashboardEdits.appending(.cost, rows: 3, to: short, arrangement: DashboardArrangement()).last?.cells == cells(0, 2, 12, 3))
        #expect(DashboardEdits.appending(.cost, rows: 3, to: [], arrangement: DashboardArrangement()).map(\.cells) == [cells(0, 0, 12, 3)])
        #expect(DashboardEdits.appending(.cost, rows: 0, to: [], arrangement: DashboardArrangement()).map(\.cells) == [cells(0, 0, 12, 1)])
    }

    @Test("The remove button removes its widget and the widgets under it rise; a widget no longer in the list changes nothing")
    func removing() throws {
        // Without Tickets, Cost rises from under it to the first row.
        let removed = try #require(DashboardEdits.removing(slot(1), from: list, arrangement: arrangement))
        #expect(removed.map(\.kind) == [.project, .recentChats, .cost])
        #expect(removed.map(\.cells) == [cells(0, 0, 12, 5), cells(0, 5, 12, 6), cells(12, 0, 12, 3)])
        #expect(DashboardEdits.removing(slot(1), from: removed, arrangement: arrangement) == nil)
        let last = try #require(DashboardEdits.removing(slot(3), from: list, arrangement: arrangement))
        #expect(last.map(\.cells) == [cells(0, 0, 12, 5), cells(12, 0, 12, 4), cells(0, 5, 12, 6)])
    }

    @Test("A moved widget lands where the placement rule puts it, the others make room, and every shown widget gets its position")
    func moving() throws {
        // Cost moved to the first cells: Project, which starts on that row, moves down, and Recent
        // Chats under it.
        let moved = try #require(DashboardEdits.placing(slot(3), at: cells(0, 0, 12, 3), in: list, arrangement: arrangement))
        #expect(moved.map(\.kind) == [.project, .tickets, .recentChats, .cost])
        #expect(moved.map(\.cells) == [cells(0, 3, 12, 5), cells(12, 0, 12, 4), cells(0, 8, 12, 6), cells(0, 0, 12, 3)])
        // Released where it was, or where it rises back to its place, a widget changes nothing:
        // the list keeps no position.
        #expect(DashboardEdits.placing(slot(3), at: cells(12, 4, 12, 3), in: list, arrangement: arrangement) == nil)
        #expect(DashboardEdits.placing(slot(3), at: cells(12, 30, 12, 3), in: list, arrangement: arrangement) == nil)
        // The widget stays inside the 24 columns and at row 0 or below.
        #expect(DashboardEdits.placing(slot(0), at: cells(40, -3, 12, 5), in: list, arrangement: arrangement)?.map(\.cells)
            == [cells(12, 0, 12, 5), cells(12, 5, 12, 4), cells(0, 0, 12, 6), cells(12, 9, 12, 3)])
        #expect(DashboardEdits.placing(DashboardSlot(id: UUID(), occurrence: 0), at: cells(0, 0, 12, 3), in: list, arrangement: arrangement) == nil)
        // Moved again from the stored positions.
        let back = try #require(DashboardEdits.placing(slot(3), at: cells(12, 4, 12, 3), in: moved, arrangement: arrangement))
        #expect(back.map(\.cells) == [cells(0, 0, 12, 5), cells(12, 0, 12, 4), cells(0, 5, 12, 6), cells(12, 4, 12, 3)])
    }

    @Test("A resized widget keeps its place, the widgets it now covers move down, and those under it rise when it gets lower")
    func resizing() throws {
        // Project widened over Tickets: Tickets and Cost move down under it.
        let wider = try #require(DashboardEdits.placing(slot(0), at: cells(0, 0, 16, 5), in: list, arrangement: arrangement))
        #expect(wider.map(\.cells) == [cells(0, 0, 16, 5), cells(12, 5, 12, 4), cells(0, 5, 12, 6), cells(12, 9, 12, 3)])
        // Lower, it lets the widgets under it rise.
        let lower = try #require(DashboardEdits.placing(slot(0), at: cells(0, 0, 12, 2), in: list, arrangement: arrangement))
        #expect(lower.map(\.cells) == [cells(0, 0, 12, 2), cells(12, 0, 12, 4), cells(0, 2, 12, 6), cells(12, 4, 12, 3)])
        // Released at the size it had, a widget changes nothing.
        #expect(DashboardEdits.placing(slot(0), at: cells(0, 0, 12, 5), in: list, arrangement: arrangement) == nil)
    }

    @Test("Hidden graph widgets keep their stored positions through a change, and a widget whose rows are not known stays without position")
    func hiddenAndUnmeasured() throws {
        let graph = DashboardWidget(kind: .serviceGraph, column: 0, row: 0, width: 16, height: 8)
        let free = DashboardWidget(kind: .busiestCalls)
        let widgets = [graph, DashboardWidget(kind: .project, column: 0, row: 8, width: 12, height: 4), free,
                       DashboardWidget(kind: .cost, column: 12, row: 8, width: 12, height: 3), DashboardWidget(kind: .tickets)]
        let slots = DashboardSlot.slots(of: widgets)
        let hidden = DashboardArrangement(graphEnabled: false, rows: [:])
        // The graph is not enabled: Project and Cost show risen, and Tickets, whose rows are not
        // known yet, under them with one row.
        #expect(hidden.cells(of: widgets) == [nil, cells(0, 0, 12, 4), nil, cells(12, 0, 12, 3), cells(0, 4, 12, 1)])
        let moved = try #require(DashboardEdits.placing(slots[3], at: cells(0, 0, 12, 3), in: widgets, arrangement: hidden))
        #expect(moved[0] == graph)
        #expect(moved[2] == free)
        #expect(moved[1].cells == cells(0, 3, 12, 4))
        #expect(moved[3].cells == cells(0, 0, 12, 3))
        #expect(moved[4].cells == nil)
        // Once its rows are known, the widget without position gets one too.
        let measured = DashboardArrangement(graphEnabled: false, rows: [slots[4]: 6])
        #expect(DashboardEdits.placing(slots[3], at: cells(0, 0, 12, 3), in: widgets, arrangement: measured)?[4].cells == cells(0, 7, 12, 6))
        // Moved itself, the widget whose rows are not known gets the position the user gave it.
        let placed = try #require(DashboardEdits.placing(slots[4], at: cells(12, 0, 12, 1), in: widgets, arrangement: hidden))
        #expect(placed.map(\.cells) == [cells(0, 0, 16, 8), cells(0, 0, 12, 4), nil, cells(12, 1, 12, 3), cells(12, 0, 12, 1)])
        // A hidden widget cannot be moved.
        #expect(DashboardEdits.placing(slots[0], at: cells(4, 0, 16, 8), in: widgets, arrangement: hidden) == nil)
        // With the graph enabled, the graph widgets show at their stored places.
        let enabled = DashboardArrangement(graphEnabled: true, rows: [slots[2]: 5, slots[4]: 6])
        #expect(enabled.cells(of: widgets) == [cells(0, 0, 16, 8), cells(0, 8, 12, 4), cells(0, 12, 12, 5), cells(12, 8, 12, 3), cells(12, 11, 12, 6)])
    }

    @Test("A settings change applies to its widget only")
    func updating() {
        let updated = DashboardEdits.updating(slot(1), in: list) { $0.includeSubprojects = false }
        #expect(updated?[1].includeSubprojects == false)
        #expect(updated?.enumerated().filter { $0.offset != 1 }.map(\.element) == list.filter { $0.kind != .tickets })
        #expect(DashboardEdits.updating(DashboardSlot(id: UUID(), occurrence: 0), in: list) { $0.title = "X" } == nil)
        // A change of settings stores no position.
        #expect(updated?.allSatisfy { $0.cells == nil } == true)
    }

    @Test("Checkboxes keep the order of the settings, and the last checked box of a group cannot be unchecked")
    func checkboxes() {
        #expect(DashboardEdits.toggling(TicketStatus.done, on: false, in: TicketStatus.allCases) == [.todo, .inProgress, .review])
        #expect(DashboardEdits.toggling(TicketStatus.todo, on: true, in: [.done]) == [.todo, .done])
        #expect(DashboardEdits.toggling(TicketStatus.done, on: false, in: [.done]) == [.done])
        #expect(DashboardEdits.toggling(ChatKind.ticket, on: true, in: []) == [.ticket])
        #expect(DashboardEdits.toggling(DashboardProjectField.name, on: false, in: [.folder, .name, .name]) == [.folder])
        #expect(DashboardEdits.isLastChecked(ChatKind.ticket, in: [.ticket]))
        #expect(DashboardEdits.isLastChecked(ChatKind.ticket, in: [.ticket, .ticket]))
        #expect(!DashboardEdits.isLastChecked(ChatKind.ticket, in: [.ticket, .bundle]))
        #expect(!DashboardEdits.isLastChecked(ChatKind.bundle, in: [.ticket]))
    }

    @Test("Quick clicks each apply: a click flips the newest value, and the stepper steps from the newest number within 1–20")
    func clicksFromNewestValues() {
        let once = DashboardEdits.flipping(TicketStatus.review, in: TicketStatus.allCases)
        #expect(once == [.todo, .inProgress, .done])
        #expect(DashboardEdits.flipping(TicketStatus.review, in: once) == TicketStatus.allCases)
        #expect(DashboardEdits.flipping(ChatKind.ticket, in: [.ticket]) == [.ticket])
        var widget = DashboardWidget(kind: .recentChats)
        widget.chatCount = DashboardEdits.steppingChatCount(of: widget, by: 1)
        widget.chatCount = DashboardEdits.steppingChatCount(of: widget, by: 1)
        #expect(widget.chatCount == 7)
        #expect(DashboardEdits.steppingChatCount(of: DashboardWidget(kind: .recentChats, chatCount: 20), by: 1) == 20)
        #expect(DashboardEdits.steppingChatCount(of: DashboardWidget(kind: .recentChats, chatCount: 1), by: -1) == 1)
        #expect(DashboardEdits.steppingChatCount(of: DashboardWidget(kind: .recentChats, chatCount: 50), by: -1) == 19)
    }

    @Test("Widgets that share an id, which only a hand edit gives, each have their own slot")
    func sharedIDs() throws {
        let id = UUID()
        let widgets = [DashboardWidget(id: id, kind: .cost), DashboardWidget(id: id, kind: .tickets), DashboardWidget(kind: .project)]
        let slots = DashboardSlot.slots(of: widgets)
        #expect(slots.map(\.occurrence) == [0, 1, 0])
        #expect(Set(slots).count == 3)
        #expect(slots[1].index(in: widgets) == 1)
        let shared = DashboardArrangement(graphEnabled: false, rows: Dictionary(uniqueKeysWithValues: zip(slots, [2, 3, 4])))
        #expect(shared.cells(of: widgets) == [cells(0, 0, 12, 2), cells(12, 0, 12, 3), cells(0, 2, 12, 4)])
        #expect(DashboardEdits.removing(slots[1], from: widgets, arrangement: shared)?.map(\.kind) == [.cost, .project])
        // The second widget of the id is the one that moves.
        let moved = DashboardEdits.placing(slots[1], at: cells(0, 0, 12, 3), in: widgets, arrangement: shared)
        #expect(moved?.map(\.kind) == [.cost, .tickets, .project])
        #expect(moved?.map(\.cells) == [cells(0, 3, 12, 2), cells(0, 0, 12, 3), cells(0, 5, 12, 4)])
    }

    /// A stand-in for the workspace: the stored list, and the lists it applies, given to the
    /// subscribers after they are stored.
    @MainActor
    final class Store {
        var stored = DashboardWidget.defaultList
        var subscribers: [AsyncStream<[DashboardWidget]>.Continuation] = []
        var sent: [[DashboardWidget]] = []
        var messages: [String?] = []

        func apply(_ list: [DashboardWidget]) {
            stored = list
            for subscriber in subscribers {
                subscriber.yield(list)
            }
        }

        func lists() -> AsyncStream<[DashboardWidget]> {
            let (stream, continuation) = AsyncStream<[DashboardWidget]>.makeStream(bufferingPolicy: .unbounded)
            subscribers.append(continuation)
            return stream
        }

        func send(_ changes: DashboardChanges, _ edit: @escaping ([DashboardWidget]) -> [DashboardWidget]?,
                  call: @escaping @MainActor ([DashboardWidget]) async throws -> [DashboardWidget]) {
            changes.send(stored: { self.stored }, lists: { self.lists() }, edit: edit, call: call, done: { self.messages.append($0) })
        }

        func finish(_ count: Int) async {
            while messages.count < count {
                await Task.yield()
            }
        }
    }

    @Test("Each change starts from the stored list once the event of the previous change has been applied")
    func sequencedChanges() async throws {
        let store = Store()
        let changes = DashboardChanges(eventTimeout: .seconds(30))
        // The result of each call arrives before its event, which the workspace applies a moment later.
        let call: @MainActor ([DashboardWidget]) async throws -> [DashboardWidget] = { list in
            store.sent.append(list)
            Task { @MainActor in
                store.apply(list)
            }
            return list
        }
        let slots = DashboardSlot.slots(of: store.stored)
        let arrangement = arrangement
        store.send(changes, { DashboardEdits.removing(slots[3], from: $0, arrangement: arrangement) }, call: call)
        store.send(changes, { DashboardEdits.updating(slots[1], in: $0) { $0.includeSubprojects = false } }, call: call)
        store.send(changes, { $0 }, call: call)
        await store.finish(3)
        #expect(store.sent.count == 2)
        #expect(store.sent[1].map(\.kind) == [.project, .tickets, .recentChats])
        #expect(store.sent[1][1].includeSubprojects == false)
        // The change of settings is made from the positions the removal stored.
        #expect(store.sent[1].map(\.cells) == [cells(0, 0, 12, 5), cells(12, 0, 12, 4), cells(0, 5, 12, 6)])
        #expect(store.stored == store.sent[1])
        #expect(store.messages == [nil, nil, nil])
    }

    @Test("A change made just after another device's change starts from it, even when both events came before the result")
    func laterChangeOfAnotherDevice() async throws {
        let store = Store()
        let changes = DashboardChanges(eventTimeout: .seconds(30))
        let other = DashboardWidget(kind: .cost, title: "Spend")
        var first = true
        let call: @MainActor ([DashboardWidget]) async throws -> [DashboardWidget] = { list in
            store.sent.append(list)
            if first {
                first = false
                // This call's event, then another device's write, both applied before the result.
                store.apply(list)
                store.apply(list + [other])
            } else {
                store.apply(list)
            }
            return list
        }
        let slots = DashboardSlot.slots(of: store.stored)
        let arrangement = arrangement
        store.send(changes, { DashboardEdits.removing(slots[0], from: $0, arrangement: arrangement) }, call: call)
        store.send(changes, { DashboardEdits.updating(slots[2], in: $0) { $0.chatCount = 3 } }, call: call)
        await store.finish(2)
        #expect(store.sent.count == 2)
        #expect(store.sent[1].last == other)
        #expect(store.sent[1].first { $0.kind == .recentChats }?.chatCount == 3)
    }

    @Test("A call whose event never comes is waited for at most the timeout; a failed call gives its message")
    func timeoutAndFailure() async throws {
        let store = Store()
        let changes = DashboardChanges(eventTimeout: .milliseconds(50))
        let arrangement = arrangement
        store.send(changes, { DashboardEdits.appending(.cost, rows: 3, to: $0, arrangement: arrangement) }, call: { list in
            store.sent.append(list)
            return list
        })
        store.send(changes, { DashboardEdits.appending(.project, rows: 5, to: $0, arrangement: arrangement) }, call: { _ in
            throw EngineError(.unavailable, "Not connected to Studio.")
        })
        await store.finish(2)
        #expect(store.messages == [nil, "Not connected to Studio."])
        #expect(store.sent.count == 1)
    }
}
