import Foundation

/// The prompt resources and their rendering (docs/chats.md › System prompts).
enum Prompts {
    /// The resource names: `Sources/HephaestusCore/Resources/prompts/<name>.md`.
    enum Name: String, CaseIterable, Sendable {
        case common, project, ticket, bundle, feedback
        case implementTicket = "implement-ticket"
        case implementBundleTicket = "implement-bundle-ticket"
        case implementBundle = "implement-bundle"
        case namingTicket = "naming-ticket"
        case namingBundle = "naming-bundle"
        case namingChat = "naming-chat"
    }

    private static let cache = PromptCache()

    /// The text of a prompt: the content of its file without the final newline.
    static func text(_ name: Name) -> String {
        cache.text(name)
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

    /// The prompt of a chat kind, appended after the common prompt.
    static func kindPrompt(_ kind: ChatKind) -> Name {
        switch kind {
        case .project: return .project
        case .ticket: return .ticket
        case .bundle: return .bundle
        case .feedback: return .feedback
        }
    }

    // MARK: Rendered blocks (docs/chats.md › Rendered blocks)

    /// `{{projectCommands}}`: `- <kind>: <command>` per configured command in the order build,
    /// run, test; `- none: use the repository's own commands` when none is configured.
    static func projectCommands(_ commands: ProjectCommands) -> String {
        let lines = [("build", commands.build), ("run", commands.run), ("test", commands.test)].compactMap { kind, command in
            ModelRules.normalizedCommand(command).map { "- \(kind): \($0)" }
        }
        return lines.isEmpty ? "- none: use the repository's own commands" : lines.joined(separator: "\n")
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

    /// `{{ticket}}`: the ticket's current data, attachment paths made absolute, its other chats
    /// (`chatLines`, one `- <chat id> (<kind>): <title>` each), cut beyond 30,000 characters.
    static func ticket(_ ticket: Ticket, projectRoot: String, chatLines: [String]) -> String {
        func attachmentLine(_ attachment: Attachment) -> String {
            let path = (projectRoot as NSString).appendingPathComponent(".hephaestus/" + attachment.path)
            return "- \(attachment.name) (\(attachment.contentType), \(attachment.size) bytes): \(path)"
        }
        var lines = [
            "ID: \(ticket.id)",
            "Title: \(ticket.title)",
            "Status: \(ticket.status.rawValue)",
            "Created: \(ISODate.string(from: ticket.created)) by \(ticket.createdBy.rawValue)",
            "Updated: \(ISODate.string(from: ticket.updated))",
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
            lines += ticket.attachments.map(attachmentLine)
        }
        if ticket.comments.isEmpty {
            lines.append("Comments: none")
        } else {
            lines.append("Comments:")
            for comment in ticket.comments {
                let edited = comment.updated.map { " (edited \(ISODate.string(from: $0)))" } ?? ""
                lines.append("- \(ISODate.string(from: comment.created)) by \(comment.author.rawValue)\(edited):")
                if !comment.text.isEmpty {
                    lines += comment.text.components(separatedBy: "\n").map { "  " + $0 }
                }
                if !comment.attachments.isEmpty {
                    lines.append("  Attachments:")
                    lines += comment.attachments.map { "  " + attachmentLine($0) }
                }
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

    /// `{{feedbackContext}}`: the lines after the line `Feedback context:` of the first user
    /// message's text, unchanged; `- none` when that line is missing.
    static func feedbackContext(fromFirstMessage text: String?) -> String {
        guard let text else { return "- none" }
        let lines = text.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(of: "Feedback context:") else { return "- none" }
        return lines[(marker + 1)...].joined(separator: "\n")
    }

    /// The value of `--append-system-prompt`: the rendered common prompt, a blank line, and the
    /// rendered prompt of the chat's kind.
    static func systemPrompt(kind: ChatKind, values: [String: String]) -> String {
        render(text(.common), values) + "\n\n" + render(text(kindPrompt(kind)), values)
    }
}

/// Reads the prompt files once.
private final class PromptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [Prompts.Name: String] = [:]

    func text(_ name: Prompts.Name) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let text = texts[name] { return text }
        let url = Bundle.module.url(forResource: name.rawValue, withExtension: "md", subdirectory: "prompts")
        var text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if text.hasSuffix("\n") { text.removeLast() }
        texts[name] = text
        return text
    }
}
