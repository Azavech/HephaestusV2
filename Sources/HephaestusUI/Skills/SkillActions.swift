// OWNER: ui-skills-feedback — selecting skills, Move to Trash, the library location and the body
// focus of the Skills section (docs/skills.md › Saving, › Move to Trash, › Editor, › Empty and
// error states).
import AppKit
import HephaestusCore
import SwiftUI

/// The actions of the Skills section and of the Internal Skills view that outlive a view:
/// selection with the unsaved changes prompt and the Move to Trash confirmations.
@MainActor
enum SkillActions {
    /// Selects a skill of a project's Skills section, or of the Internal Skills view, in a window,
    /// or clears the selection with nil. When the shown skill has unsaved changes, `Do you want to
    /// save the changes to “<name>”?` asks first; Cancel keeps the current selection and returns
    /// false (docs/skills.md › Saving). `startEditing` opens the skill's body in Edit mode with the
    /// keyboard focus (New Skill sheet).
    @discardableResult
    static func select(_ name: String?, window: WindowState, workspace: DeviceWorkspace, scope: SkillsScope,
                       startEditing: Bool = false) async -> Bool {
        let current = window.skillViewState(scope, deviceID: workspace.deviceID)
        if current.selectedSkillName == name, !startEditing { return true }
        if let editor = current.skillEditor, editor.skillName != name {
            let unsaved = editor.unsavedEditors
            if !unsaved.isEmpty {
                guard await UnsavedChangesPrompt.confirm(unsaved, in: window) else { return false }
            }
        }
        window.updateSkillViewState(scope, deviceID: workspace.deviceID) { state in
            state.selectedSkillName = name
            guard let name else {
                state.skillEditor = nil
                return
            }
            guard startEditing || state.skillEditor?.skillName != name else { return }
            let editor = SkillEditorState(skillName: name, scope: scope,
                                          bodyMode: startEditing ? .edit : state.skillEditor?.bodyMode ?? .preview)
            editor.attach(window: window, workspace: workspace)
            if startEditing {
                editor.bodyFocusRequest += 1
            }
            state.skillEditor = editor
            Task {
                await editor.refresh()
            }
        }
        return true
    }

    /// The skill's Move to Trash: the alert `Move “<name>” to the Trash?`, then `skills.delete`;
    /// the skill's selection is cleared in this window.
    static func trashSkill(_ name: String, window: WindowState, workspace: DeviceWorkspace, projectID: String) async {
        let confirmed = await confirmTrash(title: "Move “\(name)” to the Trash?",
                                           message: "The skill is removed from every project that enables it.",
                                           window: window)
        guard confirmed else { return }
        do {
            _ = try await workspace.call(SkillsDelete.self, .init(name: name))
        } catch {
            window.alert = .failure("Move to Trash", error)
            return
        }
        let scope = SkillsScope.project(projectID)
        guard window.skillViewState(scope, deviceID: workspace.deviceID).selectedSkillName == name else { return }
        window.updateSkillViewState(scope, deviceID: workspace.deviceID) {
            $0.selectedSkillName = nil
            $0.skillEditor = nil
        }
    }

    /// An extra file's Move to Trash: the alert `Move “<path>” to the Trash?`, then
    /// `skills.deleteFile`; its view closes without saving.
    static func trashFile(_ path: String, of editor: SkillEditorState, window: WindowState, workspace: DeviceWorkspace) async {
        guard await confirmTrash(title: "Move “\(path)” to the Trash?", message: nil, window: window) else { return }
        do {
            _ = try await workspace.call(SkillsDeleteFile.self, .init(name: editor.skillName, path: path))
        } catch {
            window.alert = .failure("Move to Trash", error)
            return
        }
        editor.fileWasTrashed(path)
    }

    /// `Move to Trash` (destructive, default) and `Cancel` (Escape) as a sheet of the window
    /// (docs/skills.md › Move to Trash).
    private static func confirmTrash(title: String, message: String?, window: WindowState) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let response = await AlertPresenter.present(alert, on: window.app?.windowRegistry.window(forMain: window.id))
        return response == .alertFirstButtonReturn
    }
}

/// The skills library folder of a device, for the library empty state and the editor's footer.
@MainActor
enum SkillLibraryLocation {
    /// The default library of a device whose data directory is the default one.
    static let defaultRemotePath = "~/Library/Application Support/HephaestusV2/Skills"

    /// The library folder of This Mac: `skillsLibraryPath` with `~/` expanded, else
    /// `<data dir>/Skills`; nil for a remote device.
    static func localURL(of workspace: DeviceWorkspace) -> URL? {
        guard workspace.isLocal, let app = AppModel.shared else { return nil }
        let settings = workspace.settings ?? HostSettings()
        return settings.skillsLibraryURL(dataDirectory: app.engine.dataDirectory)
    }

    /// The library folder with the home folder written `~`. A remote snapshot carries neither the
    /// data directory nor the home folder: a remote library without `skillsLibraryPath` is shown at
    /// its default place, and a path under `/Users/<name>` is written with `~` (docs/skills.md ›
    /// Remote windows).
    static func displayPath(of workspace: DeviceWorkspace) -> String {
        if let url = localURL(of: workspace) {
            return abbreviated(url.path, home: NSHomeDirectory())
        }
        guard let path = workspace.settings?.skillsLibraryPath else { return defaultRemotePath }
        if path.hasPrefix("~/") { return path }
        let components = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Users" {
            return (["~"] + components.dropFirst(2).map(String.init)).joined(separator: "/")
        }
        return path
    }

    /// A skill's folder, home folder written `~`.
    static func displayPath(of skillName: String, in workspace: DeviceWorkspace) -> String {
        displayPath(of: workspace) + "/" + skillName
    }

    static func abbreviated(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Puts the keyboard focus in the editable text view drawn in this view's frame, once per
/// request: the New Skill sheet focuses the new skill's body (docs/skills.md › New Skill sheet).
/// The code editor is an AppKit text view, so the focus is set through AppKit.
struct TextViewFocuser: NSViewRepresentable {
    /// True while a focus request waits.
    let isPending: Bool
    /// Called once the request is handled.
    let done: () -> Void

    func makeNSView(context: Context) -> FocuserView {
        FocuserView()
    }

    func updateNSView(_ view: FocuserView, context: Context) {
        view.done = done
        if isPending {
            view.start()
        }
    }

    final class FocuserView: NSView {
        var done: (() -> Void)?
        private var isRunning = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func start() {
            guard !isRunning else { return }
            isRunning = true
            attempt(remaining: 20)
        }

        /// The text view may be created after this view, so the search is retried every 0.1 s
        /// for 2 seconds.
        private func attempt(remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if let window = self.window, let target = self.textView(in: window) {
                    window.makeFirstResponder(target)
                    self.finish()
                } else if remaining > 0 {
                    self.attempt(remaining: remaining - 1)
                } else {
                    self.finish()
                }
            }
        }

        private func finish() {
            isRunning = false
            done?()
        }

        private func textView(in window: NSWindow) -> NSTextView? {
            guard let root = window.contentView else { return nil }
            let frame = convert(bounds, to: nil)
            return Self.textViews(in: root).first { textView in
                textView.isEditable && !textView.isHiddenOrHasHiddenAncestor
                    && frame.intersects(textView.convert(textView.visibleRect, to: nil))
            }
        }

        private static func textViews(in view: NSView) -> [NSTextView] {
            if let textView = view as? NSTextView { return [textView] }
            return view.subviews.flatMap { textViews(in: $0) }
        }
    }
}
