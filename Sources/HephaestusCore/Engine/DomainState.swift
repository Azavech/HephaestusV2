import Foundation

/// The device data the engine keeps in memory: the registry, the loaded projects with their
/// tickets, bundles and chat metadata (docs/data-model.md › Loading, docs/architecture.md ›
/// Startup step 4). It lives on the engine actor; handlers read and change it with no `await`
/// between the read and the write (docs/architecture.md › Concurrency). The engine API answers
/// from this state, except for transcripts, attachments and the project's other files.
// DOC-GAP: the docs assign no type or folder to the in-memory project data; it is engine state,
// so it lives in `Engine/`. Chat metadata is loaded with its project here; the runtime state of
// chats (processes, `state`, pending requests, driving devices) belongs to `ChatManager`.
struct DomainState {
    /// `registry.yml` as last loaded or written.
    var registry: Registry
    /// The loaded projects and sub projects, by identifier.
    private(set) var projects: [ProjectID: LoadedProject] = [:]
    /// Loaded project by standardized root path.
    private var rootIndex: [String: ProjectID] = [:]
    /// The project that holds each loaded chat.
    private var chatIndex: [ChatID: ProjectID] = [:]
    /// Tickets whose Haiku naming is pending, with their provisional title.
    var pendingTicketNames: [TicketID: String] = [:]
    /// Bundles whose Haiku naming is pending, with their provisional title.
    var pendingBundleNames: [BundleID: String] = [:]
    /// Where removed ticket, bundle and attachment files go (docs/data-model.md › Atomic writes).
    var trash: any DomainTrash = SystemTrash()
    /// The `git` executable for `ProjectDetail.gitRemoteURL`, looked up on first use.
    var gitExecutable: GitExecutable = .notLookedUp
    /// True once the engine stops: background naming answers are not written anymore.
    var isStopped = false

    init(registry: Registry) {
        self.registry = registry
    }

    // MARK: Cross-key accessors (parallel-rules › Cross-key contracts)

    /// True when a loaded project has this identifier.
    func isLoaded(_ projectID: ProjectID) -> Bool {
        projects[projectID] != nil
    }

    /// The content of a loaded project's project.yml.
    func project(_ id: ProjectID) -> Project? {
        projects[id]?.project
    }

    /// The root folder of a loaded project.
    func projectRoot(_ id: ProjectID) -> URL? {
        projects[id].map { URL(fileURLWithPath: $0.rootPath, isDirectory: true) }
    }

    /// Every loaded project and sub project in depth-first order: the top-level projects in
    /// registry.yml order, each followed by its descendants in `subprojects` order.
    func loadedProjectIDs() -> [ProjectID] {
        var result: [ProjectID] = []
        func visit(_ id: ProjectID) {
            result.append(id)
            for child in childIDs(of: id) {
                visit(child)
            }
        }
        for id in topLevelIDs() {
            visit(id)
        }
        return result
    }

    /// A loaded ticket.
    func ticket(_ id: TicketID) -> Ticket? {
        guard let projectID = Identifiers.projectID(of: id) else { return nil }
        return projects[projectID]?.tickets[id]
    }

    /// The loaded tickets of a project, not those of its sub projects, by ticket number.
    func tickets(of projectID: ProjectID) -> [Ticket] {
        (projects[projectID]?.tickets.values).map { $0.sorted { DomainState.number(of: $0.id) < DomainState.number(of: $1.id) } } ?? []
    }

    /// A loaded bundle.
    func bundle(_ id: BundleID) -> TicketBundle? {
        guard let projectID = Identifiers.projectID(of: id) else { return nil }
        return projects[projectID]?.bundles[id]
    }

    /// The loaded bundles of a project, by bundle number.
    func bundles(of projectID: ProjectID) -> [TicketBundle] {
        (projects[projectID]?.bundles.values).map { $0.sorted { DomainState.number(of: $0.id) < DomainState.number(of: $1.id) } } ?? []
    }

    /// The metadata of a loaded chat, with its `projectID`; `state` is the stored value
    /// (`idle`): the runtime state comes from `ChatManager`.
    func chat(_ id: ChatID) -> ChatMeta? {
        guard let projectID = chatIndex[id] else { return nil }
        return projects[projectID]?.chats[id]
    }

    /// The loaded chats of a project, all kinds, by `updated` descending.
    func chats(of projectID: ProjectID) -> [ChatMeta] {
        (projects[projectID]?.chats.values).map {
            $0.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id.uuidString < $1.id.uuidString }
        } ?? []
    }

    /// Adds or replaces the metadata of a chat in memory, in the project named by its
    /// `projectID` (nothing happens when that project is not loaded). The caller writes the file.
    mutating func upsertChat(_ meta: ChatMeta) {
        guard projects[meta.projectID] != nil else { return }
        if let previous = chatIndex[meta.id], previous != meta.projectID {
            projects[previous]?.chats[meta.id] = nil
        }
        projects[meta.projectID]?.chats[meta.id] = meta
        chatIndex[meta.id] = meta.projectID
    }

    /// Removes the metadata of a chat from memory. The caller moves the files to the Trash.
    mutating func removeChat(_ id: ChatID) {
        guard let projectID = chatIndex.removeValue(forKey: id) else { return }
        projects[projectID]?.chats[id] = nil
    }

    // MARK: Project tree

    /// The loaded project whose root is `rootPath` (standardized).
    func projectID(atRoot rootPath: String) -> ProjectID? {
        rootIndex[rootPath]
    }

    /// The top-level loaded projects, in registry.yml order.
    func topLevelIDs() -> [ProjectID] {
        var seen = Set<ProjectID>()
        var result: [ProjectID] = []
        for entry in registry.loadableEntries {
            guard let id = rootIndex[DomainPaths.standardize(entry)], projects[id]?.parentID == nil,
                  seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    /// The loaded direct sub projects of a project, in the order of its `subprojects`.
    func childIDs(of id: ProjectID) -> [ProjectID] {
        guard let parent = projects[id] else { return [] }
        var seen = Set<ProjectID>()
        var result: [ProjectID] = []
        for entry in parent.project.subprojects {
            guard let root = DomainPaths.subprojectRoot(parent: parent.rootPath, entry: entry),
                  let child = rootIndex[root], projects[child]?.parentID == id, seen.insert(child).inserted
            else { continue }
            result.append(child)
        }
        return result
    }

    /// The loaded descendants of a project in depth-first order, without the project itself.
    func descendants(of id: ProjectID) -> [ProjectID] {
        var result: [ProjectID] = []
        func visit(_ id: ProjectID) {
            for child in childIDs(of: id) {
                result.append(child)
                visit(child)
            }
        }
        visit(id)
        return result
    }

    /// The ancestors of a project, from its parent up to its top-level project.
    func ancestors(of id: ProjectID) -> [ProjectID] {
        var result: [ProjectID] = []
        var current = projects[id]?.parentID
        while let parent = current, !result.contains(parent) {
            result.append(parent)
            current = projects[parent]?.parentID
        }
        return result
    }

    /// The innermost loaded project whose root strictly contains `path`.
    func innermostProject(containing path: String) -> ProjectID? {
        var best: (id: ProjectID, length: Int)?
        for (root, id) in rootIndex where DomainPaths.isStrictlyInside(path, root) {
            if best == nil || root.count > best!.length {
                best = (id, root.count)
            }
        }
        return best?.id
    }

    /// The absolute root paths of the registered top-level projects, loaded or not, in registry
    /// order: the folders the file watcher follows (docs/data-model.md › Watching).
    func registeredRootPaths() -> [String] {
        var seen = Set<String>()
        return registry.loadableEntries.map(DomainPaths.standardize).filter { seen.insert($0).inserted }
    }

    // MARK: Summaries

    /// The number of tickets per status of a project.
    func ticketCounts(of id: ProjectID) -> TicketCounts {
        var counts = TicketCounts()
        for ticket in projects[id].map({ Array($0.tickets.values) }) ?? [] {
            switch ticket.status {
            case .todo: counts.todo += 1
            case .inProgress: counts.inProgress += 1
            case .done: counts.done += 1
            }
        }
        return counts
    }

    /// The ProjectSummary of a loaded project.
    func summary(_ id: ProjectID) -> ProjectSummary? {
        guard let loaded = projects[id] else { return nil }
        return ProjectSummary(id: id, name: loaded.project.name, rootPath: loaded.rootPath, parentID: loaded.parentID,
                              subprojectIDs: childIDs(of: id), ticketCounts: ticketCounts(of: id))
    }

    /// The `projects.list` result: every loaded project and sub project, depth first.
    func projectSummaries() -> [ProjectSummary] {
        loadedProjectIDs().compactMap(summary)
    }

    // MARK: Changes (the caller writes the files first)

    /// Adds a loaded project, or replaces the one with the same identifier.
    mutating func insert(_ loaded: LoadedProject) {
        if let previous = projects[loaded.project.id], previous.rootPath != loaded.rootPath {
            rootIndex[previous.rootPath] = nil
        }
        projects[loaded.project.id] = loaded
        rootIndex[loaded.rootPath] = loaded.project.id
        for id in loaded.chats.keys {
            chatIndex[id] = loaded.project.id
        }
    }

    /// Removes a loaded project from memory, with its tickets, bundles and chats; its sub projects
    /// stay (the caller removes them too).
    @discardableResult
    mutating func remove(_ id: ProjectID) -> LoadedProject? {
        guard let loaded = projects.removeValue(forKey: id) else { return nil }
        rootIndex[loaded.rootPath] = nil
        for chatID in loaded.chats.keys {
            chatIndex[chatID] = nil
        }
        for ticketID in loaded.tickets.keys {
            pendingTicketNames[ticketID] = nil
        }
        for bundleID in loaded.bundles.keys {
            pendingBundleNames[bundleID] = nil
        }
        return loaded
    }

    /// Replaces the project.yml content of a loaded project.
    mutating func setProject(_ project: Project) {
        projects[project.id]?.project = project
    }

    /// Changes the parent of a loaded project.
    mutating func setParent(_ parentID: ProjectID?, of id: ProjectID) {
        projects[id]?.parentID = parentID
    }

    /// Adds or replaces a loaded ticket; its file is no longer recorded as invalid.
    mutating func setTicket(_ ticket: Ticket) {
        guard let projectID = ticket.projectID, projects[projectID] != nil else { return }
        projects[projectID]?.tickets[ticket.id] = ticket
        projects[projectID]?.invalidTickets[ticket.id] = nil
    }

    /// Removes a loaded ticket.
    mutating func removeTicket(_ id: TicketID) {
        guard let projectID = Identifiers.projectID(of: id) else { return }
        projects[projectID]?.tickets[id] = nil
        pendingTicketNames[id] = nil
    }

    /// Records why a ticket file of a project does not load; nil forgets it.
    mutating func setInvalidTicket(_ id: TicketID, reason: String?) {
        guard let projectID = Identifiers.projectID(of: id) else { return }
        projects[projectID]?.invalidTickets[id] = reason
    }

    /// Why the file of a ticket that is not loaded cannot be read, when it is recorded.
    func invalidTicketReason(_ id: TicketID) -> String? {
        guard let projectID = Identifiers.projectID(of: id) else { return nil }
        return projects[projectID]?.invalidTickets[id]
    }

    /// Adds or replaces a loaded bundle.
    mutating func setBundle(_ bundle: TicketBundle) {
        guard let projectID = bundle.projectID, projects[projectID] != nil else { return }
        projects[projectID]?.bundles[bundle.id] = bundle
    }

    /// Removes a loaded bundle.
    mutating func removeBundle(_ id: BundleID) {
        guard let projectID = Identifiers.projectID(of: id) else { return }
        projects[projectID]?.bundles[id] = nil
        pendingBundleNames[id] = nil
    }

    /// The number of a well-formed ticket or bundle id.
    static func number(of id: String) -> Int {
        Identifiers.parseTicketID(id)?.number ?? Identifiers.parseBundleID(id)?.number ?? Int.max
    }
}

/// One loaded project or sub project with its data.
struct LoadedProject {
    /// The content of project.yml.
    var project: Project
    /// Standardized absolute path of the root folder.
    var rootPath: String
    /// The parent, for a sub project.
    var parentID: ProjectID?
    var tickets: [TicketID: Ticket] = [:]
    var bundles: [BundleID: TicketBundle] = [:]
    /// Chat metadata, with `projectID` set and the stored `state`.
    var chats: [ChatID: ChatMeta] = [:]
    /// Ticket files of this project that never loaded or are invalid and not loaded, with the
    /// reason (`tickets.get` fails with `internal` for them, docs/tickets.md › Live updates).
    var invalidTickets: [TicketID: String] = [:]

    /// The `.hephaestus/` folder of the project.
    var folder: ProjectFolder {
        ProjectFolder(root: URL(fileURLWithPath: rootPath, isDirectory: true))
    }
}

/// The lookup state of the `git` executable (docs/architecture.md › Child processes, rule 5).
enum GitExecutable: Equatable {
    case notLookedUp
    case missing
    case found(String)
}

/// Lexical path rules of docs/engine-api.md › Paths for absolute paths and sub project entries.
enum DomainPaths {
    /// Standardizes an absolute path: `.` components removed, `..` components resolved,
    /// repeated and trailing `/` removed; symbolic links are not resolved.
    static func standardize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True when `path` lies strictly inside the folder `root` (both standardized).
    static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        if root == "/" { return path != "/" && path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    /// The path of `path` relative to `root`, for a path strictly inside it.
    static func relative(_ path: String, to root: String) -> String {
        root == "/" ? String(path.dropFirst()) : String(path.dropFirst(root.count + 1))
    }

    /// The root of a sub project entry: the parent root joined with the relative entry; nil when
    /// the entry is not a relative path of docs/data-model.md › Paths.
    static func subprojectRoot(parent: String, entry: String) -> String? {
        guard ModelRules.isRelativePath(entry) else { return nil }
        return parent == "/" ? "/" + entry : parent + "/" + entry
    }

    /// True when a standardized absolute path has a `.hephaestus` component.
    static func hasDataFolderComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains(".hephaestus")
    }

    /// A project path received from a client (docs/engine-api.md › Paths): a trailing `/` is
    /// removed first; then `/` separators, no leading `/` and no `.`, `..` or empty component.
    /// Returns nil when the path breaks a rule; `""` is the root.
    static func projectPath(_ value: String) -> String? {
        var path = value
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        if path.isEmpty { return "" }
        return ModelRules.isRelativePath(path) ? path : nil
    }
}
