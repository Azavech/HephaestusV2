// OWNER: ui-shell — the setup window of a virtual machine image (docs/virtual-machines.md › Setup
// window; docs/ui.md › Windows).
import AppKit
import HephaestusCore
import SwiftUI
import Virtualization

/// The setup window of an image: the screen of its setup virtual machine, the three steps, the
/// agent's status and `Finish Setup`. It closes when the virtual machine has stopped, after the
/// alert of a setup that failed; closing it before `Finish Setup` shuts the virtual machine down.
struct ImageSetupWindow: View {
    let imageID: UUID
    @Environment(AppModel.self) private var app
    @State private var hostWindow = HostWindow()
    @State private var endHandled = false

    var body: some View {
        Group {
            if let session = app.imageSetups[imageID] {
                ImageSetupView(session: session)
                    .navigationTitle(VMImagePresentation.setupTitle(version: session.version))
                    // `initial`: a setup that ended before the window showed closes it too.
                    .onChange(of: session.phase, initial: true) { _, phase in
                        if phase == .ended {
                            sessionEnded(session)
                        }
                    }
            } else {
                // No setup runs for this image: the window has nothing to show. It closes once its
                // root view is in it.
                Color.clear
                    .onAppear {
                        DispatchQueue.main.async {
                            hostWindow.window?.close()
                        }
                    }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .readsHostWindow(hostWindow)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window === hostWindow.window {
                app.imageSetupWindowClosed(imageID)
            }
        }
        .onDisappear {
            app.imageSetupWindowClosed(imageID)
        }
    }

    /// The virtual machine has stopped: the window closes, after the failure alert of
    /// docs/ui.md › Principles when a failure ended the setup.
    private func sessionEnded(_ session: VMSetupSession) {
        guard !endHandled else { return }
        endHandled = true
        guard let failure = session.failure else {
            // Once the root view is in the window, for a setup that ended before it showed.
            DispatchQueue.main.async {
                hostWindow.window?.close()
            }
            return
        }
        Task {
            await VMImagePresentation.showFailure(VMImagePresentation.failureTitle(of: session), failure, on: hostWindow.window)
            hostWindow.window?.close()
        }
    }
}

/// The content of the setup window.
struct ImageSetupView: View {
    let session: VMSetupSession

    /// The proportions of the setup virtual machine's display.
    private static let displayAspectRatio: CGFloat = 2560.0 / 1600.0

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                VirtualMachineScreen(virtualMachine: session.virtualMachine)
                    .aspectRatio(Self.displayAspectRatio, contentMode: .fit)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
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

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.virtualMachine = virtualMachine
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
    }
}
