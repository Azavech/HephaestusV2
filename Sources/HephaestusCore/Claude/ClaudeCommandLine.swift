import Foundation

/// The argument lists of the Claude CLI processes (docs/chats.md › Command line, › Haiku naming
/// › Command) and the files written for a launch.
enum ClaudeCommandLine {
    /// Row 14: the tools that run in every permission mode.
    static let preApprovedTools = [
        "ask_questions", "ask_symbol", "ask_color", "ask_sound", "ask_shortcut", "close_chat", "list_projects", "get_project",
        "list_tickets", "get_ticket", "create_ticket", "update_ticket", "set_ticket_status", "add_comment", "update_comment",
        "list_bundles", "get_bundle", "create_bundle", "update_bundle", "search", "list_docs", "list_web_tabs", "list_skills",
        "get_skill", "list_chats", "get_chat",
    ].map { "mcp__hephaestus__\($0)" }.joined(separator: ",")

    /// The argv of a chat process, the CLI path first; no shell is involved.
    static func chat(cliPath: String, chatID: ChatID, sessionStarted: Bool, settings: ChatSettings, mcpPort: Int, mcpConfigPath: String,
                     systemPrompt: String, pluginDirectory: String?) -> [String] {
        var argv = [cliPath, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages"]
        argv += [sessionStarted ? "--resume" : "--session-id", chatID.uuidString]
        argv += ["--model", settings.model]
        argv += ["--effort", settings.effort.rawValue]
        argv += ["--permission-mode", settings.permissionMode.rawValue]
        argv += ["--allow-dangerously-skip-permissions"]
        argv += ["--permission-prompt-tool", "stdio"]
        argv += ["--mcp-config", mcpConfigPath]
        argv += ["--allowedTools", preApprovedTools]
        argv += ["--disallowedTools", "AskUserQuestion"]
        argv += ["--append-system-prompt", systemPrompt]
        if let pluginDirectory {
            argv += ["--plugin-dir", pluginDirectory]
        }
        argv += ["--settings", chatSettings(ultracode: settings.ultracode, mcpPort: mcpPort)]
        return argv
    }

    /// Row 18: the `UserPromptSubmit` hook of the linked items hook, after `"ultracode":true` when
    /// ultracode is on (docs/chats.md › Command line, › Linked items hook). The CLI reads the token
    /// from the process's environment, so it is not part of the arguments.
    static func chatSettings(ultracode: Bool, mcpPort: Int) -> String {
        let url = "http://127.0.0.1:\(mcpPort)\(LinkedItemsHook.path)"
        let variable = LinkedItemsHook.tokenVariable
        let hook = #"{"type":"http","url":\#(ControlLines.string(url)),"headers":{"Authorization":\#(ControlLines.string("Bearer $" + variable))},"#
            + #""allowedEnvVars":[\#(ControlLines.string(variable))],"timeout":\#(LinkedItemsHook.timeoutSeconds)}"#
        let hooks = #""hooks":{"UserPromptSubmit":[{"hooks":[\#(hook)]}]}"#
        return ultracode ? #"{"ultracode":true,\#(hooks)}"# : "{\(hooks)}"
    }

    /// The argv of a naming call (docs/chats.md › Haiku naming › Command).
    static func naming(cliPath: String, prompt: String, input: String) -> [String] {
        [cliPath, "-p", "--model", "haiku", "--output-format", "json", "--no-session-persistence", "--tools", "",
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--system-prompt", prompt, input]
    }

    /// `Runtime/mcp/<chat id>.json` (docs/chats.md › MCP configuration file).
    static func mcpConfiguration(port: Int, token: String) -> Data {
        let url = "http://127.0.0.1:\(port)/mcp"
        let text = #"{"mcpServers":{"hephaestus":{"type":"http","url":\#(ControlLines.string(url)),"headers":{"Authorization":\#(ControlLines.string("Bearer " + token))}}}}"#
        return Data(text.utf8)
    }

    /// The line each launch appends to the chat's log: `--- <ISO-8601 date> launch: <argv> ---`,
    /// with the value of `--append-system-prompt` replaced by `<N characters>` and the arguments
    /// quoted as docs/chats.md › Exit handling and logs states.
    static func launchLogLine(argv: [String], date: Date) -> String {
        var parts: [String] = []
        var replaceNext = false
        for argument in argv {
            if replaceNext {
                parts.append("<\(argument.count) characters>")
                replaceNext = false
                continue
            }
            parts.append(quoted(argument))
            replaceNext = argument == "--append-system-prompt"
        }
        return "--- \(ISODate.string(from: date)) launch: \(parts.joined(separator: " ")) ---"
    }

    private static func quoted(_ argument: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=,@+%"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
