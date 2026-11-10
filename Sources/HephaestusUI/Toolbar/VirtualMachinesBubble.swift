// OWNER: ui-shell — the Virtual Machines bubble of the main toolbar and its popover
// (docs/virtual-machines.md › Virtual Machines bubble; docs/ui.md › Toolbar).
import AppKit
import HephaestusCore
import SwiftUI

/// One row of the popover: a running virtual machine of the user or of Claude, or the setup
/// virtual machine of an image (docs/virtual-machines.md › Popover).
struct VMPopoverRow: Identifiable, Hashable {
    enum Source: Hashable {
        /// A virtual machine of the user or of Claude, by its id.
        case machine(UUID)
        /// The setup virtual machine of an image; `closing` once its window has closed.
        case setup(imageID: UUID, closing: Bool)
    }

    let source: Source
    /// The virtual machine's name, or `Set Up macOS <version>` for a setup virtual machine.
    let name: String
    /// `Started by you`, `<project id> · <chat name>`, or `<project id>` without the chat.
    let startedBy: String
    /// When the virtual machine started: its running time counts from it.
    let startedAt: Date

    var id: String {
        switch source {
        case .machine(let id): return "vm/\(id.uuidString)"
        case .setup(let imageID, _): return "setup/\(imageID.uuidString)"
        }
    }
}

/// A setup virtual machine that the popover lists.
struct VMPopoverSetup: Hashable {
    let imageID: UUID
    /// The macOS version of its image.
    let version: String
    let startedAt: Date
    /// True once its window has closed: the virtual machine still shuts down.
    let closing: Bool
}

/// The number of the bubble and the rows of its popover (docs/virtual-machines.md › Bubble,
/// › Popover).
enum VMPopoverPresentation {
    static let symbol = "display"
    static let tooltip = "Virtual Machines"
    static let emptyText = "No virtual machines running"
    static let startedByUser = "Started by you"
    /// The size of a preview, in points: the proportions of the display of a virtual machine.
    static let previewSize = CGSize(width: 160, height: 100)
    /// A preview is taken again this long after the last one began, while the popover is open.
    static let previewInterval: Duration = .seconds(2)

    /// The number beside the symbol; nil at 0, when the bubble holds the symbol alone.
    static func countText(_ count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

    /// The number of the bubble: the number of rows, without reading the chats of their texts.
    static func count(_ list: VMList?, setups: [VMPopoverSetup]) -> Int {
        (list?.machines.filter { $0.state == .running }.count ?? 0) + setups.count
    }

    /// The rows, the virtual machine that started first at the top: the Running virtual
    /// machines of the user and of Claude in `list`, and the setup virtual machines. The install
    /// of an image runs a virtual machine without a screen: it has no row.
    static func rows(_ list: VMList?, chats: [String: ChatMeta], setups: [VMPopoverSetup]) -> [VMPopoverRow] {
        let machines = (list?.machines ?? []).filter { $0.state == .running }.map { machine in
            VMPopoverRow(source: .machine(machine.id), name: machine.name, startedBy: startedByText(machine, chats: chats),
                         startedAt: machine.startedAt ?? machine.created)
        }
        let setupRows = setups.map { setup in
            VMPopoverRow(source: .setup(imageID: setup.imageID, closing: setup.closing),
                         name: VMImagePresentation.setupTitle(version: setup.version), startedBy: startedByUser,
                         startedAt: setup.startedAt)
        }
        return (machines + setupRows).sorted { ($0.startedAt, $0.name, $0.id) < ($1.startedAt, $1.name, $1.id) }
    }

    /// `Started by you` for a virtual machine of the user; for one that Claude started, the text
    /// of the Started by column of Settings: `<project id> · <chat name>`, or `<project id>` once
    /// its chat no longer exists.
    static func startedByText(_ machine: VirtualMachine, chats: [String: ChatMeta]) -> String {
        switch machine.startedBy {
        case .user: return startedByUser
        case .claude: return VirtualMachinePresentation.startedByText(machine, chats: chats)
        }
    }

    /// The running time of a row at `now`: `<m> min`, or `<h> h <mm> min` from an hour on.
    static func runningTime(_ row: VMPopoverRow, now: Date) -> String {
        VMRunningTime.text(since: row.startedAt, now: max(now, row.startedAt))
    }
}

extension AppModel {
    /// The setup virtual machines that run: those of the open setup windows, and those whose
    /// window closed and that still shut down.
    var popoverSetups: [VMPopoverSetup] {
        let open = imageSetups.values.filter { $0.phase != .ended }.map {
            VMPopoverSetup(imageID: $0.imageID, version: $0.version, startedAt: $0.startedAt, closing: false)
        }
        let closing = closingImageSetups.filter { $0.phase != .ended }.map {
            VMPopoverSetup(imageID: $0.imageID, version: $0.version, startedAt: $0.startedAt, closing: true)
        }
        return open + closing
    }

    /// The setup session of an image that the popover lists.
    func popoverSetupSession(_ imageID: UUID) -> VMSetupSession? {
        imageSetups[imageID] ?? closingImageSetups.first { $0.imageID == imageID }
    }

    /// A click on the preview of a setup virtual machine: its setup window comes to front.
    /// Nothing happens once the window has closed.
    func showImageSetup(_ imageID: UUID) {
        guard imageSetups[imageID] != nil else { return }
        windowOpener?(.imageSetup(imageID))
    }
}

/// The Virtual Machines bubble of a main window that shows This Mac: `display` and the number of
/// virtual machines that run, hidden at 0. A click opens the popover.
struct VirtualMachinesBubble: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    @Environment(AppModel.self) private var app
    @State private var popoverShown = false

    var body: some View {
        let count = VMPopoverPresentation.count(workspace.virtualMachines, setups: app.popoverSetups)
        Button {
            popoverShown = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: VMPopoverPresentation.symbol)
                if let text = VMPopoverPresentation.countText(count) {
                    Text(text)
                        .monospacedDigit()
                }
            }
        }
        .help(VMPopoverPresentation.tooltip)
        .accessibilityLabel(VMPopoverPresentation.tooltip)
        .accessibilityValue(String(count))
        .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
            VirtualMachinesPopover(window: window, workspace: workspace) {
                popoverShown = false
            }
            .environment(app)
        }
        // The workspace follows `vms.changed` once it holds the virtual machines.
        .task(id: workspace.deviceID) {
            if workspace.virtualMachines == nil {
                await workspace.loadVirtualMachines()
            }
        }
    }
}

/// The popover: one row per virtual machine that the bubble counts, or `No virtual machines
/// running`.
private struct VirtualMachinesPopover: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let close: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let rows = VMPopoverPresentation.rows(workspace.virtualMachines, chats: workspace.chats, setups: app.popoverSetups)
        Group {
            if rows.isEmpty {
                Text(VMPopoverPresentation.emptyText)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        VMPopoverRowView(row: row, window: window, workspace: workspace, close: close)
                    }
                }
                .padding(12)
            }
        }
        .fixedSize()
    }
}

/// A row: the preview, the name, the Started by line, the running time and `Stop`.
private struct VMPopoverRowView: View {
    let row: VMPopoverRow
    let window: WindowState
    let workspace: DeviceWorkspace
    let close: () -> Void
    @Environment(AppModel.self) private var app
    /// The session of a virtual machine of the user or of Claude, from the VM screens service.
    @State private var machineSession: VMSession?
    /// True from a click on `Stop` until `vms.stop` returns.
    @State private var stopping = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                VMPreview(source: previewSource)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.name)
                Text(row.startedBy)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.startedBy)
                TimelineView(.periodic(from: row.startedAt, by: 60)) { context in
                    Text(VMPopoverPresentation.runningTime(row, now: context.date))
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .frame(width: 200, alignment: .leading)
            Button("Stop", action: stop)
                .disabled(stopDisabled)
        }
        // The session of a virtual machine that starts again is a new one.
        .task(id: row.startedAt) {
            guard case .machine(let vmID) = row.source, workspace.isLocal else { return }
            machineSession = await app.engine.virtualMachineSession(vmID)
        }
    }

    private var previewSource: VMPreviewSource {
        switch row.source {
        case .machine:
            return machineSession.map(VMPreviewSource.machine) ?? .none
        case .setup(let imageID, _):
            return app.popoverSetupSession(imageID).map(VMPreviewSource.setup) ?? .none
        }
    }

    /// `Stop` is disabled while the virtual machine shuts down, whoever asked for the stop.
    private var stopDisabled: Bool {
        switch row.source {
        case .machine:
            guard let phase = machineSession?.phase else { return stopping }
            return stopping || phase == .stopping || phase == .ended
        case .setup(let imageID, let closing):
            return closing || app.popoverSetupSession(imageID)?.isShuttingDown ?? true
        }
    }

    /// Closes the popover and shows the virtual machine: the detail of the user's or Claude's in
    /// this window, the setup window of a setup virtual machine. A setup virtual machine whose
    /// window has closed has nothing to show.
    private func open() {
        switch row.source {
        case .machine(let vmID):
            close()
            Task {
                await window.navigate(to: .virtualMachine(vmID: vmID))
            }
        case .setup(let imageID, let closing):
            guard !closing else { return }
            close()
            app.showImageSetup(imageID)
        }
    }

    /// Stops the virtual machine without confirmation; a failure shows `Stop failed` on the window.
    private func stop() {
        switch row.source {
        case .machine(let vmID):
            stopping = true
            Task {
                do {
                    _ = try await workspace.call(VMsStop.self, VMParams(vmID: vmID))
                } catch {
                    window.alert = WindowAlert.failure("Stop", error)
                }
                stopping = false
            }
        case .setup(let imageID, _):
            app.stopImageSetup(imageID)
        }
    }
}

/// What a preview takes its screenshots from.
@MainActor
private enum VMPreviewSource {
    case machine(VMSession)
    case setup(VMSetupSession)
    /// The session is not known yet.
    case none

    var id: ObjectIdentifier? {
        switch self {
        case .machine(let session): return ObjectIdentifier(session)
        case .setup(let session): return ObjectIdentifier(session)
        case .none: return nil
        }
    }

    var agentConnected: Bool {
        switch self {
        case .machine(let session): return session.agent != nil
        case .setup(let session): return session.agent != nil
        case .none: return false
        }
    }

    func capturePreview() async -> Data? {
        switch self {
        case .machine(let session): return await session.capturePreview()
        case .setup(let session): return await session.capturePreview()
        case .none: return nil
        }
    }
}

/// A preview: the last screenshot of the screen, scaled to fit on black, taken when the popover
/// opens and every 2 seconds while it is open; black while the agent is not connected and until
/// the first screenshot. A failed screenshot leaves the image that shows.
private struct VMPreview: View {
    let source: VMPreviewSource
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image, source.agentConnected {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: VMPopoverPresentation.previewSize.width, height: VMPopoverPresentation.previewSize.height)
        .contentShape(Rectangle())
        .task(id: source.id) {
            await refresh()
        }
    }

    /// Runs while the popover shows the preview: the popover's content exists only while it is
    /// open, so no screenshot is taken while it is closed.
    private func refresh() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let next = clock.now.advanced(by: VMPopoverPresentation.previewInterval)
            if !source.agentConnected {
                image = nil
            } else if let png = await source.capturePreview(), let captured = NSImage(data: png) {
                image = captured
            }
            try? await Task.sleep(until: next, clock: clock)
        }
    }
}
