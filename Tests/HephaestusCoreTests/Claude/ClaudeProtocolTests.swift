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

    @Test("User messages: the image blocks then the text block, so that a skill call runs; no text block for an empty text; the uuid last")
    func userMessages() {
        let uuid = "7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B"
        #expect(Self.text(ControlLines.userMessage(text: "Why does the build fail?", images: [ControlLines.Image(mediaType: "image/png", base64: "iVBO")],
                                                   uuid: uuid))
            == #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBO"}},{"type":"text","text":"Why does the build fail?"}]},"uuid":"7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B"}"# + "\n")
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
            settings: ChatSettings(model: "opus", effort: .high, permissionMode: .manual, ultracode: true), mcpPort: 47820,
            mcpConfigPath: "/Users/example/Library/Application Support/HephaestusV2/Runtime/mcp/3F2504E0-4F89-11D3-9A0C-0305E82C3301.json",
            systemPrompt: "You are Claude, working inside HephaestusV2, …",
            pluginDirectory: "/Users/example/Library/Application Support/HephaestusV2/Runtime/plugins/HEPH",
            globalMemoriesFolder: "/Users/example/.claude/memory")
        #expect(argv == [
            "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--resume", "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            "--model", "opus", "--effort", "high", "--permission-mode", "manual", "--allow-dangerously-skip-permissions",
            "--permission-prompt-tool", "stdio",
            "--mcp-config", "/Users/example/Library/Application Support/HephaestusV2/Runtime/mcp/3F2504E0-4F89-11D3-9A0C-0305E82C3301.json",
            "--allowedTools",
            "mcp__hephaestus__ask_questions,mcp__hephaestus__ask_symbol,mcp__hephaestus__ask_color,mcp__hephaestus__ask_sound,mcp__hephaestus__ask_shortcut,mcp__hephaestus__ask_font,mcp__hephaestus__ask_animation,mcp__hephaestus__show_image,mcp__hephaestus__list_projects,mcp__hephaestus__get_project,mcp__hephaestus__list_tickets,mcp__hephaestus__get_ticket,mcp__hephaestus__create_ticket,mcp__hephaestus__update_ticket,mcp__hephaestus__set_ticket_status,mcp__hephaestus__add_comment,mcp__hephaestus__update_comment,mcp__hephaestus__list_bundles,mcp__hephaestus__get_bundle,mcp__hephaestus__create_bundle,mcp__hephaestus__update_bundle,mcp__hephaestus__search,mcp__hephaestus__list_docs,mcp__hephaestus__list_web_tabs,mcp__hephaestus__list_skills,mcp__hephaestus__get_skill,mcp__hephaestus__list_chats,mcp__hephaestus__get_chat,mcp__hephaestus__k8s_status,mcp__hephaestus__k8s_logs,mcp__hephaestus__k8s_events,mcp__hephaestus__argocd_status",
            "--disallowedTools", "AskUserQuestion",
            "--append-system-prompt", "You are Claude, working inside HephaestusV2, …",
            "--plugin-dir", "/Users/example/Library/Application Support/HephaestusV2/Runtime/plugins/HEPH",
            "--settings",
            #"{"ultracode":true,"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"http","url":"http://127.0.0.1:47820/hooks/user-prompt-submit","headers":{"Authorization":"Bearer $HEPHAESTUS_HOOK_TOKEN"},"allowedEnvVars":["HEPHAESTUS_HOOK_TOKEN"],"timeout":10}]}],"PreToolUse":[{"matcher":"mcp__hephaestus__close_chat","hooks":[{"type":"http","url":"http://127.0.0.1:47820/hooks/pre-tool-use","headers":{"Authorization":"Bearer $HEPHAESTUS_HOOK_TOKEN"},"allowedEnvVars":["HEPHAESTUS_HOOK_TOKEN"],"timeout":10}]}]}}"#,
            "--add-dir", "/Users/example/.claude/memory",
        ])
    }

    @Test("A new session uses --session-id; no plugin folder leaves row 17 out; without ultracode row 18 holds the hook alone; no global memories folder leaves row 19 out")
    func newSessionCommandLine() {
        let argv = ClaudeCommandLine.chat(cliPath: "/fake/claude", chatID: Self.chatID, sessionStarted: false,
                                          settings: ChatSettings(permissionMode: .bypassPermissions), mcpPort: 50123, mcpConfigPath: "/m.json",
                                          systemPrompt: "P", pluginDirectory: nil, globalMemoriesFolder: nil)
        #expect(!argv.contains("--add-dir"))
        #expect(Array(argv[8...9]) == ["--session-id", "3F2504E0-4F89-11D3-9A0C-0305E82C3301"])
        #expect(Array(argv[10...15]) == ["--model", "default", "--effort", "high", "--permission-mode", "bypassPermissions"])
        #expect(!argv.contains("--plugin-dir"))
        #expect(Array(argv.suffix(4)) == [
            "--append-system-prompt", "P", "--settings",
            #"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"http","url":"http://127.0.0.1:50123/hooks/user-prompt-submit","headers":{"Authorization":"Bearer $HEPHAESTUS_HOOK_TOKEN"},"allowedEnvVars":["HEPHAESTUS_HOOK_TOKEN"],"timeout":10}]}],"PreToolUse":[{"matcher":"mcp__hephaestus__close_chat","hooks":[{"type":"http","url":"http://127.0.0.1:50123/hooks/pre-tool-use","headers":{"Authorization":"Bearer $HEPHAESTUS_HOOK_TOKEN"},"allowedEnvVars":["HEPHAESTUS_HOOK_TOKEN"],"timeout":10}]}]}}"#,
        ])
    }

    /// docs/chats.md › Context window: Auto passes no `--autocompact`; 200K and 1M pass row 20 last.
    @Test("Row 20 passes --autocompact for 200K and 1M, and nothing for Auto", arguments: [
        (ContextWindow.auto, nil), (.tokens200K, "200000"), (.tokens1M, "1000000"),
    ] as [(ContextWindow, String?)])
    func contextWindowCommandLine(window: ContextWindow, tokens: String?) {
        for globalMemoriesFolder in [nil, "/Users/example/.claude/memory"] {
            let argv = ClaudeCommandLine.chat(cliPath: "/fake/claude", chatID: Self.chatID, sessionStarted: true,
                                              settings: ChatSettings(contextWindow: window), mcpPort: 47820, mcpConfigPath: "/m.json",
                                              systemPrompt: "P", pluginDirectory: nil, globalMemoriesFolder: globalMemoriesFolder)
            if let tokens {
                #expect(Array(argv.suffix(2)) == ["--autocompact", tokens])
                #expect(argv.filter { $0 == "--autocompact" }.count == 1)
            } else {
                #expect(!argv.contains("--autocompact"))
                #expect(argv.last == (globalMemoriesFolder ?? ClaudeCommandLine.chatSettings(ultracode: false, mcpPort: 47820)))
            }
        }
    }

    @Test("The settings JSON of row 18 is valid JSON holding the hook, with ultracode first when on")
    func chatSettingsJSON() throws {
        for ultracode in [false, true] {
            let text = ClaudeCommandLine.chatSettings(ultracode: ultracode, mcpPort: 47820)
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            let object = try #require(value.objectValue)
            #expect(object["ultracode"] == (ultracode ? .bool(true) : nil))
            #expect(text.hasPrefix(ultracode ? #"{"ultracode":true,"hooks":"# : #"{"hooks":"#))
            #expect(object["hooks"]?.objectValue?["UserPromptSubmit"] != nil)
            #expect(object["hooks"]?.objectValue?["PreToolUse"]?.arrayValue?.first?.objectValue?["matcher"]
                == .string("mcp__hephaestus__close_chat"))
        }
    }

    @Test("Row 18 holds a Read rule per inherited memory folder, before the hooks; a path with a pattern character or a final white space gets none")
    func readRules() throws {
        let folder = "/Users/example/.claude/projects/-Users-example-Developer-Suite/memory"
        let text = ClaudeCommandLine.chatSettings(ultracode: true, mcpPort: 47820,
                                                  readFolders: [folder, "/Users/example/Library/Application Support/Claude (work)", "/tmp/a*b",
                                                                "/tmp/a\\b", "/tmp/new\nline", "/tmp/space "])
        #expect(text.hasPrefix(#"{"ultracode":true,"permissions":{"allow":["Read(//Users/example/.claude/projects/-Users-example-Developer-Suite/memory/**)","Read(//Users/example/Library/Application Support/Claude (work)/**)"]},"hooks":{"#))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value.objectValue?["permissions"]?.objectValue?["allow"]?.arrayValue?.count == 2)
        #expect(value.objectValue?["hooks"]?.objectValue?["PreToolUse"] != nil)
        // No rule at all leaves the key out.
        #expect(ClaudeCommandLine.chatSettings(ultracode: false, mcpPort: 47820, readFolders: ["/tmp/[x]"])
            == ClaudeCommandLine.chatSettings(ultracode: false, mcpPort: 47820))
        for path in ["/tmp/a?b", "/tmp/a[b", "/tmp/a\u{7F}b", "/tmp/a\u{85}b", "/tmp/tab\t", "/tmp/end ", "/tmp/nbsp\u{A0}",
                     "/tmp/bom\u{FEFF}", "relative"] {
            #expect(ClaudeCommandLine.readRule(path) == nil, "\(path)")
        }
        for path in ["/tmp/é ü", "/tmp/a]b", "/tmp/{a,b}", "/tmp/(x)", "/tmp/a|b+c^d$e"] {
            #expect(ClaudeCommandLine.readRule(path) == "Read(/\(path)/**)", "\(path)")
        }
        let argv = ClaudeCommandLine.chat(cliPath: "/fake/claude", chatID: Self.chatID, sessionStarted: false, settings: ChatSettings(),
                                          mcpPort: 47820, mcpConfigPath: "/m.json", systemPrompt: "P", pluginDirectory: nil, readFolders: [folder],
                                          globalMemoriesFolder: nil)
        #expect(argv.last == ClaudeCommandLine.chatSettings(ultracode: false, mcpPort: 47820, readFolders: [folder]))
        // A sub project's chat with the global memories folder: row 19 follows the rules of row 18.
        let both = ClaudeCommandLine.chat(cliPath: "/fake/claude", chatID: Self.chatID, sessionStarted: false, settings: ChatSettings(),
                                          mcpPort: 47820, mcpConfigPath: "/m.json", systemPrompt: "P", pluginDirectory: nil, readFolders: [folder],
                                          globalMemoriesFolder: "/Users/example/.claude/memory")
        #expect(Array(both.suffix(4)) == ["--settings", ClaudeCommandLine.chatSettings(ultracode: false, mcpPort: 47820, readFolders: [folder]),
                                          "--add-dir", "/Users/example/.claude/memory"])
    }

    @Test("close_chat is not pre-approved by --allowedTools: the close chat hook approves a call that names no other chat")
    func closeChatPermission() throws {
        let tools = ClaudeCommandLine.preApprovedTools.split(separator: ",").map(String.init)
        #expect(!tools.contains("mcp__hephaestus__close_chat"))
        #expect(tools.contains("mcp__hephaestus__ask_questions"))
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(ClaudeCommandLine.chatSettings(ultracode: false, mcpPort: 47820).utf8))
        let entry = try #require(settings.objectValue?["hooks"]?.objectValue?["PreToolUse"]?.arrayValue?.first?.objectValue)
        #expect(entry["matcher"] == .string(CloseChatHook.toolName))
        let hook = try #require(entry["hooks"]?.arrayValue?.first?.objectValue)
        #expect(hook["url"] == .string("http://127.0.0.1:47820/hooks/pre-tool-use"))
        #expect(hook["headers"] == .object(["Authorization": .string("Bearer $HEPHAESTUS_HOOK_TOKEN")]))
    }

    @Test("Row 14 is the <pre-approved tools> argument of docs/chats.md › Command line: the Kubernetes and Argo CD tools that read, not those that change a cluster or open a port")
    func preApprovedTools() throws {
        let chats = try Repository.doc("chats.md")
        let start = try #require(chats.range(of: "- `<pre-approved tools>` is this single argument: `")).upperBound
        let end = try #require(chats[start...].firstIndex(of: "`"))
        #expect(ClaudeCommandLine.preApprovedTools == String(chats[start..<end]))
        let tools = Set(ClaudeCommandLine.preApprovedTools.split(separator: ",").map(String.init))
        for tool in ["k8s_status", "k8s_logs", "k8s_events", "argocd_status"] {
            #expect(tools.contains("mcp__hephaestus__\(tool)"), "\(tool)")
        }
        for tool in ["k8s_restart", "k8s_scale", "k8s_port_forward", "k8s_stop_port_forward", "argocd_sync"] {
            #expect(!tools.contains("mcp__hephaestus__\(tool)"), "\(tool)")
        }
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
        let models = try #require(ClaudeModel.parse(response.objectValue?["response"]?.objectValue?["response"]?.objectValue?["models"]))
        #expect(models.first == ClaudeModel(value: "default", displayName: "Default (recommended)",
                                            description: "Opus 5.5 · Best for everyday, complex tasks",
                                            supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"],
                                            resolvedModel: "claude-opus-5-5"))
        #expect(models.first { $0.value == "claude-haiku-4-5-20251001" }?.supportedEffortLevels == [])
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
