// OWNER: ui-shell — the scenes of docs/ui.md › Windows, used by the `@main` App.
import SwiftUI

/// Main window: `WindowGroup` with id `main` (docs/ui.md › Windows). It presents a request id: a
/// window opened by the app (New Window, navigation) gets its prepared `WindowState` through it;
/// a window opened by macOS (launch, Dock icon) has none.
public struct MainWindowScene: Scene {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Scene {
        WindowGroup(id: "main", for: UUID.self) { $requestID in
            MainWindowRoot(requestID: requestID)
                .environment(app)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .restorationBehavior(app.restoresWindows ? .automatic : .disabled)
        .commands {
            AppCommands(app: app)
        }
    }
}

/// Chat window: `WindowGroup` with id `chat` presenting a `ChatWindowValue` (docs/ui.md › Windows).
public struct ChatWindowScene: Scene {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Scene {
        WindowGroup(id: "chat", for: ChatWindowValue.self) { $value in
            ChatWindowRoot(value: value)
                .environment(app)
        }
        .defaultSize(width: 720, height: 820)
        .windowResizability(.contentMinSize)
        .restorationBehavior(app.restoresWindows ? .automatic : .disabled)
        .commandsRemoved()
    }
}

/// Image viewer: `WindowGroup` with id `image` presenting an `ImageViewerValue`, not restored
/// (docs/ui.md › Windows; size and title in docs/tickets.md › Image viewer).
public struct ImageViewerScene: Scene {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Scene {
        WindowGroup(id: "image", for: ImageViewerValue.self) { $value in
            if let value {
                ImageViewerWindow(value: value)
                    .registersWindow(.image(value), in: app)
                    .environment(app)
            }
        }
        .defaultSize(width: 640, height: 480)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

/// Image setup: `WindowGroup` with id `imageSetup` presenting the id of a virtual machine image,
/// not restored (docs/ui.md › Windows; docs/virtual-machines.md › Setup window).
public struct ImageSetupScene: Scene {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Scene {
        WindowGroup(id: "imageSetup", for: UUID.self) { $imageID in
            if let imageID {
                ImageSetupWindow(imageID: imageID)
                    .registersWindow(.imageSetup(imageID), in: app)
                    .environment(app)
            }
        }
        .defaultSize(width: 1340, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

/// About: `Window` with id `about`, title `About HephaestusV2`, fixed width 360, not restored
/// (docs/ui.md › Windows; docs/updater.md › About window).
public struct AboutScene: Scene {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Scene {
        Window("About HephaestusV2", id: "about") {
            AboutView()
                .frame(width: 360)
                .registersWindow(.about, in: app)
                .environment(app)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

/// Settings: the `Settings` scene, width 600, title the selected tab's name, not restored
/// (docs/ui.md › Windows, › Settings window).
public struct SettingsScene: Scene {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Scene {
        Settings {
            SettingsWindowView()
                .registersWindow(.settings, in: app)
                .environment(app)
        }
        .restorationBehavior(.disabled)
    }
}
