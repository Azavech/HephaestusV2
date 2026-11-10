// OWNER: ui-shell — the Virtual Machines bubble of the main toolbar and its popover
// (docs/virtual-machines.md › Virtual Machines bubble; docs/ui.md › Toolbar).
import AppKit
import HephaestusCore
import SwiftUI

/// One row of the popover: a virtual machine of the user or of Claude, Running or Stopped, or the
/// setup virtual machine of an image (docs/virtual-machines.md › Popover).
struct VMPopoverRow: Identifiable, Hashable {
    enum Source: Hashable {
        /// A virtual machine of the user or of Claude, by its id.
        case machine(UUID)
        /// The setup virtual machine of an image, by the image's id.
        case setup(imageID: UUID)
    }

    let source: Source
    /// The virtual machine's name, or `Set Up macOS <version>` for a setup virtual machine.
    let name: String
    /// `Started by you`, `<project id> · <chat name>`, or `<project id>` without the chat.
    let startedBy: String
    /// When the virtual machine started: its running time counts from it. Nil while it is Stopped.
    let startedAt: Date?

    var isStopped: Bool { startedAt == nil }

    var id: String {
        switch source {
        case .machine(let id): return "vm/\(id.uuidString)"
        case .setup(let imageID): return "setup/\(imageID.uuidString)"
        }
    }
}

/// A setup virtual machine that the popover lists.
struct VMPopoverSetup: Hashable {
    let imageID: UUID
    /// The macOS version of its image.
    let version: String
    let startedAt: Date
}

/// The number of the bubble and the rows of its popover (docs/virtual-machines.md › Bubble,
/// › Popover).
enum VMPopoverPresentation {
    static let symbol = "display"
    static let tooltip = "Virtual Machines"
    static let emptyText = "No virtual machines"
    static let newVMTitle = "New VM…"
    static let addImageTitle = "Add Image…"
    static let settingsTitle = "Virtual Machines Settings…"
    static let startedByUser = "Started by you"
    /// The size of a preview, in points: the proportions of the display of a virtual machine.
    static let previewSize = CGSize(width: 160, height: 100)
    /// A preview is taken again this long after the last one began, while the popover is open.
    static let previewInterval: Duration = .seconds(2)

    /// The number beside the symbol; nil at 0, when the bubble holds the symbol alone.
    static func countText(_ count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

    /// The number of the bubble: the Running virtual machines and the setup virtual machines.
    static func count(_ list: VMList?, setups: [VMPopoverSetup]) -> Int {
        (list?.machines.filter { $0.state == .running }.count ?? 0) + setups.count
    }

    /// The rows: first the Running virtual machines of the user and of Claude in `list` and the
    /// setup virtual machines, the one that started first at the top, then the Stopped virtual
    /// machines, the oldest created first. The install of an image runs a virtual machine without
    /// a screen: it has no row.
    static func rows(_ list: VMList?, chats: [String: ChatMeta], setups: [VMPopoverSetup]) -> [VMPopoverRow] {
        let machines = list?.machines ?? []
        let running = machines.filter { $0.state == .running }.map { machine in
            (row: VMPopoverRow(source: .machine(machine.id), name: machine.name,
                               startedBy: startedByText(machine, chats: chats), startedAt: machine.startedAt ?? machine.created),
             date: machine.startedAt ?? machine.created)
        }
        let setupRows = setups.map { setup in
            (row: VMPopoverRow(source: .setup(imageID: setup.imageID),
                               name: VMImagePresentation.setupTitle(version: setup.version), startedBy: startedByUser,
                               startedAt: setup.startedAt),
             date: setup.startedAt)
        }
        let stopped = machines.filter { $0.state == .stopped }.map { machine in
            (row: VMPopoverRow(source: .machine(machine.id), name: machine.name,
                               startedBy: startedByText(machine, chats: chats), startedAt: nil),
             date: machine.created)
        }
        func sorted(_ rows: [(row: VMPopoverRow, date: Date)]) -> [VMPopoverRow] {
            rows.sorted { ($0.date, $0.row.name, $0.row.id) < ($1.date, $1.row.name, $1.row.id) }.map(\.row)
        }
        return sorted(running + setupRows) + sorted(stopped)
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

    /// The running time of a row at `now`: `<m> min`, or `<h> h <mm> min` from an hour on;
    /// `Stopped` for a Stopped virtual machine.
    static func runningTime(_ row: VMPopoverRow, now: Date) -> String {
        guard let startedAt = row.startedAt else { return VirtualMachinePresentation.stoppedText }
        return VMRunningTime.text(since: startedAt, now: max(now, startedAt))
    }

    /// `Start` of a Stopped row is disabled while 2 virtual machines run, as in Settings.
    static func canStart(_ list: VMList?) -> Bool {
        VirtualMachinePresentation.canCreate(list)
    }
}

extension AppModel {
    /// The setup virtual machines that run, until they have stopped, whether a window shows their
    /// setup view or not.
    var popoverSetups: [VMPopoverSetup] {
        imageSetups.values.filter { $0.phase != .ended }.map {
            VMPopoverSetup(imageID: $0.imageID, version: $0.version, startedAt: $0.startedAt)
        }
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

/// The popover: one row per virtual machine of This Mac and per setup virtual machine, or `No
/// virtual machines`, then the row of buttons.
private struct VirtualMachinesPopover: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let close: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let rows = VMPopoverPresentation.rows(workspace.virtualMachines, chats: workspace.chats, setups: app.popoverSetups)
        // One column: each cell gets the column's width, so the buttons span the widest row.
        Grid(alignment: .leading, verticalSpacing: 12) {
            if rows.isEmpty {
                GridRow {
                    Text(VMPopoverPresentation.emptyText)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(rows) { row in
                    GridRow {
                        VMPopoverRowView(row: row, window: window, workspace: workspace, close: close)
                    }
                }
            }
            GridRow {
                HStack(spacing: 8) {
                    Button(VMPopoverPresentation.newVMTitle) {
                        close()
                        window.sheet = .newVM
                    }
                    .disabled(!VirtualMachinePresentation.canCreate(workspace.virtualMachines))
                    Button(VMPopoverPresentation.addImageTitle) {
                        close()
                        window.sheet = .addImage
                    }
                    Spacer(minLength: 16)
                    Button(VMPopoverPresentation.settingsTitle) {
                        close()
                        app.openSettings(tab: .virtualMachines)
                    }
                }
            }
        }
        .padding(12)
        .fixedSize()
    }
}

/// A row: the preview, the name, the Started by line, the running time and `Stop`; for a Stopped
/// virtual machine a black preview, `Stopped`, `Edit…` and `Start`.
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
    /// True from a click on `Start` until `vms.start` returns.
    @State private var starting = false

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
                Group {
                    if let startedAt = row.startedAt {
                        TimelineView(.periodic(from: startedAt, by: 60)) { context in
                            Text(VMPopoverPresentation.runningTime(row, now: context.date))
                        }
                    } else {
                        Text(VMPopoverPresentation.runningTime(row, now: Date()))
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .frame(width: 200, alignment: .leading)
            if row.isStopped {
                Button(VirtualMachinePresentation.editTitle, action: edit)
                    .disabled(starting)
                Button("Start", action: start)
                    .disabled(starting || !VMPopoverPresentation.canStart(workspace.virtualMachines))
            } else {
                Button("Stop", action: stop)
                    .disabled(stopDisabled)
            }
        }
        // The session of a virtual machine that starts again is a new one; a Stopped one has none,
        // and its preview is never captured.
        .task(id: row.startedAt) {
            guard case .machine(let vmID) = row.source, !row.isStopped, workspace.isLocal else {
                machineSession = nil
                return
            }
            machineSession = await app.engine.virtualMachineSession(vmID)
        }
    }

    private var previewSource: VMPreviewSource {
        switch row.source {
        case .machine:
            guard !row.isStopped else { return .none }
            return machineSession.map(VMPreviewSource.machine) ?? .none
        case .setup(let imageID):
            return app.imageSetups[imageID].map(VMPreviewSource.setup) ?? .none
        }
    }

    /// `Stop` is disabled while the virtual machine shuts down, whoever asked for the stop.
    private var stopDisabled: Bool {
        switch row.source {
        case .machine:
            guard let phase = machineSession?.phase else { return stopping }
            return stopping || phase == .stopping || phase == .ended
        case .setup(let imageID):
            return app.imageSetups[imageID]?.isShuttingDown ?? true
        }
    }

    /// Closes the popover and shows the virtual machine in this window: the detail of the user's
    /// or Claude's, the setup view of a setup virtual machine. A setup virtual machine that shuts
    /// down has nothing to show.
    private func open() {
        switch row.source {
        case .machine(let vmID):
            close()
            Task {
                await window.navigate(to: .virtualMachine(vmID: vmID))
            }
        case .setup(let imageID):
            guard let session = app.imageSetups[imageID], !session.isShuttingDown else { return }
            close()
            app.showImageSetup(imageID, in: window)
        }
    }

    /// Closes the popover and opens the Edit VM sheet of a Stopped virtual machine on this window.
    private func edit() {
        guard case .machine(let vmID) = row.source else { return }
        close()
        window.sheet = .editVM(vmID: vmID)
    }

    /// Starts a Stopped virtual machine with `vms.start`; a failure shows `Start failed` on the
    /// window.
    private func start() {
        guard case .machine(let vmID) = row.source else { return }
        starting = true
        Task {
            do {
                _ = try await workspace.call(VMsStart.self, VMParams(vmID: vmID))
            } catch {
                window.alert = WindowAlert.failure("Start", error)
            }
            starting = false
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
        case .setup(let imageID):
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
