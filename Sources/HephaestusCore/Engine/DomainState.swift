import Foundation

/// The device data the engine keeps in memory: the registry, the loaded projects with their
/// tickets, bundles and chat metadata (docs/data-model.md › Loading, docs/architecture.md ›
/// Startup step 4). It lives on the engine actor; handlers read and change it with no `await`
/// between the read and the write (docs/architecture.md › Concurrency).
// DOC-GAP: the docs assign no type or folder to the in-memory project data; it is engine state,
// so it lives in `Engine/`. Chat metadata is loaded with its project here; the runtime state of
// chats (processes, `state`, pending requests, driving devices) belongs to `ChatManager`.
// STUB: core-domain — loading, the project tree, the ticket, bundle and chat metadata maps and
// the reload rules of docs/data-model.md › External changes.
struct DomainState {
    /// `registry.yml` as loaded at launch.
    var registry: Registry

    init(registry: Registry) {
        self.registry = registry
    }

    /// True when a loaded project has this identifier.
    // STUB: core-domain — no project is loaded yet.
    func isLoaded(_ projectID: ProjectID) -> Bool {
        false
    }

    /// The `projects.list` result: every loaded project and sub project, depth first.
    // STUB: core-domain — no project is loaded yet.
    func projectSummaries() -> [ProjectSummary] {
        []
    }
}

extension Engine {
    /// Startup step 4 of docs/architecture.md › Startup: loads every registered project, its sub
    /// projects, tickets, bundles and chat metadata (docs/data-model.md › Loading, steps 3 to 5).
    // STUB: core-domain
    func loadProjects() async {}
}
