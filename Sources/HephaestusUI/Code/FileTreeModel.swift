// OWNER: ui-code-docs — the listings of the file tree, loaded lazily with files.list and refreshed
// on files.changed (docs/code-editor.md › File tree).
import Foundation
import HephaestusCore
import HephaestusText
import Observation

/// The refresh rule of the file tree (docs/code-editor.md › File tree, Refresh).
enum FileTreeRefresh {
    /// The listed folders to list again after a `files.changed` event: every listed folder when
    /// the paths contain `""`; otherwise each listed folder that is the parent of a changed path,
    /// is itself a changed path, or lies under a changed path.
    static func foldersToRelist(listed: Set<String>, changed: [String]) -> Set<String> {
        if changed.contains("") { return listed }
        return listed.filter { folder in
            changed.contains { path in
                ProjectPaths.parent(of: path) == folder || path == folder || folder.hasPrefix(path + "/")
            }
        }
    }
}

/// The folders of one project's file tree in one window: listings by folder project path (`""`
/// for the root), the listings in flight and the failures.
@MainActor @Observable
final class FileTreeModel {
    /// The engine's maximum number of entries of one listing.
    static let maximumEntries = 10_000

    let projectID: String
    private(set) var listings: [String: [FileEntry]] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private(set) weak var workspace: DeviceWorkspace?
    @ObservationIgnored private weak var window: WindowState?
    @ObservationIgnored private var relistRequested: Set<String> = []
    @ObservationIgnored nonisolated(unsafe) private var tasks: [Task<Void, Never>] = []

    init(workspace: DeviceWorkspace, projectID: String, window: WindowState) {
        self.workspace = workspace
        self.projectID = projectID
        self.window = window
        let events = workspace.events()
        tasks.append(Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                if case .filesChanged(let payload) = event.event, payload.projectID == self.projectID {
                    self.refresh(changed: payload.paths)
                }
            }
        })
        let start = workspace.connectionGeneration
        let generations = Observations { [weak workspace] in workspace?.connectionGeneration ?? start }
        tasks.append(Task { @MainActor [weak self] in
            for await generation in generations where generation > start {
                // After a reconnect, the lists a window shows are loaded again.
                self?.refresh(changed: [""])
            }
        })
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }

    /// Stops following the engine.
    func stop() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    /// Lists a folder the first time it is shown.
    func ensureListed(_ folder: String) {
        guard listings[folder] == nil, errors[folder] == nil, !loading.contains(folder) else { return }
        list(folder)
    }

    /// Lists a folder again (Try Again of a failed listing).
    func retry(_ folder: String) {
        errors[folder] = nil
        list(folder)
    }

    /// True when the folder is known as a listed folder.
    func isListed(_ folder: String) -> Bool {
        listings[folder] != nil
    }

    /// The entry at a path, when its folder is listed.
    func entry(at path: String) -> FileEntry? {
        listings[ProjectPaths.parent(of: path)]?.first { $0.path == path }
    }

    private func refresh(changed: [String]) {
        let listed = Set(listings.keys).union(errors.keys)
        for folder in FileTreeRefresh.foldersToRelist(listed: listed, changed: changed) {
            list(folder)
        }
    }

    /// `files.list` under the replay rule: an event recorded while the listing runs lists the
    /// folder again once the result is stored.
    private func list(_ folder: String) {
        guard let workspace else { return }
        guard !loading.contains(folder) else {
            relistRequested.insert(folder)
            return
        }
        loading.insert(folder)
        let projectID = self.projectID
        Task { @MainActor [weak self] in
            do {
                try await workspace.seed({
                    try await workspace.call(FilesList.self, FilesList.Params(projectID: projectID, path: folder))
                }, replace: { entries in
                    self?.store(entries, in: folder)
                }, replay: { event in
                    if case .filesChanged(let payload) = event.event, payload.projectID == projectID,
                       !FileTreeRefresh.foldersToRelist(listed: [folder], changed: payload.paths).isEmpty {
                        self?.relistRequested.insert(folder)
                    }
                })
            } catch let error as EngineError where error.code == .notFound && !folder.isEmpty {
                self?.forget(folder)
            } catch {
                self?.errors[folder] = errorMessage(error)
                self?.listings[folder] = nil
            }
            guard let self else { return }
            self.loading.remove(folder)
            if self.relistRequested.remove(folder) != nil {
                self.list(folder)
            }
        }
    }

    private func store(_ entries: [FileEntry], in folder: String) {
        listings[folder] = entries
        errors[folder] = nil
        // Expansion and selection are kept for paths that still exist.
        let existing = Set(entries.map(\.path))
        let folders = Set(entries.filter(\.isDirectory).map(\.path))
        for path in listings.keys where ProjectPaths.parent(of: path) == folder && !path.isEmpty && !folders.contains(path) {
            forget(path)
        }
        guard let window else { return }
        window.updateViewState(of: projectID) { state in
            state.expandedCodeFolders = state.expandedCodeFolders.filter { path in
                ProjectPaths.parent(of: path) != folder || folders.contains(path)
            }
            if let selected = state.selectedTreePath, ProjectPaths.parent(of: selected) == folder, !existing.contains(selected) {
                state.selectedTreePath = nil
            }
        }
    }

    /// A folder that no longer exists: its listing and the listings below it are dropped.
    private func forget(_ folder: String) {
        for path in listings.keys where ProjectPaths.isSameOrDescendant(path, of: folder) {
            listings[path] = nil
        }
        for path in errors.keys where ProjectPaths.isSameOrDescendant(path, of: folder) {
            errors[path] = nil
        }
    }

    // MARK: Rows

    /// The SF Symbol of a file: `swift` for `.swift`, `doc.text` for the other text languages of
    /// Language detection, `photo` for image types, `doc` for the rest.
    static func symbol(forFileNamed name: String) -> String {
        let language = SyntaxHighlighter.language(forFileName: name, firstLine: nil)
        if language == .swift { return "swift" }
        if language != .plain { return "doc.text" }
        if ProjectPaths.isImageName(name) { return "photo" }
        return "doc"
    }

    /// The rows of a listed folder, with the rows of its expanded sub folders.
    func rows(of folder: String, expanded: Set<String>) -> [OutlineRow] {
        if let error = errors[folder] {
            return [OutlineRow(id: "\u{1}error:" + folder, title: error, kind: .message)]
        }
        guard let entries = listings[folder] else { return [] }
        if entries.isEmpty {
            return [OutlineRow(id: "\u{1}empty:" + folder, title: "Empty", kind: .message)]
        }
        var rows = entries.map { entry -> OutlineRow in
            if entry.isDirectory {
                return OutlineRow(id: entry.path, title: entry.name, symbol: "folder", kind: .folder,
                                  isDimmed: entry.isIgnored == true, isLoading: loading.contains(entry.path),
                                  children: expanded.contains(entry.path) ? rows(of: entry.path, expanded: expanded) : [])
            }
            return OutlineRow(id: entry.path, title: entry.name, symbol: Self.symbol(forFileNamed: entry.name), kind: .item,
                              isDimmed: entry.isIgnored == true)
        }
        if entries.count >= Self.maximumEntries {
            rows.append(OutlineRow(id: "\u{1}truncated:" + folder, title: "Only the first 10,000 items are shown.", kind: .message))
        }
        return rows
    }

    /// The expanded folders that can be seen: those whose ancestors are all expanded.
    func visibleExpandedFolders(_ expanded: Set<String>) -> [String] {
        expanded.filter { path in
            ProjectPaths.ancestors(of: path).allSatisfy { expanded.contains($0) }
        }.sorted()
    }
}

/// The per-window state of the Code and Docs sections that is not part of `ProjectViewState`:
/// tree listings, menu command handlers and the fragment a doc link scrolls to. Entries live while
/// their window is open.
@MainActor
final class CodeDocsStore {
    static let shared = CodeDocsStore()

    struct Key: Hashable {
        var windowID: UUID
        var deviceID: String
        var projectID: String
    }

    @MainActor
    final class Entry {
        weak var window: WindowState?
        var fileTree: FileTreeModel?
        var docsTree: DocsTreeModel?
        var codeCommands: CodeSectionCommands?
        var docsCommands: DocsSectionCommands?
        /// The pane widths of the sections.
        let layout = SectionLayout()
        /// The fragment the preview scrolls to once the doc at `path` is rendered.
        var pendingFragment: (path: String, fragment: String)?
        /// The Docs section's preview while it is shown.
        weak var preview: DocPreviewController?

        init(window: WindowState) {
            self.window = window
        }

        func stop() {
            fileTree?.stop()
            docsTree?.stop()
        }

        /// The fragment of a `doc` target once its doc is selected (docs/documentation-viewer.md ›
        /// Opening a doc, step 3): a preview that shows the doc rendered scrolls at once;
        /// otherwise the next rendering of the doc scrolls. Without a fragment, or with an empty
        /// one, an earlier fragment that did not scroll yet is dropped.
        func applyDocTarget(path: String, fragment: String?) {
            guard let fragment, !fragment.isEmpty else {
                pendingFragment = nil
                return
            }
            if let preview, preview.showsRendered(path) {
                pendingFragment = nil
                preview.scroll(to: fragment)
            } else {
                pendingFragment = (path, fragment)
            }
        }
    }

    private var entries: [Key: Entry] = [:]

    func entry(window: WindowState, projectID: String) -> Entry {
        prune()
        let key = Key(windowID: window.id, deviceID: window.deviceID, projectID: projectID)
        if let entry = entries[key] { return entry }
        let entry = Entry(window: window)
        entries[key] = entry
        return entry
    }

    /// The file tree of a project in a window.
    func fileTree(window: WindowState, workspace: DeviceWorkspace, projectID: String) -> FileTreeModel {
        let entry = entry(window: window, projectID: projectID)
        if let tree = entry.fileTree, tree.workspace === workspace { return tree }
        entry.fileTree?.stop()
        let tree = FileTreeModel(workspace: workspace, projectID: projectID, window: window)
        entry.fileTree = tree
        return tree
    }

    /// The docs tree of a project in a window.
    func docsTree(window: WindowState, workspace: DeviceWorkspace, projectID: String) -> DocsTreeModel {
        let entry = entry(window: window, projectID: projectID)
        if let tree = entry.docsTree, tree.workspace === workspace { return tree }
        entry.docsTree?.stop()
        let tree = DocsTreeModel(workspace: workspace, projectID: projectID, window: window)
        entry.docsTree = tree
        return tree
    }

    /// Drops the entries of closed windows.
    private func prune() {
        for (key, entry) in entries where entry.window == nil {
            entry.stop()
            entries[key] = nil
        }
    }
}
