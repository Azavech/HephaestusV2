// OWNER: ui-shell — the Virtual Machines tab of the Settings window (docs/ui.md › Virtual Machines;
// docs/virtual-machines.md).
import AppKit
import HephaestusCore
import SwiftUI

/// The texts of the images of virtual machines (docs/ui.md › Virtual Machines,
/// docs/virtual-machines.md › Image states, › Setup window).
enum VMImagePresentation {
    /// The text of the State column: `Downloading… 42%`, `Installing… 63%`, `Needs setup`, `Ready`
    /// or `Failed: <message>`.
    static func stateText(_ image: VMImage) -> String {
        switch image.state {
        case .downloading: return "Downloading… \(image.percentage)%"
        case .installing: return "Installing… \(image.percentage)%"
        case .needsSetup: return "Needs setup"
        case .ready: return "Ready"
        case .failed:
            guard let failure = image.failure, !failure.isEmpty else { return "Failed" }
            return "Failed: \(failure)"
        }
    }

    /// The text of the macOS column and of the Version pop-up: `27.2.1 (26B131)`.
    static func versionText(_ image: VMImage) -> String {
        MacOSVersion.title(version: image.version, build: image.build)
    }

    /// The text of the Disk column: the space the image uses on disk, as a file size.
    static func diskText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }

    /// The title of the setup window: `Set Up macOS <version>`.
    static func setupTitle(version: String) -> String {
        "Set Up macOS \(version)"
    }

    /// The status line of the setup window.
    static func agentStatusText(_ agent: GuestAgentStatus?) -> String {
        guard let agent else { return "Waiting for the agent…" }
        return agent.sip == .disabled ? "Agent connected · SIP off" : "Agent connected · SIP on"
    }

    /// The title of the Delete… alert.
    static func deleteTitle(version: String) -> String {
        "Delete the image “macOS \(version)”?"
    }

    static let deleteMessage = "Its virtual machines are deleted too."

    /// The title of the alert of a setup that failed: `Set Up…` that cannot boot the image, and a
    /// setup virtual machine that fails while it runs.
    static let setUpFailedTitle = "Set Up failed"
    /// The title of the alert of a `Restart in Recovery` that cannot start the virtual machine.
    static let restartFailedTitle = "Restart in Recovery failed"

    /// The title of the alert of a setup that ended with a failure.
    @MainActor
    static func failureTitle(of session: VMSetupSession) -> String {
        session.restartFailed ? restartFailedTitle : setUpFailedTitle
    }

    /// The failure alert of docs/ui.md › Principles, on a window.
    @MainActor
    static func showFailure(_ title: String, _ message: String, on window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await AlertPresenter.present(alert, on: window)
    }
}

/// The Virtual Machines tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the
/// image setup service).
struct VirtualMachinesSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var showsAddImage = false
    @State private var hostWindow = HostWindow()

    private var images: [VMImage] { app.localWorkspace.vmImages ?? [] }
    private var defaultImageID: UUID? { app.localWorkspace.settings?.defaultVMImage }
    private var selected: VMImage? { images.first { $0.id == selection } }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "Images") {
                Table(images, selection: $selection) {
                    TableColumn("Default") { image in
                        // The radio of the questions cards; the mark moves when `settings.updated`
                        // arrives.
                        RadioButton(selected: defaultImageID == image.id) {
                            if defaultImageID != image.id {
                                setDefault(image)
                            }
                        }
                        .disabled(image.state != .ready)
                        .accessibilityLabel("Default")
                    }
                    .width(52)
                    TableColumn("macOS") { image in
                        Text(VMImagePresentation.versionText(image))
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("State") { image in
                        let text = VMImagePresentation.stateText(image)
                        Text(text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(text)
                    }
                    TableColumn("Disk") { image in
                        Text(VMImagePresentation.diskText(image.diskBytes))
                            .monospacedDigit()
                    }
                    .width(80)
                }
                .frame(height: 150)
                HStack(spacing: 8) {
                    Button("Add Image…") {
                        showsAddImage = true
                    }
                    Button("Set Up…", action: setUp)
                        .disabled(selected?.state != .needsSetup)
                    Button("Delete…", action: delete)
                        .disabled(selected == nil)
                }
            }
        }
        .readsHostWindow(hostWindow)
        .task {
            await app.localWorkspace.loadVMImages()
        }
        .onChange(of: images.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
            }
        }
        .sheet(isPresented: Binding(get: { showsAddImage && !app.sheetsEnded }, set: { showsAddImage = $0 })) {
            AddImageSheet()
                .environment(app)
        }
    }

    /// Turning a radio on calls `settings.update` with `defaultVMImage`; the mark moves when
    /// `settings.updated` arrives.
    private func setDefault(_ image: VMImage) {
        let window = hostWindow.window
        Task {
            if let message = await updateLocalSettings(app, SettingsUpdate.Params(defaultVMImage: .set(image.id))) {
                await VMImagePresentation.showFailure("Default failed", message, on: window)
            }
        }
    }

    /// Set Up… boots the selected image and opens its setup window, or brings it to front.
    private func setUp() {
        guard let image = selected else { return }
        let window = hostWindow.window
        Task {
            do {
                try await app.openImageSetup(image.id)
            } catch {
                await VMImagePresentation.showFailure(VMImagePresentation.setUpFailedTitle, errorMessage(error), on: window)
            }
        }
    }

    /// Delete… asks for confirmation, then deletes the selected image.
    private func delete() {
        guard let image = selected else { return }
        let window = hostWindow.window
        Task {
            guard await ShellPanels.confirmDestructive(title: VMImagePresentation.deleteTitle(version: image.version),
                                                       message: VMImagePresentation.deleteMessage,
                                                       action: "Delete", on: window) else { return }
            do {
                _ = try await app.localWorkspace.call(VMImagesDelete.self, VMImagesDelete.Params(imageID: image.id))
            } catch {
                await VMImagePresentation.showFailure("Delete failed", errorMessage(error), on: window)
            }
        }
    }
}
