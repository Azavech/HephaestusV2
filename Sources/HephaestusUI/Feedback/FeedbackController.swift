// OWNER: ui-skills-feedback — starting feedback: capture, the receiving device, the default project
// lookup, the context and Send (docs/feedback.md › Flow, › Starting feedback, › Feedback project,
// › Feedback context, › Creating the feedback chat).
import AppKit
import Foundation
import HephaestusCore
import SwiftUI

/// The window whose feedback is started.
enum FeedbackSource {
    /// A main window: its device receives the feedback.
    case main(WindowState)
    /// A chat window: the chat's device receives the feedback.
    case chat(ChatWindowValue)
    /// Settings, About or another window: This Mac receives the feedback.
    case other
}

/// What a capture gathered for its Feedback sheet, from the captured window at capture time.
struct FeedbackCapture {
    /// The device whose engine creates the feedback chat (docs/feedback.md › Starting feedback).
    let receivingDeviceID: String
    /// docs/feedback.md › Feedback context.
    let context: FeedbackContext
}

/// Starts feedback for a window: captures it with `WindowCapture` (owned by ui-shell), keeps the
/// PNG in `AppModel.feedbackPreviews`, then shows the Feedback sheet on that window
/// (`WindowSheet.feedback` on a main window). A start while a capture is running is ignored.
@MainActor
final class FeedbackController {
    weak var app: AppModel?
    /// True while a window is being rendered.
    private(set) var isCapturing = false
    /// The captures of the open Feedback sheets, by preview id.
    private var captures: [UUID: FeedbackCapture] = [:]
    /// The Feedback sheets attached to windows other than main windows, by preview id.
    private var hostedSheets: [UUID: (sheet: NSWindow, parent: NSWindow)] = [:]

    init() {}

    /// The ladybug of a status bar, or Help ▸ Send Feedback… (⇧⌘B) for the key window.
    func start(capturing window: NSWindow?, source: FeedbackSource) {
        // A window that shows a sheet, or is itself a sheet (the key window while a sheet is
        // shown), does not start feedback; nor does a start while a capture is running.
        guard let app, !isCapturing, let window, window.attachedSheet == nil, window.sheetParent == nil else { return }
        if case .main(let state) = source, state.sheet != nil { return }
        // A receiving device that hides its HephaestusV2 project takes no feedback.
        guard !FeedbackProject.hidesFeedback(app.workspaces[FeedbackProject.receivingDeviceID(of: source, app: app)]) else { return }
        let capture = makeCapture(for: source, app: app)
        isCapturing = true
        Task {
            // The sheet opens only after the capture finishes, so it is never in the screenshot.
            let image = try? await WindowCapture.capture(window)
            isCapturing = false
            let previewID = UUID()
            if let image {
                app.feedbackPreviews[previewID] = image.png
            }
            captures[previewID] = capture
            present(previewID, source: source, on: window, app: app)
        }
    }

    /// The capture of an open Feedback sheet.
    func capture(for previewID: UUID) -> FeedbackCapture? {
        captures[previewID]
    }

    /// The sheet closed: its screenshot and capture are dropped.
    func finish(_ previewID: UUID) {
        captures[previewID] = nil
        app?.feedbackPreviews[previewID] = nil
    }

    // MARK: Presenting the sheet

    /// The sheet is attached to the captured window: `WindowSheet.feedback` on a main window, an
    /// AppKit sheet hosting `FeedbackSheet` on any other window.
    private func present(_ previewID: UUID, source: FeedbackSource, on window: NSWindow, app: AppModel) {
        guard window.isVisible, window.attachedSheet == nil else {
            finish(previewID)
            return
        }
        if case .main(let state) = source {
            guard state.sheet == nil else {
                finish(previewID)
                return
            }
            state.sheet = .feedback(previewID: previewID)
            return
        }
        let content = FeedbackSheet(previewID: previewID, source: source) { [weak self] in
            self?.closeHostedSheet(previewID)
        }
        .environment(app)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = .preferredContentSize
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled],
                            backing: .buffered, defer: true)
        sheet.hidesOnDeactivate = false
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = controller
        hostedSheets[previewID] = (sheet, window)
        window.beginSheet(sheet) { [weak self] _ in
            self?.hostedSheetEnded(previewID)
        }
    }

    private func closeHostedSheet(_ previewID: UUID) {
        guard let entry = hostedSheets[previewID] else { return }
        entry.parent.endSheet(entry.sheet)
    }

    private func hostedSheetEnded(_ previewID: UUID) {
        if let entry = hostedSheets.removeValue(forKey: previewID) {
            entry.sheet.orderOut(nil)
        }
        finish(previewID)
    }

    // MARK: Showing the feedback chat (docs/feedback.md › Feedback sheet; docs/ui.md › Choosing the window)

    /// The main window that shows a new feedback chat: the captured main window; otherwise the most
    /// recently key main window showing the receiving device; nil when a new main window opens on
    /// that device.
    static func mainWindow(for source: FeedbackSource, receivingDeviceID: String,
                           mainWindowsByKeyOrder: [WindowState]) -> WindowState? {
        if case .main(let captured) = source, captured.deviceID == receivingDeviceID,
           mainWindowsByKeyOrder.contains(where: { $0.id == captured.id }) {
            return captured
        }
        return mainWindowsByKeyOrder.first { $0.deviceID == receivingDeviceID }
    }

    /// Send succeeded: the chosen main window, ordered front and made key, navigates to the chat
    /// (`chat{chatID}` target); no chat window opens and the window the feedback came from stays
    /// open. Returns once the window's state is updated or the target is pending.
    func showChat(_ meta: ChatMeta, in workspace: DeviceWorkspace, source: FeedbackSource) async {
        guard let app else { return }
        // The returned metadata resolves the chat's project when `chat.updated` has not arrived yet.
        if workspace.chats[meta.id.uuidString] == nil {
            workspace.chats[meta.id.uuidString] = meta
        }
        let target = NavigationTarget.chat(chatID: meta.id)
        guard let state = Self.mainWindow(for: source, receivingDeviceID: workspace.deviceID,
                                          mainWindowsByKeyOrder: app.mainWindowsByKeyOrder) else {
            let state = WindowState(deviceID: workspace.deviceID)
            state.needsDefaultProject = true
            state.pendingTarget = target
            app.openMainWindow(state)
            return
        }
        app.windowRegistry.window(forMain: state.id)?.makeKeyAndOrderFront(nil)
        await state.navigate(to: target)
    }

    // MARK: Context (docs/feedback.md › Feedback context)

    private func makeCapture(for source: FeedbackSource, app: AppModel) -> FeedbackCapture {
        let capturingDevice = app.localWorkspace.deviceName
        func context(receiving deviceID: String) -> FeedbackContext {
            FeedbackContext(appVersion: app.appVersion.version, build: app.appVersion.build, deviceName: capturingDevice,
                            mainDeviceName: app.deviceName(deviceID))
        }
        switch source {
        case .main(let state):
            var result = context(receiving: state.deviceID)
            if let projectID = state.projectID {
                result.projectID = projectID
                // No section and no item while the Global Memories view shows (docs/feedback.md ›
                // Feedback context).
                result.section = state.shownSection
                if let workspace = app.workspaces[state.deviceID] {
                    result.item = Self.selectedItem(of: state, in: workspace, projectID: projectID)
                }
            }
            return FeedbackCapture(receivingDeviceID: state.deviceID, context: result)
        case .chat(let value):
            var result = context(receiving: value.deviceID)
            if let meta = app.workspaces[value.deviceID]?.chats[value.chatID] {
                result.projectID = meta.projectID
                result.item = meta.title
            }
            // A chat window counts as the `chats` section of its project.
            result.section = .chats
            return FeedbackCapture(receivingDeviceID: value.deviceID, context: result)
        case .other:
            return FeedbackCapture(receivingDeviceID: app.localDeviceID, context: context(receiving: app.localDeviceID))
        }
    }

    /// The selected item of a main window's section; nil when nothing is selected.
    static func selectedItem(of state: WindowState, in workspace: DeviceWorkspace, projectID: String) -> String? {
        let view = state.projectStates[ProjectKey(deviceID: workspace.deviceID, projectID: projectID)] ?? ProjectViewState()
        guard let section = state.shownSection else { return nil }
        switch section {
        case .tickets:
            let projects = TicketListProjects(projectID: projectID, workspace: workspace)
            return firstTicketInListOrder(view.selectedTicketIDs, tickets: projects.tickets(in: workspace),
                                          list: view.ticketList, projects: projects)
        case .bundles:
            return view.selectedBundleID
        case .chats:
            return ChatsSectionView.inListOrder(view.selectedChatIDs.compactMap { workspace.chats[$0] }).first?.title
        case .code:
            guard let path = view.selectedEditorPath else { return nil }
            guard let tab = view.editorTabs.first(where: { $0.path == path }) else { return path }
            return "\(path):\(cursorLine(of: tab.buffer))"
        case .docs:
            return view.selectedDocPath
        case .web:
            guard let tabID = view.selectedWebTabID else { return nil }
            return workspace.webTabs[projectID]?.first { $0.id.uuidString == tabID.uppercased() }?.url
        case .skills:
            return view.selectedSkillName
        case .memories:
            return MemoryActions.selectedItemName(of: view, in: workspace, projectID: projectID)
        case .dashboard, .costs, .apiExplorer, .settings:
            return nil
        }
    }

    /// The 1-based line of the cursor (the start of the selection) of an editor buffer.
    static func cursorLine(of buffer: EditorBuffer) -> Int {
        let text = buffer.text as NSString
        let location = min(max(buffer.selection.location, 0), text.length)
        var line = 1
        var index = 0
        while index < location {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: location - index))
            guard found.location != NSNotFound else { break }
            line += 1
            index = found.location + 1
        }
        return line
    }

    /// The first selected ticket in the ticket list's order (docs/tickets.md › Ticket list);
    /// selected tickets the workspace does not hold come after, by number, as the list starts.
    static func firstTicketInListOrder(_ ids: Set<String>, tickets: [String: Ticket], list: TicketListState,
                                       projects: TicketListProjects) -> String? {
        guard !ids.isEmpty else { return nil }
        if let first = list.sorted(ids.compactMap { tickets[$0] }, projects: projects).first {
            return first.id
        }
        let number = { (id: String) in Identifiers.parseTicketID(id)?.number ?? 0 }
        return ids.sorted { list.sortAscending ? number($0) < number($1) : number($0) > number($1) }.first
    }

    // MARK: The context line of the sheet

    /// The App, Device, Project, Section and Item lines of the feedback message without their
    /// leading `- `, joined with ` · ` (docs/chats.md › Feedback message).
    static func contextLine(_ context: FeedbackContext, projectName: String?) -> String {
        var parts = ["App: HephaestusV2 v\(context.appVersion)(\(context.build))"]
        if context.deviceName == context.mainDeviceName {
            parts.append("Device: \(context.deviceName)")
        } else {
            parts.append("Device: \(context.deviceName), connected to \(context.mainDeviceName)")
        }
        if let projectID = context.projectID {
            parts.append("Project: \(projectName ?? projectID) (\(projectID))")
        }
        if let section = context.section {
            parts.append("Section: \(section.rawValue)")
        }
        if let item = context.item {
            parts.append("Item: \(item)")
        }
        return parts.joined(separator: " · ")
    }
}
