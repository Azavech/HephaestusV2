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
