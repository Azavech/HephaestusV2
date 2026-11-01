// OWNER: ui-chats — the HTML fragments of the transcript page, one per item, and the streaming
// bubbles (docs/chats.md › Web view and bridge, › Item rendering, › Tool cards, › Streaming bubbles).
import Foundation
import HephaestusCore
import HephaestusText

/// One item of the transcript page: `{id, type, html, parentToolUseID, toolUseID}`
/// (docs/chats.md › Web view and bridge).
struct TranscriptFragment: Encodable, Equatable {
    var id: String
    /// The item type.
    var type: String
    var html: String
    /// The item's `parentToolUseID`, or null.
    var parentToolUseID: String?
    /// The `toolUseID` of `toolUse` and `toolResult` items, or null.
    var toolUseID: String?

    enum CodingKeys: String, CodingKey {
        case id, type, html, parentToolUseID, toolUseID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(html, forKey: .html)
        try c.encode(parentToolUseID, forKey: .parentToolUseID)
        try c.encode(toolUseID, forKey: .toolUseID)
    }
}

/// What a fragment depends on besides its item.
struct TranscriptRenderContext: Hashable {
    /// Absolute path of the project root on the main device: Markdown links and images resolve
    /// against it, and tool card summaries show paths inside it relative to it.
    var projectRootPath: String?
    /// The chat is running: a tool card without result shows a spinner.
    var chatIsRunning: Bool
}

/// Renders items to HTML fragments; Markdown goes through the HephaestusText HTML renderer with
/// `baseDirectory` `""` and the project root (docs/documentation-viewer.md › Renderer).
enum TranscriptRenderer {
    /// A tool result shows its first 200 lines until Show All (docs/chats.md › Tool cards).
    static let resultLineLimit = 200

    static func fragment(for item: ChatItem, in state: TranscriptState, context: TranscriptRenderContext) -> TranscriptFragment {
        switch item {
        case .user(let user):
            return TranscriptFragment(id: user.id, type: "user", html: userHTML(user, context: context))
        case .assistant(let assistant):
            return TranscriptFragment(id: assistant.id, type: "assistant", html: assistantHTML(text: assistant.text, created: assistant.created, context: context),
                                      parentToolUseID: assistant.parentToolUseID)
        case .thinking(let thinking):
            return TranscriptFragment(id: thinking.id, type: "thinking", html: thinkingHTML(thinking.text, open: false, context: context),
                                      parentToolUseID: thinking.parentToolUseID)
        case .toolUse(let use):
            return TranscriptFragment(id: use.id, type: "toolUse", html: toolUseHTML(use, in: state, context: context),
                                      parentToolUseID: use.parentToolUseID, toolUseID: use.toolUseID)
        case .toolResult(let result):
            return TranscriptFragment(id: result.id, type: "toolResult", html: toolResultHTML(result), toolUseID: result.toolUseID)
        case .permissionRequest(let request):
            return TranscriptFragment(id: request.id, type: "permissionRequest", html: permissionHTML(request))
        case .questions(let set):
            return TranscriptFragment(id: set.id, type: "questions", html: questionsHTML(set, context: context))
        case .system(let system):
            return TranscriptFragment(id: system.id, type: "system",
                                      html: "<div class=\"system-line level-\(system.level.rawValue)\">\(escape(system.text))</div>")
        case .result(let result):
            let errorClass = result.isError ? " is-error" : ""
            return TranscriptFragment(id: result.id, type: "result",
                                      html: "<div class=\"result-line\(errorClass)\">\(escape(ChatFormat.resultLine(result)))</div>")
        }
    }

    /// The HTML of a streaming bubble (docs/chats.md › Streaming bubbles): an assistant bubble, an
    /// expanded `Thinking` block, or a `Preparing tool call…` card with the last 300 characters of
    /// the partial JSON.
    static func streamHTML(kind: ChatDeltaEvent.Payload.Kind, text: String, context: TranscriptRenderContext) -> String {
        switch kind {
        case .text:
            return "<div class=\"msg assistant\"><div class=\"bubble assistant-bubble\">\(markdown(text, context: context))</div></div>"
        case .thinking:
            return thinkingHTML(text, open: true, context: context)
        case .toolInput:
            let tail = String(text.suffix(TranscriptState.toolInputTail))
            return "<div class=\"tool-card preparing\"><div class=\"tool-header\"><span class=\"tool-name\">Preparing tool call…</span>"
                + "<span class=\"tool-trailing\"><span class=\"spinner\"></span></span></div>"
                + "<pre class=\"partial-json\">\(escape(tail))</pre></div>"
        }
    }

    // MARK: Items

    private static func userHTML(_ user: UserItem, context: TranscriptRenderContext) -> String {
        var html = "<div class=\"msg user\"><div class=\"caption\">\(escape(user.sender))</div>"
        if !user.text.isEmpty {
            html += bubble(kind: "user-bubble", source: user.text, created: user.created, context: context)
        }
        if !user.attachments.isEmpty {
            html += "<div class=\"attachments\">"
            for attachment in user.attachments {
                if ChatAttachmentKind.isImage(attachment.contentType) {
                    html += imageHTML(attachment, title: ChatFormat.created(user.created))
                } else {
                    html += "<button type=\"button\" class=\"file-chip\" data-path=\"\(escape(attachment.path))\">"
                        + "<span class=\"file-icon\" data-icon=\"file\"></span>"
                        + "<span class=\"file-name\">\(escape(attachment.name))</span>"
                        + "<span class=\"file-size\">\(escape(ChatFormat.byteCount(attachment.size)))</span></button>"
                }
            }
            html += "</div>"
        }
        return html + "</div>"
    }

    private static func assistantHTML(text: String, created: Date, context: TranscriptRenderContext) -> String {
        "<div class=\"msg assistant\">" + bubble(kind: "assistant-bubble", source: text, created: created, context: context) + "</div>"
    }

    /// A bubble: the Markdown, its `created` time as tooltip and the Copy button shown on hover,
    /// which copies the Markdown source.
    private static func bubble(kind: String, source: String, created: Date, context: TranscriptRenderContext) -> String {
        "<div class=\"bubble \(kind)\" title=\"\(escape(ChatFormat.created(created)))\" data-source=\"\(escape(source))\">"
            + markdown(source, context: context)
            + "<button type=\"button\" class=\"bubble-copy\">Copy</button></div>"
    }

    private static func thinkingHTML(_ text: String, open: Bool, context: TranscriptRenderContext) -> String {
        "<details class=\"thinking\"\(open ? " open" : "")><summary>Thinking</summary>"
            + "<div class=\"thinking-body\">\(markdown(text, context: context))</div></details>"
    }

    private static func toolUseHTML(_ use: ToolUseItem, in state: TranscriptState, context: TranscriptRenderContext) -> String {
        let summary = ToolCardSummary.summary(name: use.name, server: use.server, input: use.input,
                                              projectRootPath: context.projectRootPath)
        let result = state.result(forToolUseID: use.toolUseID)
        let steps = state.stepCount(ofToolUseID: use.toolUseID)
        var html = "<div class=\"tool-card\"><div class=\"tool-header\">"
        html += "<span class=\"tool-icon\" data-icon=\"\(ToolCardSummary.icon(name: use.name, server: use.server))\"></span>"
        html += "<span class=\"tool-name\">\(escape(use.name))</span>"
        if let server = use.server {
            html += "<span class=\"badge\">MCP · \(escape(server))</span>"
        }
        html += "<span class=\"tool-summary\">\(escape(summary))</span>"
        if steps > 0 {
            // `<n> steps`, `1 step` for one (docs/chats.md › Tool cards).
            html += "<span class=\"tool-steps-count\">\(steps) \(steps == 1 ? "step" : "steps")</span>"
        }
        html += "<span class=\"tool-trailing\">"
        if let result {
            if result.isError { html += "<span class=\"tag-error\">Error</span>" }
        } else if context.chatIsRunning {
            html += "<span class=\"spinner\"></span>"
        }
        html += "</span></div><div class=\"tool-body\">"
        html += "<div class=\"tool-section tool-input\"><div class=\"tool-section-title\">Input</div>\(inputHTML(use, context: context))</div>"
        html += "<div class=\"tool-result-slot\"></div>"
        html += "<div class=\"tool-steps-section\"><div class=\"tool-section-title\">Steps</div><div class=\"tool-steps\"></div></div>"
        return html + "</div></div>"
    }

    /// `Input`: the input as JSON with 2-space indentation; for `Bash` the command as a shell code
    /// block, for `Edit` `old_string` and `new_string` as two code blocks, for `Write` `content` as
    /// a code block highlighted by the file extension.
    private static func inputHTML(_ use: ToolUseItem, context: TranscriptRenderContext) -> String {
        if use.server == nil {
            switch use.name {
            case "Bash":
                if let command = use.input.chatString("command") {
                    return markdown(fence(command, language: "sh"), context: context)
                }
            case "Edit":
                if let old = use.input.chatString("old_string"), let new = use.input.chatString("new_string") {
                    return markdown(fence(old, language: "") + "\n\n" + fence(new, language: ""), context: context)
                }
            case "Write":
                if let content = use.input.chatString("content") {
                    let path = use.input.chatString("file_path") ?? ""
                    return markdown(fence(content, language: languageWord(forPath: path)), context: context)
                }
            default:
                break
            }
        }
        return markdown(fence(use.input.chatPrettyJSON, language: "json"), context: context)
    }

    private static func toolResultHTML(_ result: ToolResultItem) -> String {
        var html = "<div class=\"tool-result\(result.isError ? " is-error" : "")\"><div class=\"tool-section-title\">Result</div>"
        if !result.text.isEmpty {
            let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > resultLineLimit {
                let head = lines.prefix(resultLineLimit).joined(separator: "\n")
                let rest = lines.dropFirst(resultLineLimit).joined(separator: "\n")
                html += "<pre class=\"result-text\"><span class=\"result-head\">\(escape(head))</span>"
                    + "<span class=\"result-rest\" hidden>\n\(escape(rest))</span></pre>"
                    + "<button type=\"button\" class=\"show-all\">Show All</button>"
            } else {
                html += "<pre class=\"result-text\">\(escape(result.text))</pre>"
            }
        }
        if !result.images.isEmpty {
            html += "<div class=\"attachments result-images\">"
            for image in result.images {
                html += imageHTML(image, title: image.name)
            }
            html += "</div>"
        }
        return html + "</div>"
    }

    /// The line of a `permissionRequest` item; an MCP tool shows its short name and the badge
    /// `MCP · <server>` (docs/chats.md › Item rendering).
    private static func permissionHTML(_ request: PermissionRequestItem) -> String {
        let (server, name) = ToolUseItem.splitToolName(request.toolName)
        var html = "<div class=\"perm-line\"><div class=\"perm-main\"><span class=\"perm-tool\">\(escape(name))</span>"
        if let server {
            html += " <span class=\"badge\">MCP · \(escape(server))</span>"
        }
        html += " · \(escape(ChatFormat.permissionStatus(request)))</div>"
        if let reason = request.reason, !reason.isEmpty {
            html += "<div class=\"perm-reason\">\(escape(reason))</div>"
        }
        return html + "</div>"
    }

    private static func questionsHTML(_ set: QuestionsItem, context: TranscriptRenderContext) -> String {
        var html = "<div class=\"questions-card\"><div class=\"questions-title\">Questions</div>"
        for question in set.questions {
            html += "<div class=\"question\"><div class=\"question-text\">"
                + markdown("\(question.label). \(question.question)", context: context) + "</div><ul class=\"options\">"
            for option in question.options {
                var line = option.label
                if let description = option.description, !description.isEmpty {
                    line += " — " + description
                }
                if option.label == question.recommended {
                    line += " (recommended)"
                }
                html += "<li>\(escape(line))</li>"
            }
            html += "</ul>"
            if let answer = set.answers[question.label] {
                html += "<div class=\"answer\">\(escape("Answer: " + answer))</div>"
            } else {
                html += "<div class=\"answer pending\">Not answered yet</div>"
            }
            html += "</div>"
        }
        return html + "</div>"
    }

    /// A thumbnail of a stored image, at most 240 × 240 pt; a click opens the image viewer.
    private static func imageHTML(_ attachment: Attachment, title: String) -> String {
        "<img class=\"thumb\" src=\"\(escape(attachmentURL(path: attachment.path)))\" alt=\"\(escape(attachment.name))\""
            + " title=\"\(escape(title))\" data-path=\"\(escape(attachment.path))\" loading=\"lazy\">"
    }

    // MARK: Helpers

    /// Markdown inside an element of the class `md` (docs/documentation-viewer.md › Styling).
    static func markdown(_ text: String, context: TranscriptRenderContext) -> String {
        let options = MarkdownRenderOptions(baseDirectory: "", projectRootPath: context.projectRootPath, stripFrontMatter: false)
        return "<div class=\"md\">" + MarkdownHTMLRenderer.render(text, options: options) + "</div>"
    }

    /// A fenced code block whose fence is longer than any backtick run of the code.
    static func fence(_ code: String, language: String) -> String {
        var longest = 0
        var run = 0
        for character in code {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let marks = String(repeating: "`", count: max(3, longest + 1))
        return marks + language + "\n" + code + (code.hasSuffix("\n") ? "" : "\n") + marks
    }

    /// The language word of a file for the code block of a `Write` input: its extension, lowercased
    /// (docs/chats.md › Tool cards, docs/documentation-viewer.md › Code blocks).
    static func languageWord(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.filter { $0.isLetter || $0.isNumber || "+#._-".contains($0) }
    }

    /// `hephaestus-attachment://attachment/<percent-encoded path relative to .hephaestus/>`
    /// (docs/documentation-viewer.md › Resource URL schemes).
    static func attachmentURL(path: String) -> String {
        "hephaestus-attachment://attachment/" + percentEncodedPath(path)
    }

    /// Each path component UTF-8 encoded, every byte outside `A`–`Z`, `a`–`z`, `0`–`9`, `-`, `.`,
    /// `_` and `~` written as `%` and two uppercase hexadecimal digits.
    static func percentEncodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { component in
            var out = ""
            for byte in component.utf8 {
                switch byte {
                case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                     UInt8(ascii: "~"):
                    out.append(Character(UnicodeScalar(byte)))
                default:
                    out += String(format: "%%%02X", byte)
                }
            }
            return out
        }.joined(separator: "/")
    }

    /// Text and attribute values escaped as in docs/documentation-viewer.md › HTML output.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
