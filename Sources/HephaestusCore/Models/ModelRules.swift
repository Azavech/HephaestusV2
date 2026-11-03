import Foundation

/// A broken write rule (docs/data-model.md › Write rules). The engine fails the call with the
/// error code of `kind` and `message`.
public struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The value is already used by another object.
        case conflict
        /// Any other rule, a duplicate inside the value itself included.
        case invalid
    }

    public var kind: Kind
    /// The field the rule belongs to.
    public var field: String
    /// The message returned to the caller, naming the field and the rule.
    public var message: String

    public init(kind: Kind = .invalid, field: String, message: String) {
        self.kind = kind
        self.field = field
        self.message = message
    }

    /// `<field>: <rule>.`, the form of `identifier: use 2 to 8 letters A–Z.`, for the rules whose
    /// message no document gives (docs/data-model.md › Write rules).
    public static func invalid(_ field: String, _ rule: String) -> ValidationError {
        ValidationError(kind: .invalid, field: field, message: "\(field): \(rule).")
    }

    public var description: String { message }
}

/// The write rules of the field tables of docs/data-model.md, with the messages of
/// docs/tickets.md, docs/projects.md and docs/workflow.md where those documents give one.
public enum ModelRules {
    // MARK: Text (docs/data-model.md › Text)

    /// True when `value` contains a line break.
    public static func containsLineBreak(_ value: String) -> Bool {
        value.contains(where: \.isNewline)
    }

    /// Trims a single-line value and checks it is one line of `length` characters.
    public static func singleLine(_ value: String, field: String, length: ClosedRange<Int>,
                                  error: @autoclosure () -> ValidationError) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containsLineBreak(trimmed), length.contains(trimmed.count) else { throw error() }
        return trimmed
    }

    /// Converts CR LF and lone CR to LF, as the engine does when it writes a multi-line value.
    public static func normalizedLineBreaks(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Names and titles

    /// Project `name`: single line, 1–100 characters.
    public static func projectName(_ value: String) throws -> String {
        try singleLine(value, field: "name", length: 1...100, error: .invalid("name", "use 1 to 100 characters on one line"))
    }

    /// Ticket `title`: single line, 1–200 characters (docs/tickets.md › Titles and naming).
    public static func ticketTitle(_ value: String) throws -> String {
        try singleLine(value, field: "title", length: 1...200,
                       error: ValidationError(field: "title", message: "Title must be 1 to 200 characters on one line."))
    }

    /// Bundle `title`: the rules of ticket titles (docs/tickets.md › Bundle rules).
    public static func bundleTitle(_ value: String) throws -> String {
        try ticketTitle(value)
    }

    /// Chat `title`: single line, 1–100 characters.
    public static func chatTitle(_ value: String) throws -> String {
        try singleLine(value, field: "title", length: 1...100, error: .invalid("title", "use 1 to 100 characters on one line"))
    }

    /// Ticket `description` written through the API: not empty after trimming.
    public static func ticketDescription(_ value: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(field: "description", message: "The description must not be empty.")
        }
        return normalizedLineBreaks(value)
    }

    /// A comment has a non-empty `text`, at least one attachment, or both.
    public static func comment(text: String, attachmentCount: Int) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0 else {
            throw ValidationError(field: "text", message: "A comment needs text or at least one attachment.")
        }
    }

    // MARK: Identifiers

    /// A project identifier typed by the user or sent by Claude: 2 to 8 letters, uppercased.
    public static func projectIdentifier(_ value: String) throws -> ProjectID {
        guard Identifiers.isTypedProjectID(value) else {
            throw ValidationError.invalid("identifier", "use 2 to 8 letters A–Z")
        }
        return value.uppercased()
    }

    /// A ticket id received from a client or Claude, uppercased (docs/tickets.md › Errors).
    public static func ticketID(_ value: String) throws -> TicketID {
        guard let id = Identifiers.normalizedTicketID(value) else {
            throw ValidationError(field: "ticketID", message: "\"\(value)\" is not a valid ticket id.")
        }
        return id
    }

    /// A bundle id received from a client or Claude, uppercased (docs/tickets.md › Errors).
    public static func bundleID(_ value: String) throws -> BundleID {
        guard let id = Identifiers.normalizedBundleID(value) else {
            throw ValidationError(field: "bundleID", message: "\"\(value)\" is not a valid bundle id.")
        }
        return id
    }

    /// A skill name: `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 64 characters.
    public static func skillName(_ value: String, field: String = "name") throws -> String {
        guard Identifiers.isSkillName(value) else {
            throw ValidationError.invalid(field, "use at most 64 lowercase letters, digits and single hyphens between them")
        }
        return value
    }

    // MARK: Paths (docs/data-model.md › Paths)

    /// A relative path of a project file: `/` separators, no leading or trailing `/`, no
    /// empty, `.` or `..` components.
    public static func isRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    public static func relativePath(_ value: String, field: String) throws -> String {
        guard isRelativePath(value) else {
            throw ValidationError.invalid(field, "use a relative path with / separators and no empty, . or .. component")
        }
        return value
    }

    /// An absolute path of a device file: starts with `/`, no trailing `/`, no `.` or `..`
    /// components (docs/data-model.md › Registry file).
    public static func isAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return false }
        if value == "/" { return true }
        guard !value.hasSuffix("/") else { return false }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// An absolute path, or a path starting with `~/` (settings `claudePath` and
    /// `skillsLibraryPath`).
    public static func isAbsoluteOrHomePath(_ value: String) -> Bool {
        value.hasPrefix("/") || (value.hasPrefix("~/") && value.count > 2)
    }

    // MARK: Project parts

    /// `ProjectCommands`: each value trimmed, an empty string stored as `null`.
    public static func normalizedCommand(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Web tab `url`: an absolute `http` or `https` URL, stored as entered after trimming.
    public static func webTabURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw ValidationError.invalid("url", "use an absolute http or https URL")
        }
        return trimmed
    }

    /// Web tab `title`: line breaks replaced by spaces, at most 500 characters, longer titles
    /// truncated.
    public static func normalizedWebTabTitle(_ value: String) -> String {
        let oneLine = normalizedLineBreaks(value).replacingOccurrences(of: "\n", with: " ")
        let singleLine = String(oneLine.map { $0.isNewline ? " " : $0 })
        return singleLine.count > 500 ? String(singleLine.prefix(500)) : singleLine
    }

    /// `ChatSettings.model`: non-empty, no white space.
    public static func chatModel(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ValidationError.invalid("model", "use a model value without white space")
        }
        return value
    }

    // MARK: Collections

    /// Fails with `invalid` when `values` holds the same element twice.
    public static func noDuplicates<T: Hashable>(_ values: [T], field: String,
                                                 message: (T) -> String = { "\($0) is listed more than once." }) throws {
        var seen = Set<T>()
        for value in values where !seen.insert(value).inserted {
            throw ValidationError(field: field, message: message(value))
        }
    }

    // MARK: Attachments

    /// Attachment `name`: one path component, and the stored file name `<id>-<name>` at most
    /// 255 UTF-8 bytes.
    public static func attachmentName(_ name: String, id: UUID) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ValidationError.invalid("name", "use one file name without /")
        }
        let stored = "\(id.uuidString)-\(name)"
        guard stored.utf8.count <= 255 else {
            throw ValidationError.invalid("name", "use a file name of at most \(255 - 37) UTF-8 bytes")
        }
        return name
    }

    /// The two forms of an attachment `path`: `attachments/<TICKET-ID>/<id>-<name>` or
    /// `chats/<CHAT-ID>/<id>-<name>`, with a file name of one component.
    public static func isAttachmentPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[2].isEmpty, parts[2] != ".", parts[2] != ".." else { return false }
        switch parts[0] {
        case "attachments": return Identifiers.isTicketID(parts[1])
        case "chats": return Identifiers.isUppercaseUUID(parts[1])
        default: return false
        }
    }

    // MARK: Device and settings

    /// Device `name`: trimmed; empty stores `null`; otherwise one line of 1 to 63 UTF-8 bytes.
    public static func deviceName(_ value: String?) throws -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard !containsLineBreak(trimmed), trimmed.utf8.count <= 63 else {
            throw ValidationError.invalid("name", "use one line of 1 to 63 UTF-8 bytes")
        }
        return trimmed
    }

    /// A port of the MCP or sync server: 1024–65535.
    public static func serverPort(_ value: Int, field: String) throws -> Int {
        guard (1024...65535).contains(value) else {
            throw ValidationError.invalid(field, "use a port from 1024 to 65535")
        }
        return value
    }

    /// `updateCheckIntervalMinutes`: 5–1440.
    public static func updateCheckInterval(_ value: Int) throws -> Int {
        guard (5...1440).contains(value) else {
            throw ValidationError.invalid("updateCheckIntervalMinutes", "use 5 to 1440 minutes")
        }
        return value
    }

    /// Remote device `port`: 1–65535.
    public static func remotePort(_ value: Int) throws -> Int {
        guard (1...65535).contains(value) else {
            throw ValidationError.invalid("port", "use a port from 1 to 65535")
        }
        return value
    }

    // MARK: Skills

    /// Skill `description` written by the engine: 1–1024 characters.
    public static func skillDescription(_ value: String) throws -> String {
        guard (1...1024).contains(value.count) else {
            throw ValidationError.invalid("description", "use 1 to 1024 characters")
        }
        return value
    }

    // MARK: Questions (docs/workflow.md › Validation, docs/chats.md › Posting questions)

    /// Checks a question set in the order of docs/chats.md › Posting questions and fails with
    /// the message of the first rule broken.
    public static func questions(_ questions: [Question]) throws {
        guard (1...26).contains(questions.count) else {
            throw ValidationError(field: "questions", message: "ask_questions needs 1 to 26 questions.")
        }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
        for (index, question) in questions.enumerated() {
            let letter = letters[index]
            guard question.label == letter else {
                throw ValidationError(field: "questions", message: "Question \(index + 1) must have the label \"\(letter)\".")
            }
            let label = question.label
            guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError(field: "questions", message: "Question \(label) has no text.")
            }
            guard (2...10).contains(question.options.count) else {
                throw ValidationError(field: "questions", message: "Question \(label) needs 2 to 10 options.")
            }
            var seen = Set<String>()
            for option in question.options {
                let trimmed = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
                    throw ValidationError(field: "questions", message: "Question \(label) has an empty or repeated option label.")
                }
            }
            for option in question.options {
                let trimmed = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !containsLineBreak(trimmed), trimmed.count <= 200 else {
                    throw ValidationError(field: "questions",
                                          message: "Question \(label) has an option label longer than 200 characters or on several lines.")
                }
            }
            guard question.options.contains(where: { $0.label == question.recommended }) else {
                throw ValidationError(field: "questions",
                                      message: "Question \(label): the recommended answer must be one of its option labels.")
            }
        }
    }

    /// The rules of a symbol request (docs/workflow.md › Symbol requests), in their order, on the
    /// trimmed suggestions and recommended symbol; `isSymbol` tells whether a name is in the
    /// symbol catalogue of the main device.
    public static func symbolRequest(question: String, suggestions: [String], recommended: String,
                                     isSymbol: (String) -> Bool) throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(field: "question", message: "ask_symbol needs a question.")
        }
        guard (2...10).contains(suggestions.count) else {
            throw ValidationError(field: "suggestions", message: "ask_symbol needs 2 to 10 suggestions.")
        }
        guard !suggestions.contains(where: \.isEmpty), Set(suggestions).count == suggestions.count else {
            throw ValidationError(field: "suggestions", message: "ask_symbol has an empty or repeated suggestion.")
        }
        if let unknown = suggestions.first(where: { !isSymbol($0) }) {
            throw ValidationError(field: "suggestions", message: "\(unknown) is not an SF Symbol of this Mac.")
        }
        guard suggestions.contains(recommended) else {
            throw ValidationError(field: "recommended", message: "ask_symbol: the recommended symbol must be one of the suggestions.")
        }
    }

    /// The rules of a color request (docs/workflow.md › Color requests), in their order, on the
    /// suggestions and the recommended suggestion with their colors trimmed.
    public static func colorRequest(question: String, suggestions: [ColorValue], recommended: ColorValue,
                                    lightAndDark: Bool) throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(field: "question", message: "ask_color needs a question.")
        }
        guard (2...10).contains(suggestions.count) else {
            throw ValidationError(field: "suggestions", message: "ask_color needs 2 to 10 suggestions.")
        }
        let values = suggestions + [recommended]
        if !lightAndDark, values.contains(where: \.isPair) {
            throw ValidationError(field: "suggestions",
                                  message: "ask_color needs one color per suggestion, or lightAndDark for light and dark pairs.")
        }
        if lightAndDark, values.contains(where: { !$0.isPair }) {
            throw ValidationError(field: "suggestions", message: "ask_color needs a light and dark pair per suggestion.")
        }
        if let unknown = suggestions.flatMap(\.colors).first(where: { !SystemColors.isColor($0) }) {
            throw ValidationError(field: "suggestions", message: "\(unknown) is not a hex color #RRGGBB or a system color name.")
        }
        for (index, suggestion) in suggestions.enumerated() where suggestions[..<index].contains(where: { $0.isSame(as: suggestion) }) {
            throw ValidationError(field: "suggestions", message: "ask_color has a repeated suggestion.")
        }
        guard suggestions.contains(where: { $0.isSame(as: recommended) }) else {
            throw ValidationError(field: "recommended", message: "ask_color: the recommended color must be one of the suggestions.")
        }
    }

    /// The rules of a sound request (docs/workflow.md › Sound requests), in their order, on the
    /// trimmed suggestions and recommended sound; `isSound` tells whether a name is in the sound
    /// catalogue of the main device for the chat's project.
    public static func soundRequest(question: String, suggestions: [String], recommended: String,
                                    isSound: (String) -> Bool) throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(field: "question", message: "ask_sound needs a question.")
        }
        guard (2...10).contains(suggestions.count) else {
            throw ValidationError(field: "suggestions", message: "ask_sound needs 2 to 10 suggestions.")
        }
        guard !suggestions.contains(where: \.isEmpty), Set(suggestions).count == suggestions.count else {
            throw ValidationError(field: "suggestions", message: "ask_sound has an empty or repeated suggestion.")
        }
        if let unknown = suggestions.first(where: { !isSound($0) }) {
            throw ValidationError(field: "suggestions", message: "\(unknown) is not a sound of this Mac or of the project.")
        }
        guard suggestions.contains(recommended) else {
            throw ValidationError(field: "recommended", message: "ask_sound: the recommended sound must be one of the suggestions.")
        }
    }
}
