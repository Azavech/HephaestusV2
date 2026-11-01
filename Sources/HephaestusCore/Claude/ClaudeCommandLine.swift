import Foundation

/// The argument lists of the Claude CLI processes (docs/chats.md › Command line, › Haiku naming
/// › Command) and the files written for a launch.
enum ClaudeCommandLine {
    /// Row 14: the tools that run in every permission mode.
    static let preApprovedTools = [
        "ask_questions", "close_chat", "list_projects", "get_project", "list_tickets", "get_ticket", "list_bundles", "get_bundle", "search",
        "list_docs", "list_web_tabs", "list_skills", "get_skill", "list_chats", "get_chat",
    ].map { "mcp__hephaestus__\($0)" }.joined(separator: ",")

    /// The argv of a chat process, the CLI path first; no shell is involved.
    static func chat(cliPath: String, chatID: ChatID, sessionStarted: Bool, settings: ChatSettings, mcpConfigPath: String,
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
        if settings.ultracode {
            argv += ["--settings", #"{"ultracode":true}"#]
        }
        return argv
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
