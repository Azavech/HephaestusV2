import Foundation

// Seams the project data engine calls that other keys implement. Each has a minimal body here
// until integration (parallel-rules › Cross-key contracts, Shims).

// SHIM(core-claude): delete at integration — cross-key contract `ChatManager.state(of:)`.
extension ChatManager {
    /// The runtime state of a chat; `idle` for chats with no process.
    func state(of chatID: ChatID) -> ChatState {
        .idle
    }
}

// SHIM(core-claude): delete at integration — the driving device of a chat, for ui.open
// (docs/engine-api.md › Chat metadata in the API).
extension ChatManager {
    /// The device id of the user that last drove the chat since the engine started; nil when
    /// unknown.
    func drivingDeviceID(of chatID: ChatID) -> String? {
        nil
    }
}

// SHIM(core-claude): delete at integration.
extension Engine {
    /// `projects.remove` and the unloading of projects terminate the Claude processes of their
    /// chats: SIGTERM, then SIGKILL 5 s later (docs/chats.md › Idle termination and quitting).
    /// Called after the projects left `domain`.
    func terminateChatProcesses(inProjects projectIDs: [ProjectID]) async {}

    /// A project loaded after startup (projects.create, projects.open, a project file that
    /// appeared): its transcripts are replayed once to find incomplete question sets and to
    /// cancel pending permission requests (docs/data-model.md › Loading, step 4).
    func scanChatTranscripts(of projectID: ProjectID) async {}

    /// The environment of child processes: the login-shell environment captured at launch,
    /// without any `HEPHAESTUS_*` variable (docs/architecture.md › Child processes, rule 1).
    func childProcessEnvironment() async -> [String: String] {
        appEnvironmentForTools()
    }
}

// SHIM(core-files): delete at integration — not in the cross-key contracts.
extension Engine {
    /// The registered top-level project roots changed (`domain.registeredRootPaths()`): the
    /// FSEvents streams follow them (docs/data-model.md › Watching).
    func watchedProjectRootsDidChange() async {}
}
