import Foundation
import Testing
@testable import HephaestusCore

/// The lines written to a Claude process (docs/chats.md › Control protocol, › User messages,
/// › Answer) and the argument lists (docs/chats.md › Command line, › Haiku naming › Command).
@Suite("Claude protocol and command lines")
struct ClaudeProtocolTests {
    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test("Control requests of the engine are the lines of docs/chats.md › Control protocol")
    func controlRequests() {
        #expect(ControlLines.requestID(1) == "hephaestus-1")
        #expect(Self.text(ControlLines.request(id: "hephaestus-1", subtype: "initialize"))
            == #"{"type":"control_request","request_id":"hephaestus-1","request":{"subtype":"initialize"}}"# + "\n")
        #expect(Self.text(ControlLines.request(id: "hephaestus-2", subtype: "interrupt"))
            == #"{"type":"control_request","request_id":"hephaestus-2","request":{"subtype":"interrupt"}}"# + "\n")
        #expect(Self.text(ControlLines.setModel(id: "hephaestus-3", model: "opus"))
            == #"{"type":"control_request","request_id":"hephaestus-3","request":{"subtype":"set_model","model":"opus"}}"# + "\n")
        #expect(Self.text(ControlLines.setPermissionMode(id: "hephaestus-4", mode: ControlLines.cliMode(.manual)))
            == #"{"type":"control_request","request_id":"hephaestus-4","request":{"subtype":"set_permission_mode","mode":"default"}}"# + "\n")
        #expect(ControlLines.cliMode(.acceptEdits) == "acceptEdits")
        #expect(Self.text(ControlLines.applyEffort(id: "hephaestus-5", effort: .xhigh))
            == #"{"type":"control_request","request_id":"hephaestus-5","request":{"subtype":"apply_flag_settings","settings":{"effortLevel":"xhigh"}}}"# + "\n")
        #expect(Self.text(ControlLines.applyUltracode(id: "hephaestus-6", on: false))
            == #"{"type":"control_request","request_id":"hephaestus-6","request":{"subtype":"apply_flag_settings","settings":{"ultracode":false}}}"# + "\n")
        #expect(Self.text(ControlLines.unsupportedAnswer(requestID: "abc", subtype: "mcp_message"))
            == #"{"type":"control_response","response":{"subtype":"error","request_id":"abc","error":"Unsupported control request: mcp_message"}}"# + "\n")
    }

    @Test("Permission answers of docs/chats.md › Answer")
    func permissionAnswers() throws {
        let input: JSONValue = ["file_path": "/tmp/example", "content": "hi"]
        let suggestions = try jsonValue(#"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#)
        #expect(Self.text(ControlLines.permissionAnswer(requestID: "r", decision: .allow, input: input, suggestions: suggestions, message: ""))
            == #"{"type":"control_response","response":{"subtype":"success","request_id":"r","response":{"behavior":"allow","updatedInput":{"content":"hi","file_path":"/tmp/example"}}}}"# + "\n")
        #expect(Self.text(ControlLines.permissionAnswer(requestID: "r", decision: .allowAlways, input: input, suggestions: suggestions, message: ""))
            == #"{"type":"control_response","response":{"subtype":"success","request_id":"r","response":{"behavior":"allow","updatedInput":{"content":"hi","file_path":"/tmp/example"},"updatedPermissions":[{"destination":"session","mode":"acceptEdits","type":"setMode"}]}}}"# + "\n")
        // allowAlways without suggestions writes the allow line.
        #expect(ControlLines.permissionAnswer(requestID: "r", decision: .allowAlways, input: input, suggestions: [], message: "")
            == ControlLines.permissionAnswer(requestID: "r", decision: .allow, input: input, suggestions: nil, message: ""))
        #expect(Self.text(ControlLines.permissionAnswer(requestID: "1967e0c0-4eab-4e9a-8c9e-67ec5e2cb4a0", decision: .deny, input: input,
                                                        suggestions: nil, message: "User denied in probe"))
            == #"{"type":"control_response","response":{"subtype":"success","request_id":"1967e0c0-4eab-4e9a-8c9e-67ec5e2cb4a0","response":{"behavior":"deny","message":"User denied in probe"}}}"# + "\n")
    }

    @Test("User messages: the text block then the image blocks; no text block for an empty text; the uuid last")
    func userMessages() {
        let uuid = "7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B"
        #expect(Self.text(ControlLines.userMessage(text: "Why does the build fail?", images: [ControlLines.Image(mediaType: "image/png", base64: "iVBO")],
                                                   uuid: uuid))
            == #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Why does the build fail?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBO"}}]},"uuid":"7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B"}"# + "\n")
        #expect(Self.text(ControlLines.userMessage(text: "", images: [ControlLines.Image(mediaType: "image/gif", base64: "R0lG")], uuid: uuid))
            == #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/gif","data":"R0lG"}}]},"uuid":"7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B"}"# + "\n")
        // One line: line breaks of the text are escaped.
        let line = Self.text(ControlLines.userMessage(text: "a\nb", images: [], uuid: uuid))
        #expect(line.filter { $0 == "\n" }.count == 1)
    }

    static let chatID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    @Test("The command line of the example of docs/chats.md › Command line")
    func chatCommandLine() {
        let argv = ClaudeCommandLine.chat(
            cliPath: "claude", chatID: Self.chatID, sessionStarted: true,
            settings: ChatSettings(model: "opus", effort: .high, permissionMode: .manual, ultracode: true),
            mcpConfigPath: "/Users/example/Library/Application Support/HephaestusV2/Runtime/mcp/3F2504E0-4F89-11D3-9A0C-0305E82C3301.json",
            systemPrompt: "You are Claude, working inside HephaestusV2, …",
            pluginDirectory: "/Users/example/Library/Application Support/HephaestusV2/Runtime/plugins/HEPH")
        #expect(argv == [
            "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--resume", "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            "--model", "opus", "--effort", "high", "--permission-mode", "manual", "--allow-dangerously-skip-permissions",
            "--permission-prompt-tool", "stdio",
            "--mcp-config", "/Users/example/Library/Application Support/HephaestusV2/Runtime/mcp/3F2504E0-4F89-11D3-9A0C-0305E82C3301.json",
            "--allowedTools",
            "mcp__hephaestus__ask_questions,mcp__hephaestus__list_projects,mcp__hephaestus__get_project,mcp__hephaestus__list_tickets,mcp__hephaestus__get_ticket,mcp__hephaestus__list_bundles,mcp__hephaestus__get_bundle,mcp__hephaestus__search,mcp__hephaestus__list_docs,mcp__hephaestus__list_web_tabs,mcp__hephaestus__list_skills,mcp__hephaestus__get_skill,mcp__hephaestus__list_chats,mcp__hephaestus__get_chat",
            "--disallowedTools", "AskUserQuestion",
            "--append-system-prompt", "You are Claude, working inside HephaestusV2, …",
            "--plugin-dir", "/Users/example/Library/Application Support/HephaestusV2/Runtime/plugins/HEPH",
            "--settings", #"{"ultracode":true}"#,
        ])
    }

    @Test("A new session uses --session-id; no plugin folder and no ultracode leave rows 17 and 18 out")
    func newSessionCommandLine() {
        let argv = ClaudeCommandLine.chat(cliPath: "/fake/claude", chatID: Self.chatID, sessionStarted: false,
                                          settings: ChatSettings(permissionMode: .bypassPermissions), mcpConfigPath: "/m.json",
                                          systemPrompt: "P", pluginDirectory: nil)
        #expect(Array(argv[8...9]) == ["--session-id", "3F2504E0-4F89-11D3-9A0C-0305E82C3301"])
        #expect(Array(argv[10...15]) == ["--model", "default", "--effort", "high", "--permission-mode", "bypassPermissions"])
        #expect(!argv.contains("--plugin-dir"))
        #expect(!argv.contains("--settings"))
        #expect(argv.last == "P")
    }

    @Test("The naming command of docs/chats.md › Haiku naming › Command")
    func namingCommandLine() {
        #expect(ClaudeCommandLine.naming(cliPath: "/c", prompt: "PROMPT", input: "First message:\nhi")
            == ["/c", "-p", "--model", "haiku", "--output-format", "json", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                "--mcp-config", #"{"mcpServers":{}}"#, "--system-prompt", "PROMPT", "First message:\nhi"])
        #expect(ClaudeCLI.probeArguments() == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                               "--no-session-persistence", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#])
    }

    @Test("The MCP configuration file of docs/chats.md › MCP configuration file")
    func mcpConfiguration() {
        let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        #expect(Self.text(ClaudeCommandLine.mcpConfiguration(port: 47820, token: token))
            == #"{"mcpServers":{"hephaestus":{"type":"http","url":"http://127.0.0.1:47820/mcp","headers":{"Authorization":"Bearer 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}}"#)
    }

    @Test("The launch line of the chat log replaces the system prompt by its length")
    func launchLogLine() {
        let line = ClaudeCommandLine.launchLogLine(argv: ["/c", "-p", "--append-system-prompt", "four", "--mcp-config", "/a b/c.json"],
                                                   date: Date(timeIntervalSince1970: 0))
        #expect(line == "--- 1970-01-01T00:00:00Z launch: /c -p --append-system-prompt <4 characters> --mcp-config '/a b/c.json' ---")
    }

    @Test("The version is the first dotted number of --version")
    func version() {
        #expect(ClaudeCLI.version(in: "2.1.309 (Claude Code)") == "2.1.309")
        #expect(ClaudeCLI.version(in: "Claude Code v10.2") == "10.2")
        #expect(ClaudeCLI.version(in: "build 7") == nil)
        #expect(ClaudeCLI.standardCandidates(homeDirectory: "/Users/example")
            == ["/Users/example/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    @Test("The models of an initialize response, supportedEffortLevels empty when absent")
    func models() throws {
        let response = try JSONDecoder().decode(JSONValue.self, from: FakeClaudeLauncher.fixture("initialize-response.json"))
        let models = try #require(CachedModel.parse(response.objectValue?["response"]?.objectValue?["response"]?.objectValue?["models"]))
        #expect(models.first == CachedModel(model: ClaudeModel(value: "default", displayName: "Default (recommended)",
                                                               description: "Opus 5.5 · Best for everyday, complex tasks",
                                                               supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]),
                                            resolvedModel: "claude-opus-5-5"))
        #expect(models.first { $0.model.value == "claude-haiku-4-5-20251001" }?.model.supportedEffortLevels == [])
        #expect(ClaudeCLI.fallbackModels.map(\.value) == ["default", "opus", "fable", "sonnet", "haiku"])
    }

    @Test("Stored attachment names: separators and control characters replaced, length limited")
    func storedNames() {
        #expect(ChatAttachments.storedName("a/b:c\u{07}.txt") == "a_b_c_.txt")
        #expect(ChatAttachments.storedName("") == "file")
        let long = String(repeating: "x", count: 300) + ".log"
        let stored = ChatAttachments.storedName(long)
        #expect(stored.hasSuffix(".log"))
        #expect(("\(UUID().uuidString)-" + stored).utf8.count == 213)
        #expect(ChatAttachments.imageExtension("image/jpeg") == "jpg")
    }
}
