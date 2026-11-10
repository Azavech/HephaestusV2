// OWNER: ui-shell — the New VM sheet of Settings > Virtual Machines (docs/ui.md › Virtual Machines;
// docs/virtual-machines.md › Creating).
import HephaestusCore
import SwiftUI

/// New VM: the name, the Ready image and the values of a virtual machine. `Start` calls
/// `vms.create`, which clones the image's disk and boots the virtual machine. A value the engine
/// refuses shows under the fields; any other failure is a failed start, which closes the sheet and
/// goes to `startFailed`, the red line under the table.
struct NewVMSheet: View {
    let startFailed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var name = ""
    @State private var imageID: UUID?
    @State private var cores = ""
    @State private var memory = ""
    @State private var message: String?
    @State private var starting = false

    /// The Ready images, oldest first.
    private var images: [VMImage] {
        (app.localWorkspace.vmImages ?? []).filter { $0.state == .ready }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New VM")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .frame(width: 220)
                }
                GridRow {
                    Text("Image")
                    Picker("Image", selection: $imageID) {
                        ForEach(images) { image in
                            Text(VMImagePresentation.versionText(image))
                                .tag(Optional(image.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(images.isEmpty)
                }
                numberRow("Cores", text: $cores)
                numberRow("Memory (GB)", text: $memory)
            }
            .disabled(starting)
            FieldMessage(text: message)
            SheetButtonRow(defaultTitle: "Start", defaultEnabled: VirtualMachinePresentation.canSubmit(name: name, imageID: imageID) && !starting,
                           cancel: { dismiss() }, confirm: start)
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            select(VirtualMachinePresentation.initialImage(images, defaultImageID: app.localWorkspace.settings?.defaultVMImage))
        }
        .onChange(of: imageID) { _, id in
            select(images.first { $0.id == id })
        }
    }

    private func numberRow(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
            TextField(label, text: text)
                .labelsHidden()
                .frame(width: 80)
        }
    }

    /// Selects an image and fills Cores and Memory with its values.
    private func select(_ image: VMImage?) {
        guard let image else { return }
        if imageID != image.id {
            imageID = image.id
        }
        cores = String(image.cores)
        memory = String(image.memoryGB)
    }

    /// The whole number of a field, or nil with the engine's message for a value outside the range
    /// of its param.
    private func value(_ text: String, _ param: String, _ range: ClosedRange<Int>) -> Int? {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
        message = VMImageLimits.message(param, range)
        return nil
    }

    private func start() {
        guard let imageID, !starting else { return }
        let limits = VMImageLimits.host
        guard let coresValue = value(cores, "cores", limits.cores),
              let memoryValue = value(memory, "memoryGB", limits.memoryGB) else { return }
        message = nil
        starting = true
        Task {
            do {
                _ = try await app.localWorkspace.call(VMsCreate.self, VMsCreate.Params(
                    name: name, imageID: imageID, cores: coresValue, memoryGB: memoryValue))
                dismiss()
            } catch {
                if VirtualMachinePresentation.staysInSheet(error) {
                    message = errorMessage(error)
                } else {
                    startFailed(errorMessage(error))
                    dismiss()
                }
            }
            starting = false
        }
    }
}
