// OWNER: ui-shell — the `@main` App: every scene of docs/ui.md › Windows, wired to `AppModel`
// (docs/architecture.md › Modules).
import HephaestusUI
import SwiftUI

@main
struct HephaestusV2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Startup steps 1 to 8 run here, before any window opens (docs/architecture.md › Startup).
    private let app = AppModel.launch()

    var body: some Scene {
        MainWindowScene(app: app)
        ChatWindowScene(app: app)
        ImageViewerScene(app: app)
        AboutScene(app: app)
        SettingsScene(app: app)
    }
}
