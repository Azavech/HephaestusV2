// OWNER: ui-shell — the setup view of a virtual machine image in the centre column of a main
// window (docs/virtual-machines.md › Setup view; docs/ui.md › Pane headers).
import AppKit
import HephaestusCore
import SwiftUI
import Virtualization

/// The setup view of an image: a pane header with `Set Up macOS <version>`, its running time and
/// `Stop`, and under it the screen of its setup virtual machine, the three steps, the agent's
/// status and `Finish Setup`. The setup runs whether the view shows or not; the window leaves the
/// view when the setup ends (`AppModel.imageSetupEnded`).
struct ImageSetupView: View {
    let window: WindowState
    let imageID: UUID
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if let session = app.imageSetups[imageID] {
                header(session)
                Divider()
                ImageSetupContent(window: window, session: session)
            } else {
                // The setup has ended: the window leaves the view, after the alert of a failure.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // `Type Password` needs the image's password (docs/virtual-machines.md › Type Password).
            if app.localWorkspace.vmImages == nil {
                await app.localWorkspace.loadVMImages()
            }
        }
    }

    /// The pane header: `Set Up macOS <version>`, `Running · <time>` and `Stop`.
    private func header(_ session: VMSetupSession) -> some View {
        HStack(spacing: 10) {
            Text(VMImagePresentation.setupTitle(version: session.version))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: session.startedAt, by: 60)) { context in
                Text(VMImagePresentation.setupRunningText(since: session.startedAt, now: context.date))
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Stop") {
                app.stopImageSetup(imageID)
            }
            .disabled(session.isShuttingDown)
        }
        .padding(.horizontal, 12)
        .paneHeaderBar()
    }
}

/// The setup view in a window without a project, which takes the welcome view's place, and on
/// its right, while the workspace holds one, the image's newest Auto Setup chat without a project,
/// in a column of the inspector's width with its title in a pane header (docs/ui.md › Welcome
/// view).
struct ImageSetupWithChat: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let imageID: UUID
    @Environment(AppModel.self) private var app

    /// The newest Auto Setup chat of the image that belongs to no project.
    static func setupChat(of imageID: UUID, in chats: [String: ChatMeta]) -> ChatMeta? {
        chats.values.filter { $0.kind == .setup && $0.projectID.isEmpty && $0.imageID == imageID }
            .max { $0.created != $1.created ? $0.created < $1.created : $0.id.uuidString < $1.id.uuidString }
    }

    var body: some View {
        if let chat = Self.setupChat(of: imageID, in: workspace.chats) {
            HSplitView {
                ImageSetupView(window: window, imageID: imageID)
                    .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                chatColumn(chat)
                    .frame(minWidth: PaneWidthMemory.minimumInspectorWidth, idealWidth: CGFloat(window.inspectorWidth), maxWidth: 600,
                           maxHeight: .infinity)
            }
        } else {
            ImageSetupView(window: window, imageID: imageID)
        }
    }

    private func chatColumn(_ chat: ChatMeta) -> some View {
        let linked = LinkedItems.linked(state: ProjectViewState(), section: nil, tickets: [:], bundles: [:], chats: [:], webTabs: [],
                                        imageSetupID: imageID, setupVersions: app.imageSetupVersions)
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                ChatStateMark(state: chat.state)
                    .frame(width: 12)
                Text(chat.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .paneHeaderBar()
            Divider()
            ChatView(chatID: chat.id.uuidString, workspace: workspace, showsHeader: false, isInInspector: true, linkedItems: linked)
        }
        .background(FrostedPaneBackground())
    }
}

/// The screen of the setup virtual machine and, on its right, the column of the three steps.
struct ImageSetupContent: View {
    let window: WindowState
    let session: VMSetupSession
    @Environment(AppModel.self) private var app
    @State private var keyboard = GuestKeyboard()

    /// The password of the image's guest account (docs/virtual-machines.md › Guest account).
    private var password: String? {
        app.localWorkspace.vmImages?.first { $0.id == session.imageID }?.password
    }

    /// The proportions of the setup virtual machine's display.
    private static let displayAspectRatio: CGFloat = 2560.0 / 1600.0

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                VirtualMachineScreen(virtualMachine: session.virtualMachine, keyboard: keyboard)
                    .aspectRatio(Self.displayAspectRatio, contentMode: .fit)
            }
            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            steps
                .padding(16)
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(1) {
                Text("Complete Setup Assistant: create an account and turn on automatic login.")
            }
            step(2) {
                Text("Turn off SIP:")
                Button("Restart in Recovery") {
                    Task {
                        await session.restartInRecovery()
                    }
                }
                .disabled(!session.canRestartInRecovery)
                Text("In Recovery, open Utilities ▸ Terminal, run csrutil disable, then restart.")
            }
            step(3) {
                Text("Install the agent: in Terminal, run")
                Text(GuestTools.installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                CopyButton { GuestTools.installCommand }
            }
            TypePasswordButton(keyboard: keyboard, password: password) { error in
                window.alert = WindowAlert.failure(GuestKeyboard.title, error)
            }
            Spacer(minLength: 0)
            Text(VMImagePresentation.agentStatusText(session.agent))
                .foregroundStyle(session.agent == nil ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Finish Setup") {
                    Task {
                        await session.finish()
                    }
                }
                .disabled(!session.canFinish)
            }
        }
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The screen of a virtual machine, usable with the mouse and the keyboard: the framework's
/// `VZVirtualMachineView`.
struct VirtualMachineScreen: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?
    /// The keyboard of `Type Password`, which presses its keys through this view.
    var keyboard: GuestKeyboard?

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.virtualMachine = virtualMachine
        keyboard?.view = view
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
        if let keyboard, keyboard.view !== view {
            keyboard.view = view
        }
    }
}
