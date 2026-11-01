import Foundation

/// The Claude CLI of the device: the login-shell environment, the tools lookup, the location of
/// the CLI, its `ClaudeStatus` and the model list (docs/chats.md › Claude CLI). Used only on the
/// engine actor.
// DOC-GAP: the docs describe this work but name no Swift type for it; the type name is a
// design choice.
// STUB: core-claude — the environment capture, CLI location (docs/chats.md › Locating the CLI),
// `--version`, the models probe and the `claude.updated` events.
final class ClaudeCLI {
    /// The current status: `checking` from engine start until the CLI has been located and
    /// `--version` has answered.
    var status = ClaudeStatus.detecting
    /// The `claude.models` result: the fallback list until the first `initialize` response.
    var models = ClaudeCLI.fallbackModels

    init() {}

    /// docs/chats.md › Models: the list used until the first `initialize` response since the
    /// engine started, and while the CLI is unavailable.
    static let fallbackModels: [ClaudeModel] = {
        let efforts = Effort.allCases.map(\.rawValue)
        return [
            ClaudeModel(value: "default", displayName: "Default", description: "Recommended model", supportedEffortLevels: efforts),
            ClaudeModel(value: "opus", displayName: "Opus", description: "Best for everyday, complex tasks", supportedEffortLevels: efforts),
            ClaudeModel(value: "fable", displayName: "Fable", description: "Most capable for your hardest and longest-running tasks",
                        supportedEffortLevels: efforts),
            ClaudeModel(value: "sonnet", displayName: "Sonnet", description: "Efficient for routine tasks", supportedEffortLevels: efforts),
            ClaudeModel(value: "haiku", displayName: "Haiku", description: "Fastest for quick answers", supportedEffortLevels: efforts),
        ]
    }()
}

extension Engine {
    /// Startup step 7 of docs/architecture.md › Startup: the login-shell environment capture, then
    /// the lookup of the tools and the Claude CLI detection, which emits `claude.updated` when
    /// done, then the models probe. They run in child tasks; this returns at once.
    // STUB: core-claude — the detection never starts, so the status stays `checking`.
    func startClaudeBackgroundTasks() async {}

    /// The status `claude.status` returns: while a computation started at engine start or by a
    /// `claudePath` change is in progress, the current status with `checking` true, without
    /// starting another one; otherwise the status after locating the CLI again and running
    /// `--version` (docs/engine-api.md › claude.status).
    func claudeStatusForCall() async -> ClaudeStatus {
        if claudeCLI.status.checking {
            return claudeCLI.status
        }
        // STUB: core-claude — locate the CLI, run `--version`, emit `claude.updated` when the
        // status differs.
        return claudeCLI.status
    }

    /// `settings.update` changed `claudePath`: the status is computed again and `claude.updated`
    /// is emitted when it differs (docs/chats.md › Version and status).
    // STUB: core-claude
    func claudePathDidChange() async {}

    /// docs/architecture.md › Shutdown, step 1 for the models probe, the naming calls and the
    /// tools: SIGTERM, SIGKILL 3 s later; returns once they have ended.
    // STUB: core-claude
    func stopClaudeHelperProcesses() async {}
}
