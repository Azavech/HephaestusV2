import Foundation

/// The system prompts: the texts of the system prompt skills and their rendering
/// (docs/chats.md › System prompts, docs/skills.md › System prompt skills).
enum Prompts {
    private static let cache = PromptCache()

    /// The app's default text of a system prompt skill: the text of the body of its default
    /// SKILL.md.
    static func text(_ skill: PromptSkill) -> String {
        cache.text(skill)
    }

    /// The text of a skill's body: the body without the white space and line breaks at its start
    /// and at its end.
    static func text(ofBody body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces each `{{name}}` of `template` with its value in one pass; values are inserted as
    /// they are and are not scanned again. An unknown placeholder stays as written.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var result = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let name = String(afterOpen[..<close.lowerBound])
            if let value = values[name] {
                result += value
            } else {
                result += rest[open.lowerBound..<close.upperBound]
            }
            rest = afterOpen[close.upperBound...]
        }
        result += rest
        return result
    }

    /// The names of the placeholders of `template`, in order, as `render` reads them: what lies
    /// between a `{{` and the next `}}`.
    static func placeholderNames(in template: String) -> [String] {
        var names: [String] = []
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { break }
            names.append(String(afterOpen[..<close.lowerBound]))
            rest = afterOpen[close.upperBound...]
        }
        return names
    }

    /// Renders a system prompt skill with its own placeholders only; any other `{{…}}` stays as
    /// written, and a skill without placeholders is passed unchanged.
    static func render(_ skill: PromptSkill, _ text: String, _ values: [String: String]) -> String {
        let placeholders = Set(skill.placeholders)
        guard !placeholders.isEmpty else { return text }
        return render(text, values.filter { placeholders.contains($0.key) })
    }

    /// The system prompt skills of a chat kind, in their order in `--append-system-prompt`: the
    /// common skill, then the project, ticket or bundle skill; the common skill alone for a
    /// feedback chat; the ci skill alone for a CI chat.
    static func skills(of kind: ChatKind) -> [PromptSkill] {
        switch kind {
        case .project: return [.common, .project]
        case .ticket: return [.common, .ticket]
        case .bundle: return [.common, .bundle]
        case .feedback: return [.common]
        case .ci: return [.ci]
        }
    }

    // MARK: Rendered blocks (docs/chats.md › Rendered blocks)

    /// `{{environments}}`, for a project whose type is `goService`: a blank line, the line that
    /// introduces the environments, then `- <name>: <base URL>`, with `; invalid certificates
    /// allowed` when the environment accepts invalid certificates, or `- <name>` without a URL, per
    /// environment in their order, followed by `; <field>: <value>` for each Kubernetes field it
    /// sets, as stored, then the line that names the current working environment, `current`;
    /// `- none: the user adds them in Project Settings` without environments. Empty for the other
    /// types. The common prompt writes it at the end of its first paragraph, right after the
    /// project's type, so its blank line starts a paragraph of its own.
    static func environments(_ environments: [ProjectEnvironment], current: String?, type: ProjectType) -> String {
        guard type == .goService else { return "" }
        let lines = environments.map { environment in
            let fields = [("namespace", environment.namespace), ("deployment", environment.deployment),
                          ("Argo CD application", environment.argoCDApplication), ("kubeconfig file", environment.kubeconfig)]
            let details = fields.compactMap { label, value in value.map { "; \(label): \($0)" } }
            let address = environment.baseURL.map { ": \($0)" + (environment.allowInvalidCertificates ? "; invalid certificates allowed" : "") }
            return "- \(environment.name)" + (address ?? "") + details.joined()
        }
        let currentLine = lines.isEmpty ? nil : (current ?? environments.first?.name).map(currentEnvironmentLine)
        return "\n\nThe project's environments, where the Go service runs; the Kubernetes, Argo CD and API tools take an environment's name:\n"
            + (lines.isEmpty ? "- none: the user adds them in Project Settings" : (lines + [currentLine].compactMap { $0 }).joined(separator: "\n"))
    }

    /// The line of `{{environments}}` that names the current working environment
    /// (docs/projects.md › Current working environment).
    static func currentEnvironmentLine(_ name: String) -> String {
        "The current working environment is \(name): use it when the user names no environment."
    }

    /// The most lines and characters of `MEMORY.md` that `{{globalMemories}}` keeps: the limits of
    /// the Claude CLI for a `MEMORY.md` (Claude Code 2.1.309).
    static let globalMemoriesLineLimit = 200
    static let globalMemoriesCharacterLimit = 25_000

    /// `{{globalMemories}}`: the global memories folder and the text of its `MEMORY.md`, line breaks
    /// converted to LF and trimmed of white space and line breaks at both ends, at most 200 lines and
    /// 25,000 characters; nil `index` for a `MEMORY.md` that is missing or cannot be read
    /// (docs/chats.md › Rendered blocks).
    static func globalMemories(folder: String, index: String?) -> String {
        let text = ModelRules.normalizedLineBreaks(index ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "The global memories folder is \(folder). Its MEMORY.md has no line yet."
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var truncated = false
        if lines.count > globalMemoriesLineLimit {
            lines = Array(lines.prefix(globalMemoriesLineLimit))
            truncated = true
        }
        var kept = lines.joined(separator: "\n")
        if kept.count > globalMemoriesCharacterLimit {
            // Cut at the last line break before the limit.
            let limit = kept.index(kept.startIndex, offsetBy: globalMemoriesCharacterLimit)
            kept = kept[..<limit].lastIndex(of: "\n").map { String(kept[..<$0]) } ?? ""
            truncated = true
        }
        var block = "The global memories folder is \(folder). Its MEMORY.md:"
        if !kept.isEmpty {
            block += "\n" + kept
        }
        if truncated {
            block += "\n[Truncated: read \(folder)/MEMORY.md for the other lines.]"
        }
        return block
    }

    /// The text of `{{ticket}}` when the chat's ticket no longer exists.
    static let deletedTicket = "This ticket was deleted."
    /// The text of `{{bundle}}` when the chat's bundle no longer exists.
    static let deletedBundle = "This bundle was deleted."
    /// A ticket rendering is cut beyond this many characters.
    static let ticketLimit = 30_000
    /// The value of `--append-system-prompt` keeps the tickets of a bundle in full up to this
    /// many UTF-8 bytes.
    static let systemPromptLimit = 400_000

    /// The `Links:` value of `{{ticket}}`: the groups Depends on, Blocks and Related of the ticket
    /// detail's Links line, ids in ascending ticket number; `none` without links
    /// (docs/chats.md › Rendered blocks).
    static func linksText(_ ticket: Ticket) -> String {
        let groups = TicketLinkGroups(ticket).groups.map { group in
            "\(group.label) \(group.ids.joined(separator: ", "))"
        }
        return groups.isEmpty ? "none" : groups.joined(separator: " · ")
    }

    /// `{{ticket}}`: the ticket's current data, its links, attachment paths made absolute, its
    /// other chats (`chatLines`, one `- <chat id> (<kind>): <title>` each), cut beyond 30,000
    /// characters.
    static func ticket(_ ticket: Ticket, projectRoot: String, chatLines: [String]) -> String {
        var lines = [
            "ID: \(ticket.id)",
            "Title: \(ticket.title)",
            "Status: \(ticket.status.rawValue)",
            "Created: \(ISODate.string(from: ticket.created)) by \(ticket.createdBy.rawValue)",
            "Updated: \(ISODate.string(from: ticket.updated))",
            "Links: \(linksText(ticket))",
            "<description>",
        ]
        var description = ticket.description
        if description.hasSuffix("\n") { description.removeLast() }
        if !ticket.description.isEmpty { lines.append(description) }
        lines.append("</description>")
        if ticket.attachments.isEmpty {
            lines.append("Attachments: none")
        } else {
            lines.append("Attachments:")
            lines += ticket.attachments.map { attachmentLine($0, projectRoot: projectRoot) }
        }
        if ticket.comments.isEmpty {
            lines.append("Comments: none")
        } else {
            lines.append("Comments:")
            for comment in ticket.comments {
                lines += commentLines(comment, projectRoot: projectRoot)
            }
        }
        if chatLines.isEmpty {
            lines.append("Chats: none")
        } else {
            lines.append("Chats:")
            lines += chatLines
        }
        return truncatedTicket(lines.joined(separator: "\n"))
    }

    /// The lines of one comment in `{{ticket}}`: `- <created> by <author>:`, with
    /// ` (edited <updated>)` before the colon when it was edited, its text indented by two spaces,
    /// then its attachments.
    static func commentLines(_ comment: Comment, projectRoot: String) -> [String] {
        let edited = comment.updated.map { " (edited \(ISODate.string(from: $0)))" } ?? ""
        var lines = ["- \(ISODate.string(from: comment.created)) by \(comment.author.rawValue)\(edited):"]
        if !comment.text.isEmpty {
            lines += comment.text.components(separatedBy: "\n").map { "  " + $0 }
        }
        if !comment.attachments.isEmpty {
            lines.append("  Attachments:")
            lines += comment.attachments.map { "  " + attachmentLine($0, projectRoot: projectRoot) }
        }
        return lines
    }

    /// `- <name> (<type>, <size> bytes): <absolute path>`.
    static func attachmentLine(_ attachment: Attachment, projectRoot: String) -> String {
        "- \(attachment.name) (\(attachment.contentType), \(attachment.size) bytes): \(attachment.absolutePath(projectRoot: projectRoot))"
    }

    /// The `<input>` of a comment answer call (docs/chats.md › Answer input): `Ticket:`, the
    /// ticket's rendering, a blank line, `Comment to answer:` and the comment's lines.
    static func commentAnswerInput(ticketRendering: String, comment: Comment, projectRoot: String) -> String {
        (["Ticket:", ticketRendering, "", "Comment to answer:"] + commentLines(comment, projectRoot: projectRoot)).joined(separator: "\n")
    }

    /// A ticket rendering longer than 30,000 characters is cut at the last line break before
    /// 30,000 characters and followed by the line `[Truncated: call get_ticket for the full ticket.]`.
    static func truncatedTicket(_ text: String) -> String {
        guard text.count > ticketLimit else { return text }
        let prefix = text.prefix(ticketLimit)
        let kept = prefix.lastIndex(of: "\n").map { prefix[..<$0] } ?? prefix
        return kept + "\n[Truncated: call get_ticket for the full ticket.]"
    }

    /// One ticket of a bundle: its id and title, and its full rendering (nil when it no longer
    /// exists).
    struct BundleTicket: Sendable {
        var id: TicketID
        var title: String?
        var rendering: String?
    }

    /// `{{bundle}}`: the header, then each ticket after a blank line and `Ticket <n> of <count>:`.
    /// `fullCount` tickets are rendered in full; every later one as the single line
    /// `Ticket <n> of <count>: <id> <title> (call get_ticket for its content)`.
    static func bundle(id: BundleID, title: String, tickets: [BundleTicket], fullCount: Int) -> String {
        var text = "ID: \(id)\nTitle: \(title)\nTickets: \(tickets.map(\.id).joined(separator: ", "))"
        for (offset, ticket) in tickets.enumerated() {
            let number = offset + 1
            if offset < fullCount {
                text += "\n\nTicket \(number) of \(tickets.count):\n" + (ticket.rendering ?? deletedTicket)
            } else {
                // A deleted ticket's title is `(deleted)` (docs/chats.md › Rendered blocks).
                text += "\n\nTicket \(number) of \(tickets.count): \(ticket.id) \(ticket.title ?? "(deleted)") (call get_ticket for its content)"
            }
        }
        return text
    }

    /// An inherited memory folder named by `{{parentMemories}}`: the ancestor that gave it, the
    /// folder's absolute path and the text of its `MEMORY.md` (nil when it has none, or one that
    /// cannot be read).
    struct ParentMemoryFolder: Sendable, Equatable {
        var projectName: String
        var projectID: ProjectID
        var path: String
        var index: String?
    }

    /// The paragraph that starts `{{parentMemories}}`; it names the global memories folder of
    /// `{{globalMemories}}` as the other folder where Claude saves a memory.
    static let parentMemoriesIntro = "This project is a sub project: besides your own memories, you have the memories that Claude "
        + "saved for its parent projects, listed below nearest parent first. Read a memory file of these folders with your file "
        + "tools when it is relevant, as you read your own memories. Never write in these folders: save every new memory in your "
        + "own memory folder or, when it holds for every project, in the global memories folder."
    /// The line of a folder without usable `MEMORY.md`.
    static let noMemoryIndex = "This folder has no MEMORY.md."
    /// The CLI loads at most this many lines of its own `MEMORY.md` (Claude Code 2.1.309).
    static let memoryIndexLineLimit = 200
    /// …and at most this many UTF-16 code units of them.
    static let memoryIndexLengthLimit = 25_000

    /// `{{parentMemories}}` (docs/chats.md › Rendered blocks): empty without folders; otherwise a
    /// blank line, the intro paragraph, then one part per folder, nearest parent first, each after
    /// a blank line.
    static func parentMemories(_ folders: [ParentMemoryFolder]) -> String {
        guard !folders.isEmpty else { return "" }
        let parts = folders.map { folder in
            let header = "Memories of the project \(folder.projectName) (identifier \(folder.projectID)), in the folder \(folder.path):"
            let lines = folder.index.map { memoryIndexLines($0, folder: folder.path) } ?? ""
            return header + "\n" + (lines.isEmpty ? noMemoryIndex : lines)
        }
        return "\n\n" + ([parentMemoriesIntro] + parts).joined(separator: "\n\n")
    }

    /// The lines of a `MEMORY.md` in `{{parentMemories}}`: without byte order mark, line breaks
    /// converted to LF, leading and trailing white space and line breaks removed, then limited as
    /// the CLI limits its own `MEMORY.md`: the first 200 lines, then at most 25,000 UTF-16 code
    /// units, cut at the last line break within that length, or at that length without one; a cut
    /// text ends with a `[Truncated: …]` line. Empty when nothing is left.
    static func memoryIndexLines(_ text: String, folder: String) -> String {
        var text = ModelRules.normalizedLineBreaks(text)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var cut = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > memoryIndexLineLimit {
            text = lines.prefix(memoryIndexLineLimit).joined(separator: "\n")
            cut = true
        }
        if text.utf16.count > memoryIndexLengthLimit {
            // As the CLI's `lastIndexOf("\n", 25000)`: a line break at an offset of at most 25,000
            // units, other than at the start, ends the kept text; without one, the characters that
            // fit in 25,000 units are kept.
            var units = 0
            var fitting = text.startIndex
            var lineBreak: String.Index?
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character == "\n", units > 0, units <= memoryIndexLengthLimit {
                    lineBreak = index
                }
                units += character.utf16.count
                if units > memoryIndexLengthLimit { break }
                index = text.index(after: index)
                fitting = index
            }
            text = String(text[..<(lineBreak ?? fitting)])
            cut = true
        }
        return cut ? text + "\n[Truncated: read \(folder)/MEMORY.md for the rest.]" : text
    }

    /// The value of `--append-system-prompt` (docs/chats.md › Composition and rendering): the
    /// skills of the chat's kind, each rendered with its own placeholders, separated by a blank
    /// line. `texts` are the skills' texts read from the library; a skill missing from it takes the
    /// app's default text.
    static func systemPrompt(kind: ChatKind, values: [String: String], texts: [PromptSkill: String] = [:]) -> String {
        skills(of: kind).map { render($0, texts[$0] ?? text($0), values) }.joined(separator: "\n\n")
    }
}

/// Reads the default text of each system prompt skill once.
private final class PromptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [PromptSkill: String] = [:]

    func text(_ skill: PromptSkill) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let text = texts[skill] { return text }
        let body = InternalSkills.defaultContent(skill.rawValue).flatMap { try? SkillDocument.parse($0, folderName: skill.rawValue).body }
        let text = Prompts.text(ofBody: body ?? "")
        texts[skill] = text
        return text
    }
}
