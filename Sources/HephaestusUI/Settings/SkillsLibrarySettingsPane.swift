// OWNER: ui-shell — the Skills tab of the Settings window (docs/ui.md › Skills library).
import AppKit
import HephaestusCore
import SwiftUI

/// The Skills tab; it always shows and changes This Mac (`AppModel.localWorkspace` and the local-only services).
struct SkillsLibrarySettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var message: String?
    @State private var hostWindow = HostWindow()

    private var settings: HostSettings? { app.localWorkspace.settings }

    var body: some View {
        SettingsForm {
            SettingsRow(label: "Library folder") {
                HStack(spacing: 6) {
                    PathText(path: (effectiveFolder.path as NSString).abbreviatingWithTildeInPath)
                    if settings?.skillsLibraryPath == nil {
                        Text("(default)")
                            .foregroundStyle(.secondary)
                    }
                }
                FieldMessage(text: message)
                HStack(spacing: 8) {
                    Button("Choose…", action: choose)
                    Button("Use Default", action: useDefault)
                        .disabled(settings?.skillsLibraryPath == nil)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([effectiveFolder])
                    }
                }
                .padding(.top, 4)
                Text("Skills in the previous folder are not moved. Enabled skills that the new folder lacks show under Missing from Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(settings == nil)
        .readsHostWindow(hostWindow)
    }

    /// The setting with `~/` expanded, or `<data dir>/Skills` while the setting is absent.
    private var effectiveFolder: URL {
        guard let settings else { return app.engine.dataDirectory.skillsFolder }
        return settings.skillsLibraryURL(dataDirectory: app.engine.dataDirectory)
    }

    /// `NSOpenPanel` as a sheet of the Settings window: folders only, one selection, folder
    /// creation allowed, prompt `Choose`. An `invalid` error shows in red under the path.
    private func choose() {
        Task {
            guard let path = await ShellPanels.chooseFolder(on: hostWindow.window, prompt: "Choose", canCreateDirectories: true,
                                                            directory: effectiveFolder.path) else { return }
            message = await updateLocalSettings(app, SettingsUpdate.Params(skillsLibraryPath: .set(path)))
        }
    }

    /// `settings.update` with `skillsLibraryPath` null.
    private func useDefault() {
        Task {
            message = await updateLocalSettings(app, SettingsUpdate.Params(skillsLibraryPath: .clear))
        }
    }
}
