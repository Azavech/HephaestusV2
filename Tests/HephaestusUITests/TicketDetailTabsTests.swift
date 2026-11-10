import AppKit
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Ticket detail: at every width of the detail, from its 300 pt minimum, the
/// detail stays inside its pane; each segment of its tabs is as wide as its label, and the tabs
/// narrow to the detail's width when the three segments do not fit it.
@MainActor
@Suite("Ticket detail tabs")
struct TicketDetailTabsTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let title = "A ticket whose title is much longer than its detail is wide at the minimum width"

    /// DEMO with its ticket DEMO-1, `chats` chats of the ticket and `mentions` project chats that
    /// mention it, which give the labels `Chats (<chats>)` and `Mentioned In (<mentions>)`.
    static func workspace(chats: Int = 0, mentions: Int = 0) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.projects = [ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo")]
        var chatIDs: [ChatID] = []
        for index in 0..<chats {
            let meta = ChatMeta(id: UUID(), kind: .ticket, ticketID: "DEMO-1", created: created.addingTimeInterval(Double(index)),
                                projectID: "DEMO")
            workspace.chats[meta.id.uuidString] = meta
            chatIDs.append(meta.id)
        }
        for index in 0..<mentions {
            addMention(to: workspace, minutes: index)
        }
        workspace.tickets["DEMO"] = ["DEMO-1": Ticket(id: "DEMO-1", title: title, created: created, chatIDs: chatIDs)]
        return workspace
    }

    /// A project chat that mentions DEMO-1.
    static func addMention(to workspace: DeviceWorkspace, minutes: Int) {
        let meta = ChatMeta(id: UUID(), kind: .project, created: created.addingTimeInterval(Double(minutes) * 60), projectID: "DEMO",
                            mentionedIDs: ["DEMO-1"])
        workspace.chats[meta.id.uuidString] = meta
    }

    /// A main window state that shows DEMO.
    static func windowState() -> WindowState {
        let window = WindowState(deviceID: "device")
        window.activate(projectID: "DEMO")
        return window
    }

    /// The detail of DEMO-1 as the Tickets section shows it: right of a list at its minimum width
    /// and of the divider, `width` points wide, hosted in a window that is never shown.
    @MainActor
    final class HostedDetail {
        let host: NSView
        let window: NSWindow
        /// The detail's pane, from the left edge of the list.
        let pane: ClosedRange<CGFloat>

        init(window state: WindowState, workspace: DeviceWorkspace, width: CGFloat) {
            // The AppKit views of the detail need the application.
            _ = NSApplication.shared
            let list = ListDetailSplit<Color, TicketDetailView>.minListWidth
            let total = list + 1 + width
            pane = (list + 1)...total
            let split = ListDetailSplit(listWidth: .constant(list)) {
                Color.clear
            } detail: {
                TicketDetailView(window: state, workspace: workspace, projectID: "DEMO", ticketID: "DEMO-1")
            }
            host = NSHostingView(rootView: split.frame(width: total, height: 700))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: total, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }

        /// The segmented control of the tabs, once the detail is laid out.
        var tabs: NSSegmentedControl? {
            host.layoutSubtreeIfNeeded()
            return controls.lazy.compactMap { $0 as? NSSegmentedControl }.first
        }

        /// The AppKit controls of the detail, the tabs and the title field among them.
        var controls: [NSControl] {
            Self.controls(in: host)
        }

        /// The frame of a control, from the left edge of the list.
        func frame(of control: NSControl) -> NSRect {
            control.convert(control.bounds, to: host)
        }

        /// Whether a control is inside the detail's pane, between its left and right edges.
        func isInsidePane(_ control: NSControl) -> Bool {
            let frame = frame(of: control)
            return frame.minX >= pane.lowerBound && frame.maxX <= pane.upperBound
        }

        /// Lays the detail out until `condition` holds; the bound only ends a test that fails.
        func settle(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func close() {
            window.close()
        }

        private static func controls(in view: NSView) -> [NSControl] {
            (view as? NSControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
    }

    /// The width of a segment that is as wide as its label: the width of a control with that label
    /// alone.
    static func fittedWidth(_ label: String) -> CGFloat {
        let control = NSSegmentedControl(labels: [label], trackingMode: .selectOne, target: nil, action: nil)
        control.segmentDistribution = .fit
        return control.intrinsicContentSize.width
    }

    static func labels(of tabs: NSSegmentedControl) -> [String] {
        (0..<tabs.segmentCount).map { tabs.label(forSegment: $0) ?? "" }
    }

    @Test("Laid out at 300 pt, the detail is no wider than 300 pt, and its tabs, narrower than their labels, and its title field stay inside it")
    func minimumWidth() async throws {
        let workspace = Self.workspace(chats: 12, mentions: 5)
        let window = Self.windowState()
        // The width the detail takes when its pane offers 300 pt.
        let detail = TicketDetailView(window: window, workspace: workspace, projectID: "DEMO", ticketID: "DEMO-1")
        #expect(NSHostingController(rootView: detail).sizeThatFits(in: NSSize(width: 300, height: 700)).width <= 300)

        let hosted = HostedDetail(window: window, workspace: workspace, width: ListDetailSplit<Color, TicketDetailView>.minDetailWidth)
        #expect(hosted.pane == 241...541)
        try await hosted.settle { hosted.tabs.map(hosted.isInsidePane) ?? false }
        let tabs = try #require(hosted.tabs)
        #expect(Self.labels(of: tabs) == ["Details", "Chats (12)", "Mentioned In (5)"])
        #expect(hosted.isInsidePane(tabs), "\(hosted.frame(of: tabs))")
        // The three segments do not fit: the tabs take the width the detail leaves them, and the
        // control ends the labels that do not fit with an ellipsis.
        let fitted = Self.labels(of: tabs).map(Self.fittedWidth).reduce(0, +)
        #expect(hosted.frame(of: tabs).width < fitted)
        // The title field and the other AppKit controls of the detail are not cut at its edges,
        // and none lies over the list or the divider.
        let controls = hosted.controls
        #expect(controls.contains { $0 is TitleNSTextField })
        for control in controls {
            #expect(hosted.isInsidePane(control), "\(type(of: control)) \(hosted.frame(of: control))")
        }
        hosted.close()
        workspace.close()
    }

    @Test("In a detail wide enough, each segment is as wide as its label, not as wide as the widest label")
    func fittedSegments() async throws {
        let workspace = Self.workspace(chats: 12, mentions: 5)
        let hosted = HostedDetail(window: Self.windowState(), workspace: workspace, width: 600)
        let widths = ["Details", "Chats (12)", "Mentioned In (5)"].map(Self.fittedWidth)
        let fitted = widths.reduce(0, +)
        try await hosted.settle { hosted.tabs.map { abs(hosted.frame(of: $0).width - fitted) < 1 } ?? false }
        let tabs = try #require(hosted.tabs)
        let frame = hosted.frame(of: tabs)
        #expect(abs(frame.width - fitted) < 1, "\(frame.width) \(fitted)")
        #expect(frame.width < 3 * (widths.max() ?? 0))
        // The tabs are centred in the detail.
        #expect(abs(frame.midX - (hosted.pane.lowerBound + 300)) < 1)
        hosted.close()
        workspace.close()
    }

    @Test("The tabs follow the counts: a label that changes gives its segment its new width")
    func labelChange() async throws {
        let workspace = Self.workspace(mentions: 9)
        let hosted = HostedDetail(window: Self.windowState(), workspace: workspace, width: 600)
        let before = ["Details", "Chats (0)", "Mentioned In (9)"]
        try await hosted.settle { hosted.tabs.map(Self.labels) == before }
        #expect(hosted.tabs.map(Self.labels) == before)

        Self.addMention(to: workspace, minutes: 9)
        let after = ["Details", "Chats (0)", "Mentioned In (10)"]
        let fitted = after.map(Self.fittedWidth).reduce(0, +)
        #expect(fitted > before.map(Self.fittedWidth).reduce(0, +))
        try await hosted.settle {
            hosted.tabs.map { Self.labels(of: $0) == after && abs(hosted.frame(of: $0).width - fitted) < 1 } ?? false
        }
        let tabs = try #require(hosted.tabs)
        #expect(Self.labels(of: tabs) == after)
        #expect(abs(hosted.frame(of: tabs).width - fitted) < 1, "\(hosted.frame(of: tabs).width) \(fitted)")
        hosted.close()
        workspace.close()
    }

    @Test("The selected segment is the window's ticket tab, and choosing a segment shows its tab")
    func selection() async throws {
        let workspace = Self.workspace()
        let window = Self.windowState()
        let hosted = HostedDetail(window: window, workspace: workspace, width: 600)
        try await hosted.settle { hosted.tabs?.selectedSegment == 0 }
        let tabs = try #require(hosted.tabs)
        #expect(tabs.selectedSegment == 0)

        // A click on a segment selects it, then sends the control's action.
        tabs.selectedSegment = 1
        #expect(tabs.sendAction(tabs.action, to: tabs.target))
        #expect(window.viewState.ticketTab == .chats)
        tabs.selectedSegment = 2
        #expect(tabs.sendAction(tabs.action, to: tabs.target))
        #expect(window.viewState.ticketTab == .mentionedIn)

        // A tab chosen elsewhere, for example by a navigation, selects its segment.
        window.updateViewState(of: "DEMO") { $0.ticketTab = .details }
        try await hosted.settle { hosted.tabs?.selectedSegment == 0 }
        #expect(hosted.tabs?.selectedSegment == 0)
        hosted.close()
        workspace.close()
    }
}
