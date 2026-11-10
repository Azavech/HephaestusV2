import Foundation

/// The argument lists of the Claude CLI processes (docs/chats.md › Command line, › Haiku naming
/// › Command) and the files written for a launch.
enum ClaudeCommandLine {
    /// Row 14: the tools that run in every permission mode (docs/chats.md › Command line); the
    /// four Kubernetes and Argo CD tools that only read the cluster, `api_operations`, then the
    /// VM tools but `vm_copy_out`, come last.
    static let preApprovedTools = [
        "ask_questions", "ask_symbol", "ask_color", "ask_sound", "ask_shortcut", "ask_font", "ask_animation", "show_image",
        "list_projects", "get_project", "list_tickets", "get_ticket", "create_ticket", "update_ticket", "set_ticket_status",
        "add_comment", "update_comment", "list_bundles", "get_bundle", "create_bundle", "update_bundle", "search", "list_docs",
        "list_web_tabs", "list_skills", "get_skill", "list_chats", "get_chat",
        "k8s_status", "k8s_logs", "k8s_events", "argocd_status", "api_operations",
        "vm_list_images", "vm_set_account", "vm_list", "vm_start", "vm_stop", "vm_screenshot", "vm_click", "vm_drag", "vm_scroll", "vm_type", "vm_key",
        "vm_ui_tree", "vm_shell", "vm_copy_in", "vm_setup_recovery", "vm_setup_finish",
    ].map { "mcp__hephaestus__\($0)" }.joined(separator: ",")

    /// The argv of a chat process, the CLI path first; no shell is involved. `readFolders` are the
    /// inherited memory folders that `{{parentMemories}}` names, each followed by its path with
    /// its symbolic links resolved, as written on disk and in NFC, when they differ.
    /// `globalMemoriesFolder` is the global memories folder when it exists (docs/memories.md › In
    /// chats).
    static func chat(cliPath: String, chatID: ChatID, sessionStarted: Bool, settings: ChatSettings, mcpPort: Int, mcpConfigPath: String,
                     systemPrompt: String, pluginDirectory: String?, readFolders: [String] = [], globalMemoriesFolder: String?) -> [String] {
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
        argv += ["--settings", chatSettings(ultracode: settings.ultracode, mcpPort: mcpPort, readFolders: readFolders)]
        // Row 19: the global memories folder as a working directory.
        if let globalMemoriesFolder {
            argv += ["--add-dir", globalMemoriesFolder]
        }
        // Row 20: the context window, except Auto (docs/chats.md › Context window).
        if let tokens = settings.contextWindow.autocompactTokens {
            argv += ["--autocompact", String(tokens)]
        }
        return argv
    }

    /// Row 18: the `UserPromptSubmit` hook of the linked items hook and the `PreToolUse` hook of
    /// the close chat hook and the API call hook, after `"ultracode":true` when ultracode is on and after the `Read`
    /// rules of the inherited memory folders (docs/chats.md › Command line, › Linked items hook,
    /// › Close chat hook). The CLI reads the token from the process's environment, so it is not
    /// part of the arguments.
    static func chatSettings(ultracode: Bool, mcpPort: Int, readFolders: [String] = []) -> String {
        func hook(_ path: String) -> String {
            let url = "http://127.0.0.1:\(mcpPort)\(path)"
            let variable = LinkedItemsHook.tokenVariable
            return #"{"type":"http","url":\#(ControlLines.string(url)),"headers":{"Authorization":\#(ControlLines.string("Bearer $" + variable))},"#
                + #""allowedEnvVars":[\#(ControlLines.string(variable))],"timeout":\#(LinkedItemsHook.timeoutSeconds)}"#
        }
        let hooks = #""hooks":{"UserPromptSubmit":[{"hooks":[\#(hook(LinkedItemsHook.path))]}],"#
            + #""PreToolUse":[{"matcher":\#(ControlLines.string(CloseChatHook.matcher)),"hooks":[\#(hook(CloseChatHook.path))]}]}"#
        let rules = readFolders.compactMap(readRule)
        let permissions = rules.isEmpty ? "" : #""permissions":{"allow":[\#(rules.map(ControlLines.string).joined(separator: ","))]},"#
        return "{" + (ultracode ? #""ultracode":true,"# : "") + permissions + hooks + "}"
    }

    /// The characters of a path that the CLI's path matching reads as a pattern in a permission
    /// rule, and the control characters (U+0000 to U+001F, U+007F to U+009F).
    static let patternCharacters = CharacterSet(charactersIn: "*?[\\")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x00)...Unicode.Scalar(0x1F)))
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x7F)...Unicode.Scalar(0x9F)))

    /// The `Read` rule of an inherited memory folder: `Read(/<folder>/**)`, the `//` of an absolute
    /// path; nil for a path that holds a pattern character or ends with white space, which the
    /// CLI's matching drops: Unicode white space or U+FEFF, as JavaScript's `\s` (docs/chats.md ›
    /// Command line).
    static func readRule(_ folder: String) -> String? {
        guard folder.hasPrefix("/"), folder.rangeOfCharacter(from: patternCharacters) == nil,
              let last = folder.unicodeScalars.last, !last.properties.isWhitespace, last != "\u{FEFF}" else { return nil }
        return "Read(/\(folder)/**)"
    }

    /// The tools of a comment answer: the read-only file tools and the hephaestus tools that read
    /// data, plus `update_ticket` and `set_ticket_status` (docs/chats.md › Answer command).
    static let answerMCPTools = [
        "list_projects", "get_project", "list_tickets", "get_ticket", "update_ticket", "set_ticket_status", "list_bundles",
        "get_bundle", "search", "list_docs", "list_web_tabs", "list_skills", "get_skill", "list_chats", "get_chat",
    ]
    static let answerFileTools = "Read,Grep,Glob"
    static let answerTools = ([answerFileTools] + answerMCPTools.map { "mcp__hephaestus__\($0)" }).joined(separator: ",")

    /// The argv of a comment answer call (docs/chats.md › Answer command).
    static func commentAnswer(cliPath: String, model: String, effort: String, mcpConfigPath: String, systemPrompt: String,
                              input: String) -> [String] {
        [cliPath, "-p", "--output-format", "json", "--no-session-persistence", "--model", model, "--effort", effort,
         "--permission-mode", "dontAsk", "--tools", answerFileTools, "--allowedTools", answerTools, "--strict-mcp-config",
         "--mcp-config", mcpConfigPath, "--append-system-prompt", systemPrompt, input]
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

    /// An argument as the launch line writes it: as it is when it holds only letters, digits and
    /// `-_./:=,@+%`, else in single quotes, each `'` written `'\''`; also the quoting of the kubectl
    /// commands in the messages of the Kubernetes tools (docs/mcp.md › Rules of the Kubernetes tools).
    static func quoted(_ argument: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=,@+%"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
