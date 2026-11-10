// OWNER: ui-shell — the detail of a virtual machine in the centre column of a main window
// (docs/virtual-machines.md › Detail; docs/ui.md › Pane headers).
import HephaestusCore
import SwiftUI

/// The detail of a virtual machine of This Mac: a pane header with its name, `macOS <version>`,
/// its state and `Stop` or `Start`, and under it its screen, usable with the mouse and the
/// keyboard, or `Stopped`. It follows `vms.changed`; the window leaves it when the virtual machine
/// leaves the list (`WindowState.leaveVirtualMachineDetail`).
struct VirtualMachineDetailView: View {
    let window: WindowState
    let workspace: DeviceWorkspace
    let vmID: UUID
    @Environment(AppModel.self) private var app
    /// The session of the running virtual machine, from the VM screens service.
    @State private var session: VMSession?
    @State private var acting = false
    @State private var keyboard = GuestKeyboard()

    /// The proportions of a virtual machine's display.
    private static let displayAspectRatio: CGFloat = 2560.0 / 1600.0

    private var machine: VirtualMachine? { workspace.virtualMachine(vmID) }

    /// The password of the guest account of the virtual machine's image
    /// (docs/virtual-machines.md › Guest account).
    private var password: String? {
        guard let machine else { return nil }
        return workspace.vmImages?.first { $0.id == machine.imageID }?.password
    }

    var body: some View {
        VStack(spacing: 0) {
            if let machine {
                header(machine)
                Divider()
                content(machine)
            } else {
                // The list is read, or the virtual machine is gone and the window leaves the detail.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: machine?.startedAt) {
            await loadSession()
        }
        .task {
            if workspace.virtualMachines == nil {
                await workspace.loadVirtualMachines()
            }
            window.leaveVirtualMachineDetail(ifGoneFrom: workspace)
            if workspace.vmImages == nil {
                await workspace.loadVMImages()
            }
        }
    }

    /// The pane header: the name, `macOS <version>`, the state, and `Stop` or `Start`.
    private func header(_ machine: VirtualMachine) -> some View {
        HStack(spacing: 10) {
            Text(machine.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Text(VirtualMachinePresentation.systemText(machine))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VirtualMachineStateText(machine: machine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            TypePasswordButton(keyboard: keyboard, password: password,
                               enabled: machine.state == .running && session?.vmID == vmID) { error in
                window.alert = WindowAlert.failure(GuestKeyboard.title, error)
            }
            if machine.state == .running {
                Button("Stop") {
                    act("Stop") {
                        _ = try await workspace.call(VMsStop.self, VMParams(vmID: vmID))
                    }
                }
                .disabled(acting)
            } else {
                Button("Start") {
                    act("Start") {
                        _ = try await workspace.call(VMsStart.self, VMParams(vmID: vmID))
                    }
                }
                .disabled(acting || !VirtualMachinePresentation.canStart(machine, in: workspace.virtualMachines))
            }
        }
        .padding(.horizontal, 12)
        .paneHeaderBar()
    }

    /// The screen of a running virtual machine, scaled to fit, or `Stopped` in its place.
    @ViewBuilder
    private func content(_ machine: VirtualMachine) -> some View {
        if machine.state == .running {
            ZStack {
                Color.black
                if let session, session.vmID == vmID {
                    VirtualMachineScreen(virtualMachine: session.virtualMachine, keyboard: keyboard)
                        .aspectRatio(Self.displayAspectRatio, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(VirtualMachinePresentation.stoppedText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Takes the session of the virtual machine from the VM screens service each time it starts;
    /// a stopped virtual machine has none.
    private func loadSession() async {
        guard workspace.isLocal, machine?.state == .running else {
            session = nil
            return
        }
        session = await app.engine.virtualMachineSession(vmID)
    }

    /// Runs a button of the header; a failure shows the alert `<title> failed` on the window.
    private func act(_ title: String, _ call: @escaping () async throws -> Void) {
        guard !acting else { return }
        acting = true
        Task {
            do {
                try await call()
            } catch {
                window.alert = WindowAlert.failure(title, error)
            }
            acting = false
        }
    }
}
