// OWNER: ui-code-docs — the docs of a project's docs folder, loaded with docs.list and reloaded on
// files.changed and docsPath changes (docs/documentation-viewer.md › Docs folder, › Docs tree).
import Foundation
import HephaestusCore
import Observation

/// The docs of one project's docs folder in one window.
@MainActor @Observable
final class DocsTreeModel {
    let projectID: String
    /// The `docs.list` result; nil until loaded.
    private(set) var docs: [DocEntry]?
    /// False when the docs folder does not exist.
    private(set) var folderExists = true
    /// The failure of the last `docs.list`.
    private(set) var error: String?
    private(set) var isLoading = false
    /// The selected row of the tree: a doc or a folder (project paths).
    var treeSelection: String?
    @ObservationIgnored private(set) weak var workspace: DeviceWorkspace?
    @ObservationIgnored private weak var window: WindowState?
    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored nonisolated(unsafe) private var tasks: [Task<Void, Never>] = []

    init(workspace: DeviceWorkspace, projectID: String, window: WindowState) {
        self.workspace = workspace
        self.projectID = projectID
        self.window = window
        let events = workspace.events()
        tasks.append(Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                if case .filesChanged(let payload) = event.event, payload.projectID == self.projectID,
                   Self.reloads(changed: payload.paths, docsPath: self.docsPath) {
                    self.reload()
                }
            }
        })
        // `project.updated` changing `docsPath`, and a reconnection, reload the list.
        let start = workspace.connectionGeneration
        let initialPath = docsPath
        let changes = Observations { [weak workspace] in
            "\(workspace?.connectionGeneration ?? start)\u{0}\(workspace?.details[projectID]?.project.docsPath ?? initialPath)"
        }
        let initial = "\(start)\u{0}\(initialPath)"
        tasks.append(Task { @MainActor [weak self] in
            for await value in changes where value != initial {
                self?.reload()
            }
        })
    }

    deinit {
        for task in tasks {
            task.cancel()
        }
    }

    func stop() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    /// The project's `docsPath`, a project path without a final `/`.
    var docsPath: String {
        let path = workspace?.details[projectID]?.project.docsPath ?? "docs"
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// A doc path relative to the docs folder; the project path when it lies outside.
    func relativePath(_ path: String) -> String {
        let folder = docsPath
        if folder.isEmpty { return path }
        if path.hasPrefix(folder + "/") { return String(path.dropFirst(folder.count + 1)) }
        return path
    }

    /// The tree reloads when a `files.changed` event of the project contains `""`, a path under
    /// the docs folder, the docs folder itself, or a folder that contains the docs folder.
    static func reloads(changed: [String], docsPath: String) -> Bool {
        changed.contains { path in
            path.isEmpty || path == docsPath || path.hasPrefix(docsPath + "/") || docsPath.hasPrefix(path + "/") || docsPath.isEmpty
        }
    }

    func ensureLoaded() {
        guard docs == nil, error == nil, !isLoading else { return }
        reload()
    }

    /// `docs.list` under the replay rule; an empty list checks whether the folder exists.
    func reload() {
        guard let workspace else { return }
        guard !isLoading else {
            reloadRequested = true
            return
        }
        isLoading = true
        let projectID = self.projectID
        let folder = docsPath
        Task { @MainActor [weak self] in
            do {
                let list = try await workspace.seed({
                    try await workspace.call(DocsList.self, DocsList.Params(projectID: projectID))
                }, replace: { list in
                    self?.docs = list
                    self?.error = nil
                }, replay: { event in
                    if case .filesChanged(let payload) = event.event, payload.projectID == projectID,
                       Self.reloads(changed: payload.paths, docsPath: folder) {
                        self?.reloadRequested = true
                    }
                })
                if list.isEmpty {
                    // `docs.list` gives an empty list for a missing folder too; `files.list` of
                    // the folder tells the two cases apart, notFound or invalid meaning no folder
                    // (docs/documentation-viewer.md › Empty states).
                    do {
                        _ = try await workspace.call(FilesList.self, FilesList.Params(projectID: projectID, path: folder))
                        self?.folderExists = true
                    } catch let error as EngineError where error.code == .notFound || error.code == .invalid {
                        self?.folderExists = false
                    } catch {
                        self?.folderExists = true
                    }
                } else {
                    self?.folderExists = true
                }
            } catch {
                self?.error = errorMessage(error)
            }
            guard let self else { return }
            self.isLoading = false
            if self.reloadRequested || folder != self.docsPath {
                self.reloadRequested = false
                self.reload()
            }
        }
    }

    // MARK: Tree (docs/documentation-viewer.md › Docs tree)

    private final class Folder {
        let path: String
        var folders: [String: Folder] = [:]
        var docs: [DocEntry] = []

        init(path: String) {
            self.path = path
        }
    }

    /// The folder rows (project paths) that contain at least one doc.
    var folderPaths: Set<String> {
        var result = Set<String>()
        for doc in docs ?? [] {
            var current = ProjectPaths.parent(of: doc.path)
            while !current.isEmpty, current != docsPath, ProjectPaths.isSameOrDescendant(current, of: docsPath) {
                result.insert(current)
                current = ProjectPaths.parent(of: current)
            }
        }
        return result
    }

    /// The number of docs under a folder.
    func docCount(under folder: String) -> Int {
        (docs ?? []).filter { $0.path.hasPrefix(folder + "/") }.count
    }

    /// One row per doc and one per folder that contains at least one doc. Sub folders first, then
    /// docs; a doc named `README.md` (any case) first among the docs; the rest of each group by
    /// name in Finder order.
    func rows(expanded: Set<String>) -> [OutlineRow] {
        let base = docsPath
        let root = Folder(path: base)
        for doc in docs ?? [] {
            let relative = relativePath(doc.path)
            var folder = root
            for component in relative.split(separator: "/").dropLast() {
                let path = ProjectPaths.join(folder.path, String(component))
                if let existing = folder.folders[String(component)] {
                    folder = existing
                } else {
                    let created = Folder(path: path)
                    folder.folders[String(component)] = created
                    folder = created
                }
            }
            folder.docs.append(doc)
        }
        return rows(of: root, expanded: expanded)
    }

    private func rows(of folder: Folder, expanded: Set<String>) -> [OutlineRow] {
        let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> OutlineRow in
            let child = folder.folders[name]!
            return OutlineRow(id: child.path, title: name, symbol: "folder", kind: .folder,
                              children: expanded.contains(child.path) ? rows(of: child, expanded: expanded) : [])
        }
        let docs = folder.docs.sorted { a, b in
            let nameA = ProjectPaths.name(of: a.path)
            let nameB = ProjectPaths.name(of: b.path)
            let readmeA = nameA.lowercased() == "readme.md"
            let readmeB = nameB.lowercased() == "readme.md"
            if readmeA != readmeB { return readmeA }
            return nameA.localizedStandardCompare(nameB) == .orderedAscending
        }.map { doc in
            OutlineRow(id: doc.path, title: doc.title, symbol: "doc.text", kind: .item, tooltip: relativePath(doc.path))
        }
        return folders + docs
    }

    /// The folder rows above a doc, outermost first.
    func folders(above path: String) -> [String] {
        ProjectPaths.ancestors(of: path).filter { $0 != docsPath && ProjectPaths.isSameOrDescendant($0, of: docsPath) && !docsPath.hasPrefix($0 + "/") }
    }
}
