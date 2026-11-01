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

// SHIM(core-claude): delete at integration — not in the cross-key contracts; ui.open needs the
// driving device of a chat (docs/engine-api.md › Chat metadata in the API).
extension ChatManager {
    /// The device id of the user that last drove the chat since the engine started; nil when
    /// unknown.
    func drivingDevice(of chatID: ChatID) -> String? {
        nil
    }
}

// SHIM(core-claude): delete at integration — not in the cross-key contracts.
extension Engine {
    /// `projects.remove` and the deletion of a project file terminate the Claude processes of
    /// the chats of the removed projects: SIGTERM, then SIGKILL 5 s later (docs/chats.md ›
    /// Idle termination and quitting). Called after the chats left `domain`.
    func terminateChatProcesses(_ chatIDs: [ChatID]) async {}

    /// Chat metadata was loaded with a project (at launch, by projects.open or projects.create,
    /// or when a project file appears): the transcripts are replayed once to find incomplete
    /// question sets and to cancel pending permission requests (docs/data-model.md › Loading,
    /// step 4).
    func chatsDidLoad(_ chatIDs: [ChatID]) {}
}

// SHIM(core-files): delete at integration — not in the cross-key contracts.
extension Engine {
    /// The registered top-level project roots changed (`domain.registeredRootPaths()`): the
    /// FSEvents streams follow them (docs/data-model.md › Watching).
    func watchedProjectRootsDidChange() async {}
}
