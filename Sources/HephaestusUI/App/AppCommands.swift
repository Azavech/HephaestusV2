// OWNER: ui-shell — every menu item and keyboard shortcut of docs/ui.md › Menus and keyboard
// shortcuts, and docs/ui.md › Closing tabs and windows.
import AppKit
import HephaestusCore
import SwiftUI

/// The app's menus. Conditions of the docs' table: **main** — the key window is a main window;
/// **connected** — its device is connected; **project** — it has an active project on a connected
/// device. While a main window shows a sheet, the items that act on it are disabled
/// (docs/ui.md › Principles, Sheet modality).
public struct AppCommands: Commands {
    let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutCommand()
        }
        CommandGroup(replacing: .newItem) {
            FileNewCommands(app: app)
        }
        CommandGroup(replacing: .saveItem) {
            FileCloseAndSaveCommands(app: app)
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .pasteboard) {
            PasteAndMatchStyleCommand()
        }
        // Find, Spelling and Grammar, Substitutions, Transformations and Speech: standard items
        // without a target, which AppKit validates through the responder chain (docs/ui.md ›
        // Menus and keyboard shortcuts, note 3).
        TextEditingCommands()
        CommandGroup(after: .textEditing) {
            ToggleCommentCommand()
        }
        CommandGroup(replacing: .sidebar) {
            ViewCommands(app: app)
        }
        CommandGroup(replacing: .toolbar) {}
        CommandMenu("Navigate") {
            NavigateCommands()
        }
        CommandMenu("Project") {
            ProjectCommands(app: app)
        }
        CommandGroup(replacing: .help) {
            SendFeedbackCommand(app: app)
        }
    }
}

/// The focused main window when it shows no sheet.
@MainActor
private func actionable(_ window: WindowState?) -> WindowState? {
    guard let window, window.sheet == nil else { return nil }
    return window
}

// MARK: - HephaestusV2

private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About HephaestusV2") {
            openWindow(id: "about")
        }
    }
}

// MARK: - File

private struct FileNewCommands: View {
    let app: AppModel
    @FocusedValue(\.windowState) private var focused
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The menu exists from launch on: its action lets the app open a main window before any
        // window has appeared (AppModel.ensureLaunchWindow).
        let _ = app.captureCommandsOpenWindow(openWindow)
        let window = actionable(focused)
        Button("New Window") {
            app.openNewMainWindow()
        }
        .keyboardShortcut("n", modifiers: .command)
        Button("New Project…") {
            window?.sheet = .newProject
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!(window?.isConnected ?? false))
        Button("Open Project…") {
            if let window, let workspace = window.workspace {
                ProjectFlows.openProject(window: window, workspace: workspace)
            }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(!(window?.isConnected ?? false))
        Divider()
        Button("New Ticket") {
            if let window, let projectID = window.projectID {
                window.sheet = .newTicket(projectID: projectID)
            }
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!(window?.hasActiveProject ?? false))
        Button("New Chat") {
            window?.newChat()
        }
        .keyboardShortcut("n", modifiers: [.command, .option])
        .disabled(!(window?.hasActiveProject ?? false))
        Button("New Web Tab") {
            window?.section = .web
            window?.pendingSectionCommand = .newWebTab
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(!(window?.hasActiveProject ?? false))
    }
}

/// Close Tab or Close Window (⌘W), Close Window (⇧⌘W) and Save (⌘S)
/// (docs/ui.md › Closing tabs and windows).
private struct FileCloseAndSaveCommands: View {
    let app: AppModel
    @FocusedValue(\.windowState) private var focused

    var body: some View {
        let window = actionable(focused)
        let closesTab = window?.sectionCommands?.canCloseTab ?? false
        Divider()
        Button(closesTab ? "Close Tab" : "Close Window") {
            if let window, closesTab {
                window.sectionCommands?.closeTab()
            } else {
                closeKeyWindow()
            }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(!canClose)
        Button("Close Window") {
            closeKeyWindow()
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(!canClose)
        Button("Save") {
            window?.sectionCommands?.save()
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!(window?.sectionCommands?.canSave ?? false))
    }

    /// A window is key and shows no sheet; `MenuValidation` follows the key window, which SwiftUI
    /// does not observe.
    private var canClose: Bool {
        let validation = MenuValidation.shared
        return validation.keyWindowNumber != nil && !validation.keyWindowShowsSheet && focused?.sheet == nil
    }

    /// A main window closes after the unsaved changes check; any other window closes.
    private func closeKeyWindow() {
        guard let key = NSApp.keyWindow else { return }
        if let id = app.windowRegistry.mainID(of: key), let state = app.windows[id] {
            Task {
                await app.closeMainWindow(state)
            }
        } else {
            key.performClose(nil)
        }
    }
}

// MARK: - Edit

/// Edit ▸ Paste and Match Style (⌥⇧⌘V): sends `pasteAsPlainText:` to the first responder; enabled
/// while the focused view accepts it (docs/ui.md › Menus and keyboard shortcuts). SwiftUI has no
/// standard item for it, so it follows the pasteboard group.
private struct PasteAndMatchStyleCommand: View {
    var body: some View {
        Button("Paste and Match Style") {
            NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("v", modifiers: [.command, .option, .shift])
        .disabled(!MenuValidation.shared.canPasteAndMatchStyle)
    }
}

private struct ToggleCommentCommand: View {
    @FocusedValue(\.windowState) private var focused

    var body: some View {
        let handler = actionable(focused)?.sectionCommands
        Button("Toggle Comment") {
            handler?.toggleComment()
        }
        .keyboardShortcut("/", modifiers: .command)
        .disabled(!(handler?.canToggleComment ?? false))
    }
}

// MARK: - View

private struct ViewCommands: View {
    let app: AppModel
    @FocusedValue(\.windowState) private var focused

    var body: some View {
        let window = actionable(focused)
        let hasProject = window?.projectID != nil
        ForEach(ProjectSection.listed, id: \.self) { section in
            Button(section.title) {
                window?.section = section
            }
            .keyboardShortcut(section.shortcut)
            .disabled(!hasProject)
        }
        Divider()
        let showsDoc = window?.section == .docs && window?.viewState.selectedDocPath != nil
        Menu("Doc Mode") {
            ForEach(Array(DocMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) {
                    window?.updateViewState { $0.docMode = mode }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
            }
        }
        .disabled(!showsDoc)
        Divider()
        Button(window?.sidebarVisible ?? true ? "Hide Sidebar" : "Show Sidebar") {
            window?.sidebarVisible.toggle()
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
        .disabled(window == nil)
        Button(window?.inspectorVisible ?? true ? "Hide Project Chat" : "Show Project Chat") {
            window?.inspectorVisible.toggle()
        }
        .keyboardShortcut("0", modifiers: [.command, .option])
        .disabled(!hasProject)
        Button(window?.consoleVisible ?? false ? "Hide Console" : "Show Console") {
            window?.consoleVisible.toggle()
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])
        .disabled(!hasProject)
        Divider()
    }
}

// MARK: - Navigate

private struct NavigateCommands: View {
    @FocusedValue(\.windowState) private var focused

    var body: some View {
        let window = actionable(focused)
        let handler = window?.sectionCommands
        Button("Search…") {
            window?.toggleSearch()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(!(window?.isConnected ?? false))
        Button("Go to Line…") {
            handler?.goToLine()
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(!(handler?.canGoToLine ?? false))
        Divider()
        Button("Back") {
            handler?.goBack()
        }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!(handler?.canGoBack ?? false))
        Button("Forward") {
            handler?.goForward()
        }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!(handler?.canGoForward ?? false))
        Button("Reload Page") {
            handler?.reloadPage()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!(handler?.canReloadPage ?? false))
        Button("Open Location…") {
            window?.pendingSectionCommand = .openLocation
        }
        .keyboardShortcut("l", modifiers: [.command, .option])
        .disabled(window?.section != .web || window?.projectID == nil)
        Divider()
        Button("Show Previous Tab") {
            handler?.showPreviousTab()
        }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(!(handler?.canShowAdjacentTab ?? false))
        Button("Show Next Tab") {
            handler?.showNextTab()
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(!(handler?.canShowAdjacentTab ?? false))
    }
}

// MARK: - Project

private struct ProjectCommands: View {
    let app: AppModel
    @FocusedValue(\.windowState) private var focused

    var body: some View {
        let window = actionable(focused)
        let project = window?.hasActiveProject ?? false
        ForEach([RunKind.run, .build, .test], id: \.self) { kind in
            Button(kind.title) {
                window?.startRun(kind)
            }
            .keyboardShortcut(Self.shortcut(kind), modifiers: .command)
            .disabled(!project || window?.command(kind) == nil)
        }
        Button("Stop") {
            window?.stopRuns()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(window?.runningRuns.isEmpty ?? true)
        Button("Clear Console") {
            if let window, let run = window.consoleRun {
                window.workspace?.runs[run.id]?.clear()
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(!(window?.consoleVisible ?? false) || window?.consoleRun == nil)
        Divider()
        Button("New Sub Project…") {
            if let window, let projectID = window.projectID {
                window.sheet = .newSubProject(parentID: projectID)
            }
        }
        .disabled(!project)
        Button("Project Settings…") {
            window?.section = .settings
        }
        .keyboardShortcut(ProjectSection.settings.shortcut)
        .disabled(!project)
        if window?.workspace?.isLocal ?? true {
            Button("Reveal in Finder") {
                if let window, let projectID = window.projectID, let summary = window.workspace?.project(projectID) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.rootPath)])
                }
            }
            .disabled(!project)
        }
        Divider()
        Button("Remove Project…") {
            if let window, let workspace = window.workspace {
                ProjectFlows.removeProject(window: window, workspace: workspace)
            }
        }
        .disabled(!project)
    }
}

extension ProjectCommands {
    /// Run ⌘R, Build ⌘B, Test ⌘U.
    static func shortcut(_ kind: RunKind) -> KeyEquivalent {
        switch kind {
        case .run: return "r"
        case .build: return "b"
        case .test: return "u"
        }
    }
}

// MARK: - Help

/// Help ▸ Send Feedback… (⇧⌘B): starts feedback for the key window; disabled without a key window
/// and while the key window shows a sheet (docs/feedback.md › Starting feedback).
private struct SendFeedbackCommand: View {
    let app: AppModel
    @FocusedValue(\.windowState) private var focusedMain
    @FocusedValue(\.chatWindowValue) private var focusedChat

    var body: some View {
        let validation = MenuValidation.shared
        Button("Send Feedback…") {
            guard let key = NSApp.keyWindow else { return }
            let source: FeedbackSource
            switch app.windowRegistry.role(of: key) {
            case .main(let id):
                guard let state = app.windows[id] else { return }
                source = .main(state)
            case .chat(let value):
                source = .chat(value)
            default:
                source = .other
            }
            app.feedbackController.start(capturing: key, source: source)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(validation.keyWindowNumber == nil || validation.keyWindowShowsSheet || focusedMain?.sheet != nil)
    }
}
