import Foundation

// Shims of members other keys provide; each block is deleted at integration, when the owner's
// implementation is merged.

// SHIM(core-domain): delete at integration — the DomainState accessors of the cross-key
// contracts that search and skills call.
extension DomainState {
    func project(_ id: ProjectID) -> Project? { nil }
    func projectRoot(_ id: ProjectID) -> URL? { nil }
    func loadedProjectIDs() -> [ProjectID] { [] }
    func tickets(of projectID: ProjectID) -> [Ticket] { [] }
    func bundles(of projectID: ProjectID) -> [TicketBundle] { [] }
    func chats(of projectID: ProjectID) -> [ChatMeta] { [] }
}

// SHIM(core-domain): delete at integration — not among the cross-key contracts; skills.setEnabled,
// a rename and a delete change the `skills` list of loaded projects (docs/skills.md › Engine API).
// Contract: writes project.yml of a loaded project atomically and records the write as the
// engine's own (docs/data-model.md › Atomic writes), replaces the in-memory project, emits
// project.updated with `origin`, and returns that ProjectDetail; throws EngineError (`internal`
// when the file cannot be written).
extension Engine {
    func saveProject(_ project: Project, origin: Actor) throws -> ProjectDetail {
        throw EngineError.notImplemented("Saving a project")
    }
}

// SHIM(core-claude): delete at integration — not among the cross-key contracts; code search runs
// `git` found by the tools lookup with the login-shell environment (docs/architecture.md › Child
// processes, rules 1 and 5). Nil until the capture and the lookup are done, or without git.
extension ClaudeCLI {
    var loginEnvironment: [String: String]? { nil }
    var gitPath: String? { nil }
}
