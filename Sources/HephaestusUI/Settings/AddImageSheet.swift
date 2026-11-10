// OWNER: ui-shell — the Add Image sheet of Settings > Virtual Machines (docs/ui.md › Virtual
// Machines; docs/virtual-machines.md › Adding an image).
import HephaestusCore
import SwiftUI

/// Add Image: the macOS versions that ipsw.me gives, newest first, and the values of the image.
/// `Add` calls `vmImages.add` and closes the sheet; the download and the install then show in the
/// Images table.
struct AddImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var versions: [MacOSVersion] = []
    @State private var selectedBuild: String?
    @State private var loading = true
    @State private var cores = String(VMImageLimits.defaultCores)
    @State private var memory = String(VMImageLimits.defaultMemoryGB)
    @State private var disk = String(VMImageLimits.defaultDiskGB)
    @State private var message: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Image")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Version")
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        Picker("Version", selection: $selectedBuild) {
                            ForEach(versions) { version in
                                Text(MacOSVersion.title(version: version.version, build: version.build))
                                    .tag(Optional(version.build))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(versions.isEmpty)
                        if loading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                numberRow("Cores", text: $cores)
                numberRow("Memory (GB)", text: $memory)
                numberRow("Disk (GB)", text: $disk)
            }
            .disabled(adding)
            FieldMessage(text: message)
            SheetButtonRow(defaultTitle: "Add", defaultEnabled: selectedBuild != nil && !adding, cancel: { dismiss() }, confirm: add)
        }
        .padding(20)
        .frame(width: 380)
        .task {
            await loadVersions()
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

    /// `vmImages.versions`, called when the sheet opens; the newest version is selected.
    private func loadVersions() async {
        do {
            let list = try await app.localWorkspace.call(VMImagesVersions.self)
            versions = list
            selectedBuild = list.first?.build
        } catch {
            message = errorMessage(error)
        }
        loading = false
    }

    /// The whole number of a field, or nil with the engine's message for a value outside the range
    /// of its param.
    private func value(_ text: String, _ param: String, _ range: ClosedRange<Int>) -> Int? {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
        message = VMImageLimits.message(param, range)
        return nil
    }

    private func add() {
        guard let build = selectedBuild, !adding else { return }
        let limits = VMImageLimits.host
        guard let coresValue = value(cores, "cores", limits.cores),
              let memoryValue = value(memory, "memoryGB", limits.memoryGB),
              let diskValue = value(disk, "diskGB", limits.diskGB) else { return }
        message = nil
        adding = true
        Task {
            do {
                _ = try await app.localWorkspace.call(VMImagesAdd.self, VMImagesAdd.Params(
                    build: build, cores: coresValue, memoryGB: memoryValue, diskGB: diskValue))
                dismiss()
            } catch {
                message = errorMessage(error)
            }
            adding = false
        }
    }
}
