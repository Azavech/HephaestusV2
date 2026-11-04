// OWNER: ui-chats — the texts of the transcript and the chat views: durations, costs, captions, tool
// card summaries and icons, status lines (docs/chats.md › Item rendering, › Tool cards, › Chat
// states).
import Foundation
import HephaestusCore
import Observation

/// Formats of docs/chats.md › Item rendering.
enum ChatFormat {
    /// `<duration>` from `durationMs`: below 60 s one decimal and ` s` (`3.5 s`); below one hour
    /// `<m> min <s> s` (`2 min 5 s`); else `<h> h <m> min` (`1 h 2 min`).
    static func duration(milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        let tenths = (ms + 50) / 100
        if tenths < 600 {
            return "\(tenths / 10).\(tenths % 10) s"
        }
        let seconds = ms / 1000
        if seconds < 3600 {
            return "\(seconds / 60) min \(seconds % 60) s"
        }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }

    /// `<cost>`: `< $0.01` below 0.01, else `$` and two decimals (`$0.42`).
    static func cost(_ usd: Double) -> String {
        if usd < 0.01 { return "< $0.01" }
        return "$" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), usd)
    }

    /// The footer line of a `result` item: `Done · <duration> · session cost <cost>`, or
    /// `Error · <duration> · <summary>`; the cost part is left out when `costUSD` is null.
    static func resultLine(_ result: ResultItem) -> String {
        var parts = [result.isError ? "Error" : "Done", duration(milliseconds: result.durationMs)]
        if result.isError {
            if let summary = result.summary, !summary.isEmpty { parts.append(summary) }
        } else if let usd = result.costUSD {
            parts.append("session cost " + cost(usd))
        }
        return parts.joined(separator: " · ")
    }

    /// The tooltip of a bubble: its `created` time in local time.
    static func created(_ date: Date) -> String {
        createdFormatter.string(from: date)
    }

    private static let createdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    /// `<Claude name>` of an assistant caption and of the author of a comment Claude added from a
    /// chat (docs/chats.md › Item rendering, docs/tickets.md › Comments): `Claude (<model> ·
    /// <effort>)`, `Claude (<model>)` without effort, `Claude` without model; `<model>` is named
    /// with `models` (docs/chats.md › Model names).
    static func claudeName(model: String?, effort: Effort?, models: [ClaudeModel]) -> String {
        guard let model else { return "Claude" }
        let name = ClaudeModel.name(of: model, in: models)
        guard let effort else { return "Claude (\(name))" }
        return "Claude (\(name) · \(effort.label))"
    }

    /// `<created>` of a bubble's caption: only the short time for a message created on the day of
    /// `today`, else the abbreviated date and short time as in the ticket list's Created column, in
    /// the user's locale and time zone.
    static func captionTime(_ date: Date, today: Date, calendar: Calendar = .autoupdatingCurrent,
                            locale: Locale = .autoupdatingCurrent) -> String {
        let dateStyle: Date.FormatStyle.DateStyle = calendar.isDate(date, inSameDayAs: today) ? .omitted : .abbreviated
        return date.formatted(Date.FormatStyle(date: dateStyle, time: .shortened, locale: locale, calendar: calendar,
                                               timeZone: calendar.timeZone))
    }

    /// A file-style byte count, for example `12 KB`.
    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `m:ss` of the running status line.
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// The label of a permission decision line (docs/chats.md › Item rendering).
    static func permissionStatus(_ request: PermissionRequestItem) -> String {
        guard let decision = request.decision else { return "Waiting for permission" }
        guard let decidedBy = request.decidedBy else { return "Cancelled" }
        switch decision {
        case .allow: return "Allowed once by \(decidedBy)"
        case .allowAlways: return "Always allowed by \(decidedBy)"
        case .deny: return "Denied by \(decidedBy)"
        }
    }

    /// The kind as a chip and group title.
    static func kindTitle(_ kind: ChatKind) -> String {
        switch kind {
        case .project: return "Project"
        case .ticket: return "Ticket"
        case .bundle: return "Bundle"
        case .feedback: return "Feedback"
        }
    }

    /// The transcript placeholder of an empty chat (docs/chats.md › Empty transcript); nil for a
    /// feedback chat, which is never empty.
    static func placeholder(kind: ChatKind, projectName: String, ticketID: String?, bundleID: String?) -> String? {
        switch kind {
        case .project: return "Ask Claude to plan, create tickets or work on \(projectName)."
        case .ticket: return "Ask Claude about \(ticketID ?? ""), or click Implement."
        case .bundle: return "Ask Claude about \(bundleID ?? ""), or click Implement All."
        case .feedback: return nil
        }
    }
}

/// The current day of the Mac, which the captions of the transcript depend on (docs/chats.md › Web
/// view and bridge): its start, updated when the day changes, at midnight or with the time zone.
@MainActor @Observable
final class TranscriptDay {
    static let shared = TranscriptDay()

    private(set) var today = Calendar.autoupdatingCurrent.startOfDay(for: Date())

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        if day != today { today = day }
    }
}

/// The running states of a chat (docs/chats.md › Chat states): starting, running and
/// waitingPermission.
extension ChatState {
    var isChatRunning: Bool {
        self == .starting || self == .running || self == .waitingPermission
    }
}

/// A working chat (docs/chats.md › Chat states): running, or its Claude process has background
/// work running. The quit and restart checks, the idle check before an automatic update and the
/// removal of a project count working chats.
extension ChatMeta {
    var isWorking: Bool {
        state.isChatRunning || backgroundWork
    }
}

/// Which attachments show as images (docs/tickets.md › Showing attachments).
enum ChatAttachmentKind {
    static let imageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/heic", "image/heif", "image/tiff", "image/bmp", "image/webp",
    ]

    static func isImage(_ contentType: String) -> Bool {
        imageTypes.contains(contentType.lowercased())
    }
}

/// The header of a tool card: its icon and one-line summary (docs/chats.md › Tool cards).
enum ToolCardSummary {
    /// Summaries are cut at 120 characters with `…`.
    static let maximumLength = 120

    /// The inline SVG drawing of `chat.js` that the card shows.
    static func icon(name: String, server: String?) -> String {
        if server != nil { return "plug" }
        switch name {
        case "Bash": return "terminal"
        case "Read", "Write", "Edit", "NotebookEdit": return "document"
        case "Glob", "Grep": return "magnifier"
        case "WebFetch", "WebSearch": return "globe"
        case "Agent", "Task": return "people"
        case "TodoWrite": return "checklist"
        default: return "wrench"
        }
    }

    /// The one-line summary of a tool call; `projectRootPath` makes file paths inside the project
    /// relative to it.
    static func summary(name: String, server: String?, input: JSONValue, projectRootPath: String?) -> String {
        let text: String
        if server != nil {
            text = generic(input)
        } else {
            switch name {
            case "Bash":
                text = input.chatString("command").map(firstLine) ?? generic(input)
            case "Read", "Write", "Edit", "NotebookEdit":
                if let path = input.chatString("file_path") ?? input.chatString("notebook_path") {
                    text = relative(path, to: projectRootPath)
                } else {
                    text = generic(input)
                }
            case "Glob", "Grep":
                if let pattern = input.chatString("pattern") {
                    if let path = input.chatString("path"), !path.isEmpty {
                        text = pattern + " in " + path
                    } else {
                        text = pattern
                    }
                } else {
                    text = generic(input)
                }
            case "WebFetch":
                text = input.chatString("url") ?? generic(input)
            case "WebSearch":
                text = input.chatString("query") ?? generic(input)
            case "Agent", "Task":
                text = input.chatString("description") ?? generic(input)
            case "TodoWrite":
                if case .array(let todos)? = input.chatField("todos") {
                    text = "\(todos.count) todos"
                } else {
                    text = generic(input)
                }
            default:
                text = generic(input)
            }
        }
        return cut(text)
    }

    /// The generic rule: the first of these input fields that holds a non-empty string, else the
    /// input as compact JSON.
    static let genericFields = [
        "command", "file_path", "path", "pattern", "url", "query", "description", "prompt", "name", "title", "ticketID",
        "bundleID", "projectID",
    ]

    static func generic(_ input: JSONValue) -> String {
        for field in genericFields {
            if let value = input.chatString(field), !value.isEmpty { return firstLine(value) }
        }
        return input.chatCompactJSON
    }

    static func cut(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        guard single.count > maximumLength else { return single }
        return String(single.prefix(maximumLength)) + "…"
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// A path relative to the project root when it lies inside it.
    static func relative(_ path: String, to root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

extension JSONValue {
    /// The value of an object field.
    func chatField(_ key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// The string value of an object field.
    func chatString(_ key: String) -> String? {
        guard case .string(let value)? = chatField(key) else { return nil }
        return value
    }

    /// Compact JSON, keys in code point order.
    var chatCompactJSON: String {
        var out = ""
        write(to: &out, indent: nil)
        return out
    }

    /// JSON with 2-space indentation, keys in code point order.
    var chatPrettyJSON: String {
        var out = ""
        write(to: &out, indent: 0)
        return out
    }

    /// Writes the value; `indent` nil writes compact JSON, else the current depth.
    private func write(to out: inout String, indent: Int?) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value): out += Self.scalar(value)
        case .string(let value): out += Self.quoted(value)
        case .array(let values):
            guard !values.isEmpty else { out += "[]"; return }
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                if let indent { out += "\n" + String(repeating: "  ", count: indent + 1) }
                value.write(to: &out, indent: indent.map { $0 + 1 })
            }
            if let indent { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let object):
            guard !object.isEmpty else { out += "{}"; return }
            out += "{"
            for (index, key) in object.keys.sorted(by: { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }).enumerated() {
                if index > 0 { out += "," }
                if let indent { out += "\n" + String(repeating: "  ", count: indent + 1) }
                out += Self.quoted(key) + (indent == nil ? ":" : ": ")
                object[key]!.write(to: &out, indent: indent.map { $0 + 1 })
            }
            if let indent { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    /// A number as JSON text.
    private static func scalar(_ value: Double) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// A string as a JSON string literal.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
