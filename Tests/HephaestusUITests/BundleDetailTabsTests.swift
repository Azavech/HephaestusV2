import AppKit
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/tickets.md › Bundles section: at every width of the bundle detail, from its 300 pt minimum,
/// the detail stays inside its pane; each segment of its tabs is as wide as its label, and the tabs
/// narrow to the detail's width when the three segments do not fit it.
@MainActor
@Suite("Bundle detail tabs")
struct BundleDetailTabsTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)

    /// DEMO with its bundle DEMO-B1: `tickets` tickets, `chats` bundle chats and `mentions` project
    /// chats that mention the bundle, which give the labels `Tickets (<tickets>)`, `Chats (<chats>)`
    /// and `Mentioned In (<mentions>)`.
    static func workspace(tickets: Int, chats: Int = 0, mentions: Int = 0) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.projects = [ProjectSummary(id: "DEMO", name: "Demo", rootPath: "/Users/example/Demo")]
        let ticketIDs = (0..<tickets).map { "DEMO-\($0 + 1)" }
        workspace.tickets["DEMO"] = Dictionary(uniqueKeysWithValues: ticketIDs.map { ($0, Ticket(id: $0, title: "Ticket \($0)", created: created)) })
        var chatIDs: [ChatID] = []
        for index in 0..<chats {
            let meta = ChatMeta(id: UUID(), kind: .bundle, bundleID: "DEMO-B1", created: created.addingTimeInterval(Double(index)),
                                projectID: "DEMO")
            workspace.chats[meta.id.uuidString] = meta
            chatIDs.append(meta.id)
        }
        for index in 0..<mentions {
            let meta = ChatMeta(id: UUID(), kind: .project, created: created.addingTimeInterval(Double(index)), projectID: "DEMO",
                                mentionedIDs: ["DEMO-B1"])
            workspace.chats[meta.id.uuidString] = meta
        }
        workspace.bundles["DEMO"] = ["DEMO-B1": TicketBundle(id: "DEMO-B1", title: "Bundle", created: created, ticketIDs: ticketIDs,
                                                             chatIDs: chatIDs)]
        return workspace
    }

    /// A main window state that shows DEMO.
    static func windowState() -> WindowState {
        let window = WindowState(deviceID: "device")
        window.activate(projectID: "DEMO")
        return window
    }

    /// The detail of DEMO-B1, hosted `width` points wide in a window that is never shown.
    @MainActor
    final class HostedDetail {
        let host: NSView
        let window: NSWindow

        init(window state: WindowState, workspace: DeviceWorkspace, width: CGFloat) {
            // The AppKit views of the detail need the application.
            _ = NSApplication.shared
            host = NSHostingView(rootView: BundleDetailView(window: state, workspace: workspace, projectID: "DEMO", bundleID: "DEMO-B1")
                .frame(width: width, height: 700))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }

        /// The segmented control of the tabs, once the detail is laid out.
        var tabs: NSSegmentedControl? {
            host.layoutSubtreeIfNeeded()
            return Self.segmentedControl(in: host)
        }

        /// The frame of the tabs in the detail, from the detail's left edge.
        func frame(of tabs: NSSegmentedControl) -> NSRect {
            tabs.convert(tabs.bounds, to: host)
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

        private static func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl {
                return control
            }
            return view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
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

    @Test("Laid out at 300 pt, the detail is no wider than 300 pt and its tabs stay inside it",
          arguments: [[16, 12, 5], [1000, 1000, 1000]])
    func minimumWidth(counts: [Int]) async throws {
        let workspace = Self.workspace(tickets: counts[0], chats: counts[1], mentions: counts[2])
        defer { workspace.close() }
        let window = Self.windowState()
        // The width the detail takes when its pane offers 300 pt.
        let detail = BundleDetailView(window: window, workspace: workspace, projectID: "DEMO", bundleID: "DEMO-B1")
        #expect(NSHostingController(rootView: detail).sizeThatFits(in: NSSize(width: 300, height: 700)).width <= 300)

        let hosted = HostedDetail(window: window, workspace: workspace, width: 300)
        defer { hosted.close() }
        try await hosted.settle { hosted.tabs.map { hosted.frame(of: $0).maxX <= 300 } ?? false }
        let tabs = try #require(hosted.tabs)
        let labels = ["Tickets (\(counts[0]))", "Chats (\(counts[1]))", "Mentioned In (\(counts[2]))"]
        #expect(Self.labels(of: tabs) == labels)
        let frame = hosted.frame(of: tabs)
        #expect(frame.minX >= 0 && frame.maxX <= 300, "\(frame)")
        // The tabs are never wider than their segments, each as wide as its label.
        let fitted = labels.map(Self.fittedWidth).reduce(0, +)
        #expect(frame.width < fitted + 1, "\(frame.width) \(fitted)")
        if counts[0] == 1000 {
            // These three segments do not fit the detail: the tabs take the width it leaves them,
            // where the control narrows its segments and ends the labels that do not fit with an
            // ellipsis.
            #expect(fitted > 300)
            #expect(frame.width < fitted - 1)
        }
    }

    @Test("In a detail wide enough, each segment is as wide as its label, not as wide as the widest label")
    func fittedSegments() async throws {
        let workspace = Self.workspace(tickets: 16, chats: 12, mentions: 5)
        defer { workspace.close() }
        let hosted = HostedDetail(window: Self.windowState(), workspace: workspace, width: 600)
        defer { hosted.close() }
        let widths = ["Tickets (16)", "Chats (12)", "Mentioned In (5)"].map(Self.fittedWidth)
        let fitted = widths.reduce(0, +)
        try await hosted.settle { hosted.tabs.map { abs(hosted.frame(of: $0).width - fitted) < 1 } ?? false }
        let tabs = try #require(hosted.tabs)
        let frame = hosted.frame(of: tabs)
        #expect(abs(frame.width - fitted) < 1, "\(frame.width) \(fitted)")
        #expect(frame.width < 3 * (widths.max() ?? 0))
        // The tabs are centred in the detail.
        #expect(abs(frame.midX - 300) < 1)
    }

    @Test("The tabs follow the counts: a label that changes gives its segment its new width")
    func labelChange() async throws {
        let workspace = Self.workspace(tickets: 9)
        defer { workspace.close() }
        let hosted = HostedDetail(window: Self.windowState(), workspace: workspace, width: 600)
        defer { hosted.close() }
        let before = ["Tickets (9)", "Chats (0)", "Mentioned In (0)"]
        try await hosted.settle { hosted.tabs.map(Self.labels) == before }
        #expect(hosted.tabs.map(Self.labels) == before)

        workspace.tickets["DEMO"]?["DEMO-10"] = Ticket(id: "DEMO-10", title: "Ticket DEMO-10", created: Self.created)
        workspace.bundles["DEMO"]?["DEMO-B1"]?.ticketIDs.append("DEMO-10")
        let after = ["Tickets (10)", "Chats (0)", "Mentioned In (0)"]
        let fitted = after.map(Self.fittedWidth).reduce(0, +)
        #expect(fitted > before.map(Self.fittedWidth).reduce(0, +))
        try await hosted.settle {
            hosted.tabs.map { Self.labels(of: $0) == after && abs(hosted.frame(of: $0).width - fitted) < 1 } ?? false
        }
        let tabs = try #require(hosted.tabs)
        #expect(Self.labels(of: tabs) == after)
        #expect(abs(hosted.frame(of: tabs).width - fitted) < 1, "\(hosted.frame(of: tabs).width) \(fitted)")
    }

    @Test("The selected segment is the window's bundle tab, and choosing a segment shows its tab")
    func selection() async throws {
        let workspace = Self.workspace(tickets: 3)
        defer { workspace.close() }
        let window = Self.windowState()
        let hosted = HostedDetail(window: window, workspace: workspace, width: 600)
        defer { hosted.close() }
        try await hosted.settle { hosted.tabs?.selectedSegment == 0 }
        let tabs = try #require(hosted.tabs)
        #expect(tabs.selectedSegment == 0)

        // A click on a segment selects it, then sends the control's action.
        tabs.selectedSegment = 1
        #expect(tabs.sendAction(tabs.action, to: tabs.target))
        #expect(window.viewState.bundleTab == .chats)
        tabs.selectedSegment = 2
        #expect(tabs.sendAction(tabs.action, to: tabs.target))
        #expect(window.viewState.bundleTab == .mentionedIn)

        // A tab chosen elsewhere, for example by a navigation, selects its segment.
        window.updateViewState(of: "DEMO") { $0.bundleTab = .tickets }
        try await hosted.settle { hosted.tabs?.selectedSegment == 0 }
        #expect(hosted.tabs?.selectedSegment == 0)
    }
}
