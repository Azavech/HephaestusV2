// OWNER: ui-code-docs — editor tabs and their buffers, shared by the Code section, the Docs section
// and the skill editor (docs/code-editor.md › Editor buffers, › Opening files, › Large and binary
// files, › Saving, › Changes on disk).
import Foundation
import HephaestusCore
import HephaestusText
import Observation

/// An open editor tab of the Code section (`ProjectViewState.editorTabs`). Its coding keeps only
/// the path: buffers are never encoded (docs/ui.md › WindowState, Persisted column).
struct EditorTabState: Identifiable {
    var id: String { path }
    /// Project path; follows renames.
    var path: String
    var buffer: EditorBuffer

    /// A tab whose buffer is still to be loaded.
    @MainActor
    init(path: String) {
        self.path = path
        self.buffer = EditorBuffer(path: path, role: .codeTab)
    }

    /// A tab restored with its window: read again from disk, dropped when its file no longer
    /// exists (docs/code-editor.md › Opening files).
    @MainActor
    init(restoredPath path: String) {
        self.path = path
        self.buffer = EditorBuffer(path: path, role: .codeTab, isRestored: true)
    }
}

extension EditorTabState: @MainActor Codable {
    enum CodingKeys: String, CodingKey {
        case path
    }

    @MainActor
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(restoredPath: try c.decode(String.self, forKey: .path))
    }

    @MainActor
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
    }
}

/// The buffer of an editor (docs/code-editor.md › Editor buffers). "Unsaved changes" everywhere in
/// the app means `isDirty`.
@MainActor @Observable
final class EditorBuffer {
    /// Where the buffer is shown: a Code section tab or the Docs section's doc.
    enum Role {
        case codeTab
        case doc
    }

    /// What a read of the file gave while a banner is shown: the values Reload and Keep Mine take.
    private enum DiskState {
        case text(String, modified: Date, size: Int)
        case notice(EditorContent, data: Data?, modified: Date, size: Int)
    }

    /// Files above this size open read-only and are not highlighted (2 MB).
    static let readOnlyThreshold = 2_097_152

    var path: String
    var language: CodeLanguage
    /// What the tab shows.
    var content: EditorContent = .loading
    /// Current text. Set from outside the editor (a reload, or the owner of a filled buffer such as
    /// the skill editor), it replaces the editor's text without undo.
    var text = "" {
        didSet {
            if !isApplyingEditorChange, oldValue != text {
                textControllerIfLoaded?.reloadFromHost(clearUndo: true)
            }
        }
    }
    /// Text of the file at the last read or write.
    var diskText = ""
    /// `modified` of that read or write.
    var diskModified = Date.distantPast
    /// True for files above 2 MB.
    var isReadOnly = false
    var banner: EditorBanner?
    /// UTF-16 range.
    var selection = NSRange(location: 0, length: 0)
    var isSaving = false

    var isDirty: Bool { text != diskText }

    // MARK: State beyond docs/code-editor.md › Editor buffers

    // DOC-GAP: docs/code-editor.md › Editor buffers declares the buffer's data only; the
    // properties below hold what the rules of Opening files, Large and binary files, Saving and
    // Changes on disk need: the reveal of a `file` target, the editor's focus for the menu items,
    // the size and bytes of a binary file (Quick Look), and the connection to the window's engine.

    /// A reveal for the editor once the text is shown.
    var pendingReveal: EditorReveal?
    /// The tab selected before a `file` target opened this tab; selected again when the read
    /// finds a folder (docs/code-editor.md › Opening files, step 3).
    @ObservationIgnored var tabSelectedBeforeOpening: String?
    /// True while the buffer's text view has the keyboard focus.
    var hasEditorFocus = false
    /// The file size of the last read.
    var size = 0
    /// The bytes of a binary file, for Quick Look.
    @ObservationIgnored private(set) var binaryData: Data?
    /// True for a tab restored with its window.
    @ObservationIgnored let isRestored: Bool
    @ObservationIgnored let role: Role
    @ObservationIgnored let editorUndoManager = UndoManager()
    @ObservationIgnored private(set) weak var workspace: DeviceWorkspace?
    @ObservationIgnored private(set) var projectID: String?
    @ObservationIgnored private(set) weak var window: WindowState?
    @ObservationIgnored private var textControllerIfLoaded: EditorTextController?
    /// True while the editor reports the user's typing.
    @ObservationIgnored private var isApplyingEditorChange = false
    @ObservationIgnored nonisolated(unsafe) private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var pendingDisk: DiskState?
    /// True after a save conflict, until Reload, Keep Mine or a successful save.
    @ObservationIgnored private var saveConflicted = false
    /// Incremented by every disk check and save: an older read's result is dropped.
    @ObservationIgnored private var readToken = 0
    /// Incremented by every user edit, to know whether the user typed during a save.
    @ObservationIgnored private var editCount = 0
    /// Checks are held while a save or a rename runs, then run once.
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var checkWhenReleased = false
    @ObservationIgnored private var checkAfterLoad = false

    /// A buffer still to be loaded with `files.read`.
    init(path: String, role: Role = .codeTab, isRestored: Bool = false) {
        self.path = path
        self.role = role
        self.isRestored = isRestored
        self.language = SyntaxHighlighter.language(forFileName: ProjectPaths.name(of: path), firstLine: nil)
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }

    /// The file name.
    var name: String { ProjectPaths.name(of: path) }

    /// The text view controller, once the buffer was shown.
    var loadedTextController: EditorTextController? { textControllerIfLoaded }

    // MARK: Attaching and loading (docs/code-editor.md › Opening files)

    /// Connects the buffer to the window's engine and starts following `files.changed`; reads the
    /// file when the buffer is still loading.
    func load(workspace: DeviceWorkspace, projectID: String, window: WindowState?) {
        attach(workspace: workspace, projectID: projectID, window: window)
        if content == .loading {
            startLoading()
        }
    }

    /// A new file's buffer: empty and clean, without a read (docs/code-editor.md › New File).
    func takeNewFile(text: String, modified: Date, workspace: DeviceWorkspace, projectID: String, window: WindowState?) {
        attach(workspace: workspace, projectID: projectID, window: window)
        take(FileContent(path: path, text: text, modified: modified, size: text.utf8.count))
    }

    private func attach(workspace: DeviceWorkspace, projectID: String, window: WindowState?) {
        if let window {
            self.window = window
        }
        guard self.workspace !== workspace || self.projectID != projectID else { return }
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        self.workspace = workspace
        self.projectID = projectID
        let events = workspace.events()
        tasks.append(Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                if case .filesChanged(let payload) = event.event, payload.projectID == self.projectID,
                   self.isAffected(by: payload.paths) {
                    self.checkDisk()
                }
            }
        })
        if !workspace.isLocal {
            // The same check runs for every buffer when a window showing a remote device
            // reconnects, because events may have been missed.
            let start = workspace.connectionGeneration
            let generations = Observations { [weak workspace] in workspace?.connectionGeneration ?? start }
            tasks.append(Task { @MainActor [weak self] in
                for await generation in generations {
                    guard let self else { return }
                    if generation > start {
                        self.checkDisk()
                    }
                }
            })
        }
    }

    /// Stops following the engine (the tab closed).
    func detach() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    /// True when a `files.changed` path is the buffer's path or a folder above it, or `""`.
    func isAffected(by paths: [String]) -> Bool {
        paths.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Reads the file again (Try Again of a failed read).
    func retry() {
        guard workspace != nil else { return }
        content = .loading
        startLoading()
    }

    private func startLoading() {
        guard !isLoading, let workspace, let projectID else { return }
        isLoading = true
        readToken += 1
        let token = readToken
        let path = self.path
        Task { @MainActor [weak self] in
            let result: Result<FileContent, EngineError>
            do {
                result = .success(try await workspace.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: path)))
            } catch let error as EngineError {
                result = .failure(error)
            } catch {
                result = .failure(EngineError(.internal, errorMessage(error)))
            }
            guard let self else { return }
            self.isLoading = false
            guard token == self.readToken, path == self.path else {
                self.startLoading()
                return
            }
            await self.finishLoading(result)
            if self.checkAfterLoad {
                self.checkAfterLoad = false
                self.checkDisk()
            }
        }
    }

    private func finishLoading(_ result: Result<FileContent, EngineError>) async {
        switch result {
        case .success(let file):
            take(file)
        case .failure(let error) where error.code == .notFound:
            if isRestored && role == .codeTab {
                close()
            } else {
                content = .notFound
            }
        case .failure(let error) where error.code == .invalid:
            // A `file` target naming a folder reveals and selects it in the tree.
            if role == .codeTab, let workspace, let projectID,
               (try? await workspace.call(FilesList.self, FilesList.Params(projectID: projectID, path: path))) != nil {
                revealAsFolder()
            } else {
                content = .failed(message: error.message)
            }
        case .failure(let error):
            content = .failed(message: error.message)
        }
    }

    /// Takes a read as the buffer's content (docs/code-editor.md › Large and binary files).
    private func take(_ file: FileContent) {
        size = file.size
        diskModified = file.modified
        if let fileText = file.text {
            text = fileText
            diskText = fileText
            isReadOnly = file.size > Self.readOnlyThreshold
            language = SyntaxHighlighter.language(forFileName: name, firstLine: EditorTextOps.firstLine(of: fileText))
            binaryData = nil
            content = .text
            editorUndoManager.removeAllActions()
            textControllerIfLoaded?.syncWithHost()
        } else {
            text = ""
            diskText = ""
            isReadOnly = false
            if let base64 = file.dataBase64 {
                binaryData = Data(base64Encoded: base64)
                content = .binary(size: file.size)
            } else {
                binaryData = nil
                content = .tooLarge(size: file.size)
            }
        }
    }

    // MARK: Changes on disk (docs/code-editor.md › Changes on disk)

    /// Reads the file again after a `files.changed` event that names it, and applies the table of
    /// Changes on disk.
    func checkDisk() {
        guard let workspace, let projectID else { return }
        if isLoading {
            checkAfterLoad = true
            return
        }
        guard holds == 0, !isSaving else {
            checkWhenReleased = true
            return
        }
        readToken += 1
        let token = readToken
        let path = self.path
        Task { @MainActor [weak self] in
            let result: Result<FileContent, EngineError>
            do {
                result = .success(try await workspace.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: path)))
            } catch let error as EngineError {
                result = .failure(error)
            } catch {
                return
            }
            guard let self, token == self.readToken, path == self.path else { return }
            self.applyDiskRead(result)
        }
    }

    private func applyDiskRead(_ result: Result<FileContent, EngineError>) {
        switch result {
        case .success(let file):
            guard content == .text else {
                // A buffer that showed a notice, a not-found text or a failure takes the new
                // content as it would at opening.
                if !isDirty {
                    take(file)
                }
                return
            }
            if let fileText = file.text {
                if fileText == diskText {
                    diskModified = file.modified
                    if banner != nil {
                        pendingDisk = .text(fileText, modified: file.modified, size: file.size)
                    }
                } else if !isDirty {
                    replaceSilently(with: file, text: fileText)
                } else {
                    banner = .changedOnDisk
                    pendingDisk = .text(fileText, modified: file.modified, size: file.size)
                }
            } else {
                let notice: EditorContent = file.dataBase64 != nil ? .binary(size: file.size) : .tooLarge(size: file.size)
                let data = file.dataBase64.flatMap { Data(base64Encoded: $0) }
                if !isDirty {
                    banner = nil
                    take(file)
                } else {
                    banner = .changedOnDisk
                    pendingDisk = .notice(notice, data: data, modified: file.modified, size: file.size)
                }
            }
        case .failure(let error) where error.code == .notFound:
            switch content {
            case .text:
                if isDirty {
                    banner = .deletedOnDisk
                    pendingDisk = nil
                } else {
                    close()
                }
            case .binary, .tooLarge:
                close()
            case .notFound, .failed:
                content = .notFound
            case .loading:
                break
            }
        case .failure:
            // DOC-GAP: docs/code-editor.md › Changes on disk lists no row for a read that fails
            // otherwise (for example a disconnected device); the buffer is left as it is.
            break
        }
    }

    /// A clean buffer takes new text silently: new text and disk state, insertion point at the
    /// same line and column, scroll kept, undo history cleared.
    private func replaceSilently(with file: FileContent, text fileText: String) {
        banner = nil
        pendingDisk = nil
        size = file.size
        text = fileText
        diskText = fileText
        diskModified = file.modified
        isReadOnly = file.size > Self.readOnlyThreshold
        editorUndoManager.removeAllActions()
        textControllerIfLoaded?.syncWithHost()
    }

    // MARK: Banners (docs/code-editor.md › Banners)

    /// Reload: the buffer takes the text read from disk and becomes clean; undo history cleared.
    func reload() {
        let disk = pendingDisk
        banner = nil
        pendingDisk = nil
        saveConflicted = false
        switch disk {
        case .text(let fileText, let modified, let fileSize):
            replaceSilently(with: FileContent(path: path, text: fileText, modified: modified, size: fileSize), text: fileText)
        case .notice(let notice, let data, let modified, let fileSize):
            text = ""
            diskText = ""
            diskModified = modified
            size = fileSize
            binaryData = data
            content = notice
        case nil:
            checkDisk()
        }
    }

    /// Keep Mine: the buffer keeps its text; `diskText` and `diskModified` take the values read
    /// from disk, so the next save overwrites the file; after a save conflict it saves at once.
    func keepMine() {
        switch pendingDisk {
        case .text(let fileText, let modified, _):
            diskText = fileText
            diskModified = modified
        case .notice(_, _, let modified, _):
            diskText = ""
            diskModified = modified
        case nil:
            break
        }
        banner = nil
        pendingDisk = nil
        if saveConflicted {
            saveConflicted = false
            Task { @MainActor [weak self] in
                try? await self?.save()
            }
        }
    }

    /// Close of the deleted-on-disk banner: closes without saving.
    func closeWithoutSaving() {
        close()
    }

    /// Removes the buffer from its window: its Code tab closes, or the Docs section's doc is
    /// discarded and its selection cleared.
    func close() {
        detach()
        guard let window, let projectID else { return }
        let buffer = self
        window.updateViewState(of: projectID) { state in
            switch buffer.role {
            case .codeTab:
                state.removeEditorTab(buffer)
            case .doc:
                if state.docBuffer === buffer {
                    state.docBuffer = nil
                    state.selectedDocPath = nil
                }
            }
        }
    }

    /// The read of a `file` target's tab found a folder: the tab is removed, the tab selected
    /// before it is selected again, and the folder is revealed in the tree.
    private func revealAsFolder() {
        guard let window, let projectID else { return }
        let buffer = self
        let folder = path
        let previous = tabSelectedBeforeOpening
        detach()
        window.updateViewState(of: projectID) { state in
            let wasSelected = state.selectedEditorPath == folder
            state.removeEditorTab(buffer)
            if wasSelected, let previous, state.editorTabs.contains(where: { $0.path == previous }) {
                state.selectedEditorPath = previous
            }
            state.revealFolder(folder)
        }
    }

    // MARK: Renames

    /// Holds the disk checks while the item is renamed, so the event of the rename does not read
    /// the old path.
    func holdChecks() {
        holds += 1
    }

    /// Releases the hold of `holdChecks()` and runs the checks that waited.
    func releaseChecks() {
        holds = max(0, holds - 1)
        if holds == 0, checkWhenReleased {
            checkWhenReleased = false
            checkDisk()
        }
    }

    /// The buffer follows its renamed file, unsaved changes included.
    func move(to newPath: String) {
        guard newPath != path else { return }
        path = newPath
        readToken += 1
        let firstLine = content == .text ? EditorTextOps.firstLine(of: text) : nil
        language = SyntaxHighlighter.language(forFileName: name, firstLine: firstLine)
        textControllerIfLoaded?.syncWithHost()
    }

    // MARK: Saving (docs/code-editor.md › Saving)

    /// True when ⌘S saves this buffer: editable text with unsaved changes.
    var canSave: Bool {
        content == .text && !isReadOnly && isDirty && !isSaving
    }

    /// Writes the buffer with `files.write` and `expectedModified`; a conflict shows the
    /// changed-on-disk banner, any other error the save alert. Throws on failure, which cancels a
    /// close, removal or quit that waited for this save.
    func save() async throws {
        guard let workspace, let projectID else {
            throw EngineError(.unavailable, "The file “\(name)” is not open.")
        }
        guard content == .text, !isReadOnly else { return }
        let sentText = text
        let editsAtStart = editCount
        let expected: Date? = banner == .deletedOnDisk ? nil : diskModified
        let savedPath = path
        isSaving = true
        defer {
            isSaving = false
            readToken += 1
            if checkWhenReleased, holds == 0 {
                checkWhenReleased = false
                checkDisk()
            }
        }
        do {
            let result = try await workspace.call(FilesWrite.self, FilesWrite.Params(projectID: projectID, path: savedPath, text: sentText,
                                                                                     expectedModified: expected))
            let written = result.text ?? sentText
            diskText = written
            diskModified = result.modified
            size = result.size
            banner = nil
            pendingDisk = nil
            saveConflicted = false
            if written != sentText, editCount == editsAtStart, text == sentText {
                // Formatted on save: one undo step named `Format`.
                if let controller = textControllerIfLoaded {
                    controller.replaceAll(with: written, actionName: "Format")
                }
                text = written
            }
        } catch let error as EngineError where error.code == .conflict {
            saveConflicted = true
            banner = .changedOnDisk
            await readForBanner()
            throw error
        } catch {
            window?.alert = WindowAlert(title: "The file “\(name)” could not be saved.", message: errorMessage(error))
            throw error
        }
    }

    /// After a save conflict: the values on disk for Reload and Keep Mine.
    private func readForBanner() async {
        guard let workspace, let projectID else { return }
        do {
            let file = try await workspace.call(FilesRead.self, FilesRead.Params(projectID: projectID, path: path))
            if let fileText = file.text {
                pendingDisk = .text(fileText, modified: file.modified, size: file.size)
            } else {
                let notice: EditorContent = file.dataBase64 != nil ? .binary(size: file.size) : .tooLarge(size: file.size)
                pendingDisk = .notice(notice, data: file.dataBase64.flatMap { Data(base64Encoded: $0) }, modified: file.modified, size: file.size)
            }
        } catch let error as EngineError where error.code == .notFound {
            banner = .deletedOnDisk
            pendingDisk = nil
        } catch {
            pendingDisk = nil
        }
    }
}

// MARK: - EditorTextHost

extension EditorBuffer: EditorTextHost {
    var editorFileName: String { name }
    var isEditorEditable: Bool { !isReadOnly }
    /// Read-only buffers above 2 MB are not tokenized.
    var highlightsSyntax: Bool { !isReadOnly }

    var textController: EditorTextController {
        if let textControllerIfLoaded { return textControllerIfLoaded }
        let controller = EditorTextController(host: self)
        textControllerIfLoaded = controller
        return controller
    }

    func editorTextDidChange(_ text: String) {
        editCount += 1
        isApplyingEditorChange = true
        self.text = text
        isApplyingEditorChange = false
    }

    func editorSelectionDidChange(_ selection: NSRange) {
        self.selection = selection
    }

    func editorFocusDidChange(_ focused: Bool) {
        hasEditorFocus = focused
    }
}

/// What an editor tab shows (docs/code-editor.md › Editor buffers).
enum EditorContent: Equatable {
    case loading
    case text
    case binary(size: Int)
    case tooLarge(size: Int)
    case failed(message: String)
    // DOC-GAP: docs/code-editor.md › Editor buffers lists no case for a path that does not exist,
    // while › Opening files step 4 shows `File <path> was not found.` in the editor area (and
    // docs/documentation-viewer.md › Empty states `Doc <path> was not found.`); this case shows it.
    case notFound
}

enum EditorBanner: Equatable {
    case changedOnDisk
    case deletedOnDisk
}

extension EditorBuffer: UnsavedEditor {
    var hasUnsavedChanges: Bool { isDirty }

    var savePromptTitle: String {
        "Do you want to save the changes you made to “\(name)”?"
    }

    var savePromptMessage: String? {
        "Your changes will be lost if you don't save them."
    }
}

// MARK: - Tabs of a project's view state

extension ProjectViewState {
    /// The tab of a buffer.
    @MainActor
    func editorTabIndex(of buffer: EditorBuffer) -> Int? {
        editorTabs.firstIndex { $0.buffer === buffer }
    }

    /// Removes a tab; after closing the selected tab, the tab that took its place is selected,
    /// else the new last tab (docs/code-editor.md › Closing tabs).
    @MainActor
    mutating func removeEditorTab(_ buffer: EditorBuffer) {
        guard let index = editorTabIndex(of: buffer) else { return }
        let wasSelected = selectedEditorPath == editorTabs[index].path
        editorTabs.remove(at: index)
        buffer.detach()
        if wasSelected {
            if index < editorTabs.count {
                selectedEditorPath = editorTabs[index].path
            } else {
                selectedEditorPath = editorTabs.last?.path
            }
        }
    }

    /// Opens a path in a tab, or selects its open tab: a new tab goes right after the selected
    /// tab (docs/code-editor.md › Editor tabs, Order). Returns the tab's buffer.
    @MainActor
    @discardableResult
    mutating func openEditorTab(_ path: String) -> EditorBuffer {
        if let tab = editorTabs.first(where: { $0.path == path }) {
            selectedEditorPath = path
            return tab.buffer
        }
        let tab = EditorTabState(path: path)
        if let selected = selectedEditorPath, let index = editorTabs.firstIndex(where: { $0.path == selected }) {
            editorTabs.insert(tab, at: index + 1)
        } else {
            editorTabs.append(tab)
        }
        selectedEditorPath = path
        return tab.buffer
    }
}
