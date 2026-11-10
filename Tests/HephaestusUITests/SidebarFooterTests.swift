import AppKit
import HephaestusCore
import SwiftUI
import Testing
@testable import HephaestusUI

/// docs/ui.md › Sidebar: the footer's line, with the identifier at its left end and the pop-up of
/// the current working environment at its right end, its right edge at the trailing padding; on a
/// line too narrow for both, the identifier stays whole and the pop-up shrinks.
@MainActor
@Suite("Sidebar footer")
struct SidebarFooterTests {
    /// The height of the hosted sidebar; the footer is its last line.
    static let height: CGFloat = 400
    /// A name that no sidebar width holds next to an 8-letter identifier.
    static let longName = "production-europe-west-3-blue-green-canary-cluster"

    /// The frames of the footer's parts in the hosted sidebar, from its top-left corner.
    struct Frames: PreferenceKey {
        static let defaultValue: [SidebarFooterAnchors.Part: CGRect] = [:]

        static func reduce(value: inout [SidebarFooterAnchors.Part: CGRect], nextValue: () -> [SidebarFooterAnchors.Part: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    /// Records the frames of the shown footer.
    final class Recorded {
        var frames: [SidebarFooterAnchors.Part: CGRect] = [:]
    }

    /// Lays out the sidebar of a project with these environments, `width` points wide, in a
    /// window, and returns the frames of its footer's parts.
    func footer(id: String = "YC", type: ProjectType = .goService, environments names: [String], width: CGFloat) async throws
        -> [SidebarFooterAnchors.Part: CGRect] {
        // The AppKit views of the sidebar need the application.
        _ = NSApplication.shared
        let environments = names.map { ProjectEnvironment(name: $0) }
        let project = ProjectSummary(id: id, name: "Service", type: type, rootPath: "/Users/example/service")
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        workspace.projects = [project]
        workspace.details[id] = ProjectDetail(
            project: Project(id: id, name: "Service", created: Date(), type: type, environments: environments),
            rootPath: "/Users/example/service", environments: environments, currentEnvironment: names.first)
        let state = WindowState(id: UUID(), deviceID: "device")
        state.projectID = id
        let recorded = Recorded()
        let host = NSHostingView(rootView: SidebarView(window: state, workspace: workspace, project: project)
            .frame(width: width, height: Self.height)
            .overlayPreferenceValue(SidebarFooterAnchors.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.preference(key: Frames.self, value: anchors.mapValues { proxy[$0] })
                }
            }
            .onPreferenceChange(Frames.self) { recorded.frames = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: Self.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        // The bound only ends a test that fails.
        let deadline = ContinuousClock.now + .seconds(60)
        while recorded.frames[.identifier] == nil, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        return recorded.frames
    }

    @Test("The pop-up is on the identifier's line, its right edge 12 points from the sidebar's right edge at every width",
          arguments: [190, 200, 280] as [CGFloat])
    func popUpAtRightEnd(_ width: CGFloat) async throws {
        let frames = try await footer(environments: ["production", "staging"], width: width)
        let identifier = try #require(frames[.identifier])
        let popUp = try #require(frames[.popUp])
        // One line 30 points high, the last of the sidebar, with both parts centred on it.
        #expect(abs(identifier.midY - (Self.height - 15)) <= 1)
        #expect(abs(popUp.midY - (Self.height - 15)) <= 1)
        #expect(abs(identifier.minX - 12) <= 0.5)
        #expect(abs(popUp.maxX - (width - 12)) <= 0.5)
        #expect(popUp.minX >= identifier.maxX)
    }

    @Test("On a line too narrow for both, the identifier stays whole and the pop-up shrinks below the width its title needs")
    func narrowLine() async throws {
        let alone = try #require(try await footer(id: "LONGNAME", environments: [], width: 190)[.identifier])
        // Wide enough for both: the pop-up has the width its title needs.
        let fitting = try #require(try await footer(id: "LONGNAME", environments: [Self.longName], width: 600)[.popUp])
        #expect(abs(fitting.maxX - 588) <= 0.5)
        var widths: [CGFloat] = []
        for width in [190, 200, 280] as [CGFloat] {
            let frames = try await footer(id: "LONGNAME", environments: [Self.longName], width: width)
            let identifier = try #require(frames[.identifier])
            let popUp = try #require(frames[.popUp])
            #expect(abs(identifier.minX - alone.minX) <= 0.5 && abs(identifier.width - alone.width) <= 0.5, "width \(width)")
            #expect(abs(popUp.maxX - (width - 12)) <= 0.5, "width \(width)")
            #expect(popUp.minX >= identifier.maxX, "width \(width)")
            #expect(popUp.width < fitting.width, "width \(width)")
            #expect(abs(popUp.midY - (Self.height - 15)) <= 1, "width \(width)")
            widths.append(popUp.width)
        }
        #expect(widths == widths.sorted() && Set(widths).count == widths.count)
    }

    @Test("A Go service without environments and a project of another type show the identifier alone on the line",
          arguments: ProjectType.allCases)
    func identifierAlone(_ type: ProjectType) async throws {
        // A project of another type keeps the environments of its `project.yml` and shows none.
        let frames = try await footer(type: type, environments: type == .goService ? [] : ["local"], width: 200)
        let identifier = try #require(frames[.identifier])
        #expect(frames[.popUp] == nil)
        #expect(abs(identifier.minX - 12) <= 0.5)
        #expect(abs(identifier.midY - (Self.height - 15)) <= 1)
    }
}
