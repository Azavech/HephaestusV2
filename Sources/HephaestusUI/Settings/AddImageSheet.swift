// OWNER: ui-shell — the Add Image sheet of Settings > Virtual Machines (docs/ui.md › Virtual
// Machines; docs/virtual-machines.md › Adding an image).
import HephaestusCore
import SwiftUI

/// Add Image: the macOS versions that ipsw.me gives, newest first. The sheet asks for nothing else:
/// the values of a virtual machine are chosen when it is created. `Add` calls `vmImages.add` and
/// closes the sheet; the download and the install then show in the Images table.
struct AddImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var versions: [MacOSVersion] = []
    @State private var selectedBuild: String?
    @State private var loading = true
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

    private func add() {
        guard let build = selectedBuild, !adding else { return }
        message = nil
        adding = true
        Task {
            do {
                _ = try await app.localWorkspace.call(VMImagesAdd.self, VMImagesAdd.Params(build: build))
                dismiss()
            } catch {
                message = errorMessage(error)
            }
            adding = false
        }
    }
}
