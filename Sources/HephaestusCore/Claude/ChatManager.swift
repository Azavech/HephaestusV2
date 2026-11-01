import Foundation

/// The chats at runtime: Claude chat processes, their stream-json mapping and control protocol,
/// the computed `state` of each chat, pending permission requests, question sets, driving
/// devices, the chat tokens of each launch and idle termination (docs/chats.md). Used only on the
/// engine actor; the chat metadata files are loaded with their project (`DomainState`).
// DOC-GAP: the docs describe this work but name no Swift type for it; the type name is a
// design choice.
// STUB: core-claude — launch, command line, MCP configuration file, user messages, stop,
// idle termination, signals, exit handling, output mapping, permissions, questions, naming
// requests and persistence of docs/chats.md.
final class ChatManager {
    init() {}
}

extension Engine {
    /// docs/architecture.md › Shutdown, step 1 for chat processes: the quit items of
    /// docs/chats.md › Idle termination and quitting are written first, then every process group
    /// gets SIGTERM, then SIGKILL 3 s later; returns once every process has ended.
    // STUB: core-claude
    func stopChatProcesses() async {}

    /// `settings.update` moved the MCP server to another port: chat processes launched with the
    /// old port are terminated, at once when idle, otherwise when their turn ends
    /// (docs/mcp.md › Server lifecycle).
    // STUB: core-claude
    func mcpPortDidChange() async {}
}
