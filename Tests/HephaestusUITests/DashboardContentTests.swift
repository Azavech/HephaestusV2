import Foundation
import HephaestusCore
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

/// docs/dashboard.md › Edit mode and Settings: the changes of the widget list.
@MainActor
@Suite("Dashboard edits")
struct DashboardEditsTests {
    let list = DashboardWidget.defaultList

    func slot(_ index: Int, in widgets: [DashboardWidget]? = nil) -> DashboardSlot {
        DashboardSlot.slots(of: widgets ?? list)[index]
    }

    @Test("Add Widget appends the kind with its default settings and a new id; a kind can be added any number of times")
    func appending() {
        let id = UUID()
        let added = DashboardEdits.appending(.recentChats, to: list, id: id)
        #expect(added.count == 5)
        #expect(Array(added.prefix(4)) == list)
        #expect(added[4] == DashboardWidget(id: id, kind: .recentChats))
        let twice = DashboardEdits.appending(.recentChats, to: added)
        #expect(twice.map(\.kind) == [.project, .tickets, .recentChats, .cost, .recentChats, .recentChats])
        #expect(Set(twice.map(\.id)).count == 6)
        #expect(DashboardEdits.appending(.cost, to: []).map(\.kind) == [.cost])
    }

    @Test("The remove button removes its widget; a widget no longer in the list changes nothing")
    func removing() throws {
        let removed = try #require(DashboardEdits.removing(slot(3), from: list))
        #expect(removed.map(\.kind) == [.project, .tickets, .recentChats])
        #expect(DashboardEdits.removing(slot(3), from: removed) == nil)
    }

    @Test("A widget dropped on another takes its place; the widgets between them move by one place")
    func moving() {
        #expect(DashboardEdits.moving(slot(0), onto: slot(2), in: list)?.map(\.kind) == [.tickets, .recentChats, .project, .cost])
        #expect(DashboardEdits.moving(slot(3), onto: slot(1), in: list)?.map(\.kind) == [.project, .cost, .tickets, .recentChats])
        #expect(DashboardEdits.moving(slot(1), onto: slot(2), in: list)?.map(\.kind) == [.project, .recentChats, .tickets, .cost])
        #expect(DashboardEdits.moving(slot(1), onto: slot(1), in: list) == nil)
        #expect(DashboardEdits.moving(DashboardSlot(id: UUID(), occurrence: 0), onto: slot(1), in: list) == nil)
    }

    @Test("A settings change applies to its widget only")
    func updating() {
        let updated = DashboardEdits.updating(slot(1), in: list) { $0.includeSubprojects = false }
        #expect(updated?[1].includeSubprojects == false)
        #expect(updated?.enumerated().filter { $0.offset != 1 }.map(\.element) == list.filter { $0.kind != .tickets })
        #expect(DashboardEdits.updating(DashboardSlot(id: UUID(), occurrence: 0), in: list) { $0.title = "X" } == nil)
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
        #expect(DashboardEdits.removing(slots[1], from: widgets)?.map(\.kind) == [.cost, .project])
        #expect(DashboardEdits.moving(slots[2], onto: slots[0], in: widgets)?.map(\.kind) == [.project, .cost, .tickets])
    }

    @Test("A drop moves only a widget dragged from the same Dashboard")
    func dragPayload() {
        let slot = slot(2)
        let token = UUID()
        let payload = DashboardDrag.payload(token: token, slot: slot)
        #expect(DashboardDrag.slot(from: payload, token: token) == slot)
        #expect(DashboardDrag.slot(from: payload, token: UUID()) == nil)
        #expect(DashboardDrag.slot(from: "Some dragged text", token: token) == nil)
        #expect(DashboardDrag.slot(from: DashboardDrag.prefix + token.uuidString, token: token) == nil)
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
        store.send(changes, { DashboardEdits.removing(slots[3], from: $0) }, call: call)
        store.send(changes, { DashboardEdits.updating(slots[1], in: $0) { $0.includeSubprojects = false } }, call: call)
        store.send(changes, { $0 }, call: call)
        await store.finish(3)
        #expect(store.sent.count == 2)
        #expect(store.sent[1].map(\.kind) == [.project, .tickets, .recentChats])
        #expect(store.sent[1][1].includeSubprojects == false)
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
        store.send(changes, { DashboardEdits.removing(slots[0], from: $0) }, call: call)
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
        store.send(changes, { DashboardEdits.appending(.cost, to: $0) }, call: { list in
            store.sent.append(list)
            return list
        })
        store.send(changes, { DashboardEdits.appending(.project, to: $0) }, call: { _ in
            throw EngineError(.unavailable, "Not connected to Studio.")
        })
        await store.finish(2)
        #expect(store.messages == [nil, "Not connected to Studio."])
        #expect(store.sent.count == 1)
    }
}
