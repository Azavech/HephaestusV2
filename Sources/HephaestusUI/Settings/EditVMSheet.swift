// OWNER: ui-shell — the Edit VM sheet of Settings > Virtual Machines and of the Virtual Machines
// popover (docs/ui.md › Virtual Machines; docs/virtual-machines.md › Editing).
import HephaestusCore
import SwiftUI

/// Edit VM: the name, the cores, the memory and the disk size of a stopped virtual machine, filled
/// with its values. `Save` calls `vms.update`, which grows the disk when it is larger; any failure
/// shows under the fields and the sheet stays open. On a main window the virtual machines may not
/// be read yet: the sheet reads them, and it closes when its virtual machine leaves the list.
struct EditVMSheet: View {
    let vmID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var name = ""
    @State private var cores = ""
    @State private var memory = ""
    @State private var disk = ""
    /// True once the fields hold the virtual machine's values.
    @State private var filled = false
    @State private var message: String?
    @State private var saving = false

    private var list: VMList? { app.localWorkspace.virtualMachines }
    private var machine: VirtualMachine? { list?.machines.first { $0.id == vmID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit VM")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .frame(width: 220)
                }
                numberRow("Cores", text: $cores)
                numberRow("Memory (GB)", text: $memory)
                numberRow("Disk (GB)", text: $disk)
            }
            .disabled(saving || !filled)
            FieldMessage(text: message)
            SheetButtonRow(defaultTitle: "Save",
                           defaultEnabled: filled && VirtualMachinePresentation.canSave(name: name) && !saving,
                           cancel: { dismiss() }, confirm: save)
        }
        .padding(20)
        .frame(width: 380)
        .task {
            if list == nil {
                await app.localWorkspace.loadVirtualMachines()
            }
            fill()
        }
        .onChange(of: list?.machines.map(\.id)) { _, _ in
            fill()
        }
    }

    /// Fills the fields once with the virtual machine's values; a sheet whose virtual machine is not
    /// in the list closes.
    private func fill() {
        guard list != nil else { return }
        guard let machine else {
            dismiss()
            return
        }
        guard !filled else { return }
        name = machine.name
        cores = String(machine.cores)
        memory = String(machine.memoryGB)
        disk = String(VirtualMachinePresentation.currentDiskGB(machine, images: app.localWorkspace.vmImages))
        filled = true
    }

    private func numberRow(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
            TextField(label, text: text)
                .labelsHidden()
                .frame(width: 80)
        }
    }

    /// The whole number of a field, or nil with the engine's message for a value outside the range
    /// of its param.
    private func value(_ text: String, _ param: String, _ range: ClosedRange<Int>) -> Int? {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
        message = VMImageLimits.message(param, range)
        return nil
    }

    private func save() {
        guard let machine, !saving else { return }
        let limits = VMImageLimits.host
        let currentDiskGB = VirtualMachinePresentation.currentDiskGB(machine, images: app.localWorkspace.vmImages)
        guard let coresValue = value(cores, "cores", limits.cores),
              let memoryValue = value(memory, "memoryGB", limits.memoryGB),
              let diskValue = value(disk, "diskGB", limits.diskGB(imageDiskGB: currentDiskGB)) else { return }
        message = nil
        saving = true
        Task {
            do {
                _ = try await app.localWorkspace.call(VMsUpdate.self, VMsUpdate.Params(
                    vmID: vmID, name: name, cores: coresValue, memoryGB: memoryValue, diskGB: diskValue))
                dismiss()
            } catch {
                message = errorMessage(error)
            }
            saving = false
        }
    }
}
