import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Claude CLI: location, version, status, models and the environment, through
/// `LocalEngineConnection` with the in-memory launcher.
@Suite("Claude CLI status")
struct ClaudeStatusTests {
    @Test("The CLI found by the login shell is available, with its version; the probe gives the models")
    func available() async throws {
        try await withChatEngine { bed in
            let status = try await bed.connection.call(ClaudeStatusMethod.self)
            #expect(status == ClaudeStatus(available: true, path: "/fake/bin/claude", version: "2.1.309", checking: false))
            let updated = await bed.events.wait(for: "claude.updated") { (try? $0.payload(ClaudeUpdatedEvent.self))?.status.available == true }
            #expect(updated != nil)
            // The models probe ran in Runtime/claude-cwd/ with the probe flags.
            let probe = await bed.launcher.process { $0.arguments.contains("--no-session-persistence") && !$0.arguments.contains("--system-prompt") }
            #expect(probe?.request.currentDirectory == bed.dataDirectory.claudeWorkingDirectory.path)
            #expect(probe?.request.arguments == ClaudeCLI.probeArguments())
            _ = await bed.events.wait(for: "claude.updated") { (try? $0.payload(ClaudeUpdatedEvent.self))?.models.count ?? 0 > 5 }
            let models = try await bed.connection.call(ClaudeModels.self)
            #expect(models.first?.displayName == "Default (recommended)")
            #expect(models.map(\.value).contains("claude-haiku-4-5-20251001"))
            #expect(probe?.isInputClosed == true)
        }
    }

    @Test("Detection: a claudePath that is not executable stops the search")
    func settingNotExecutable() async throws {
        let launcher = FakeClaudeLauncher()
        try await withChatEngine(launcher: launcher, settings: HostSettings(claudePath: "~/bin/claude")) { bed in
            let status = await bed.engine.currentClaudeStatus
            #expect(status == ClaudeStatus(available: false, path: "/Users/example/bin/claude",
                                           error: "/Users/example/bin/claude is not an executable file.", checking: false))
            #expect(!launcher.started.contains { $0.request.executable == "/bin/zsh" })
            // While unavailable, claude.models is the fallback list.
            let models = try await bed.connection.call(ClaudeModels.self)
            #expect(models == ClaudeCLI.fallbackModels)
        }
    }

    @Test("Detection: the standard candidates come before the login shell")
    func standardCandidate() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.executables = ["/opt/homebrew/bin/claude"]
        try await withChatEngine(launcher: launcher) { bed in
            #expect(await bed.engine.currentClaudeStatus.path == "/opt/homebrew/bin/claude")
            #expect(!launcher.started.contains { $0.request.executable == "/bin/zsh" })
        }
    }

    @Test("Detection: nothing found, and a failing --version")
    func failures() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.executables = []
        launcher.loginShellOutput = ""
        try await withChatEngine(launcher: launcher) { bed in
            #expect(await bed.engine.currentClaudeStatus == ClaudeStatus(available: false, error: ClaudeCLI.notFoundMessage, checking: false))
            launcher.executables = ["/fake/bin/claude"]
            launcher.loginShellOutput = "/fake/bin/claude\n"
            launcher.versionOutput = "no version here"
            launcher.versionExit = 3
            let status = try await bed.connection.call(ClaudeStatusMethod.self)
            #expect(status == ClaudeStatus(available: false, path: "/fake/bin/claude",
                                           error: "/fake/bin/claude --version failed: exit code 3.", checking: false))
            launcher.versionExit = 0
            #expect(try await bed.connection.call(ClaudeStatusMethod.self).error == "/fake/bin/claude --version failed: exit code 0.")
        }
    }

    @Test("A claudePath change computes the status again with checking true meanwhile")
    func claudePathChange() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.executables = ["/fake/bin/claude", "/other/claude"]
        try await withChatEngine(launcher: launcher) { bed in
            #expect(await bed.engine.currentClaudeStatus.available)
            _ = try await bed.connection.call(SettingsUpdate.self, SettingsUpdate.Params(claudePath: .set("/other/claude")))
            let checking = await bed.events.wait(for: "claude.updated") { (try? $0.payload(ClaudeUpdatedEvent.self))?.status.checking == true }
            #expect(checking != nil)
            let done = await bed.events.wait(for: "claude.updated") {
                (try? $0.payload(ClaudeUpdatedEvent.self))?.status.path == "/other/claude"
            }
            #expect(try done?.payload(ClaudeUpdatedEvent.self).status.available == true)
        }
    }

    @Test("Without the CLI, a message is refused with unavailable and nothing is created")
    func unavailable() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.executables = []
        launcher.loginShellOutput = ""
        try await withChatEngine(launcher: launcher) { bed in
            let error = await engineError { try await bed.createChat(message: "Hello") }
            #expect(error == EngineError(.unavailable, ClaudeCLI.notFoundMessage))
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).isEmpty)
            let chat = try await bed.createChat()
            #expect(await engineError { try await bed.send(chat.id, "Hello") }?.code == .unavailable)
            #expect(try await bed.transcript(chat.id).isEmpty)
        }
    }

    @Test("Claude processes get the captured environment without HEPHAESTUS_* and with MCP_TOOL_TIMEOUT")
    func environment() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Hello")
            let process = try #require(await bed.launcher.chatProcess())
            #expect(process.request.environment["PATH"] == "/fake/bin:/usr/bin")
            #expect(process.request.environment["MCP_TOOL_TIMEOUT"] == "1800000")
            #expect(process.request.environment["HEPHAESTUS_EXTRA"] == nil)
            #expect(process.request.currentDirectory == bed.root.path)
            _ = chat
        }
    }
}
