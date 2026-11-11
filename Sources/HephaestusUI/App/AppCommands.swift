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
        // The View items replace the toolbar group, the first group of the View menu. SwiftUI keeps
        // the separator between the toolbar and sidebar groups even when one of them is empty: with
        // an empty toolbar group the menu would start with it; here it ends the View items.
        CommandGroup(replacing: .toolbar) {
            ViewCommands(app: app)
        }
        CommandGroup(replacing: .sidebar) {}
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
        // docs/builds.md › Visibility: View ▸ Builds is enabled while the Builds row shows.
        let showsBuilds = window.flatMap { window in window.workspace.map { window.showsBuilds(in: $0) } } ?? false
        ForEach(ProjectSection.listed, id: \.self) { section in
            Button(section.title) {
                window?.section = section
            }
            .keyboardShortcut(section.shortcut)
            .disabled(!hasProject || (section == .builds && !showsBuilds))
        }
        // docs/memories.md › Global Memories view: enabled in a main window whose device is
        // connected, with or without project.
        Button("Global Memories") {
            window?.showsGlobalMemories = true
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!(window?.isConnected ?? false))
        // docs/skills.md › Internal Skills view: enabled in a main window whose device is
        // connected, with or without project.
        Button("Internal Skills") {
            window?.showsInternalSkills = true
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!(window?.canShowInternalSkills ?? false))
        // Enabled while the active project's sidebar shows the row (docs/openapi.md › Availability).
        Button(ProjectSection.apiExplorer.title) {
            window?.section = .apiExplorer
        }
        .keyboardShortcut(ProjectSection.apiExplorer.shortcut)
        .disabled(!(window?.showsAPIExplorer ?? false))
        // Enabled while the active project's sidebar shows the row, without shortcut
        // (docs/graph.md › Enabling).
        Button(ProjectSection.graph.title) {
            window?.section = .graph
        }
        .disabled(!(window?.showsGraph ?? false))
        // Enabled while the active project's sidebar shows the row, without shortcut
        // (docs/views.md › Visibility).
        Button(ProjectSection.views.title) {
            window?.section = .views
        }
        .disabled(!(window?.showsViews ?? false))
        Divider()
        let showsDoc = window?.shownSection == .docs && window?.viewState.selectedDocPath != nil
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
        Button(window?.sidebarToggleTitle ?? "Hide Sidebar") {
            window?.sidebarVisible.toggle()
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
        .disabled(window == nil)
        Button(window?.inspectorVisible ?? true ? "Hide Project Chat" : "Show Project Chat") {
            window?.inspectorVisible.toggle()
        }
        .keyboardShortcut("0", modifiers: [.command, .option])
        .disabled(!hasProject)
    }
}

// MARK: - Navigate

private struct NavigateCommands: View {
    @FocusedValue(\.windowState) private var focused
    @FocusedValue(\.chatWindowSearch) private var chatSearch

    var body: some View {
        let window = actionable(focused)
        let handler = window?.sectionCommands
        // In a chat window, whose search panel only `Add Resource…` opens, the command closes the
        // panel while it shows (docs/search.md › Adding a resource).
        let closesChatSearch = window == nil && chatSearch?.searchVisible == true
        Button("Search…") {
            if closesChatSearch {
                chatSearch?.searchVisible = false
            } else {
                window?.toggleSearch()
            }
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(!(window?.isConnected ?? false) && !closesChatSearch)
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
        .disabled(window?.shownSection != .web || window?.projectID == nil)
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
        // Not shown for the HephaestusV2 project and its ancestors (docs/projects.md › Removing a project).
        if !removalHidden(focused) {
            Divider()
            Button("Remove Project…") {
                if let window, let workspace = window.workspace {
                    ProjectFlows.removeProject(window: window, workspace: workspace)
                }
            }
            .disabled(!project)
        }
    }

    private func removalHidden(_ window: WindowState?) -> Bool {
        guard let window, let projectID = window.projectID, let workspace = window.workspace else { return false }
        return ProjectRules.isHephaestusOrAncestor(projectID, projects: workspace.projects)
    }
}

// MARK: - Help

/// Help ▸ Send Feedback… (⇧⌘B): starts feedback for the key window; disabled without a key window
/// and while the key window shows a sheet; not shown, so that ⇧⌘B does nothing, while the key
/// window's receiving device hides its HephaestusV2 project (docs/feedback.md › Starting feedback).
private struct SendFeedbackCommand: View {
    let app: AppModel
    @FocusedValue(\.windowState) private var focusedMain
    @FocusedValue(\.chatWindowValue) private var focusedChat

    var body: some View {
        let validation = MenuValidation.shared
        if !keyWindowHidesFeedback(validation) {
            button(validation)
        }
    }

    /// The key window's receiving device hides its HephaestusV2 project; `keyWindowNumber` is read
    /// so that the menu follows the key window.
    private func keyWindowHidesFeedback(_ validation: MenuValidation) -> Bool {
        _ = validation.keyWindowNumber
        let receivingDeviceID = FeedbackProject.receivingDeviceID(of: NSApp.keyWindow, app: app)
        return FeedbackProject.hidesFeedback(app.workspaces[receivingDeviceID])
    }

    private func button(_ validation: MenuValidation) -> some View {
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
