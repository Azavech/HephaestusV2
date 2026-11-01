import Foundation

/// Starts Claude CLI processes for the engine: the real CLI in the app, an in-memory fake that
/// replays fixture lines in tests (docs/architecture.md › Engine configuration).
// DOC-GAP: the docs name `ClaudeProcessLauncher` and its two implementations but not its
// members. The requirements are added with the Claude CLI integration (docs/chats.md); stage 1
// declares the protocol so that `EngineConfiguration` is complete.
public protocol ClaudeProcessLauncher: Sendable {}

/// The launcher of the app: starts the real Claude CLI.
// STUB: claude — the process start is implemented with the Claude CLI integration.
public struct SystemClaudeProcessLauncher: ClaudeProcessLauncher {
    public init() {}
}
