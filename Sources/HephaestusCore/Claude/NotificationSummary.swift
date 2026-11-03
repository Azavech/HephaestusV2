import Foundation

/// What a summary call summarizes, with its input (docs/chats.md › Summary call).
public enum NotificationSubject: Sendable, Hashable {
    /// A finished turn: Claude's last reply of the turn.
    case reply(String)
    /// A chat waiting for permission: the oldest pending permission request.
    case permission(toolName: String, input: JSONValue)
    /// A chat waiting for answers: the questions of the set that is not completed.
    case questions([Question])
    /// A chat waiting for answers: the question of the symbol request without answer.
    case symbol(question: String)
    /// A chat waiting for answers: the question of the color request without answer.
    case color(question: String)
    /// A chat waiting for answers: the question of the sound request without answer.
    case sound(question: String)
    /// A chat waiting for answers: the question of the shortcut request without answer.
    case shortcut(question: String)
    /// A chat waiting for answers: the question of the font request without answer.
    case font(question: String)
    /// A chat waiting for answers: the question of the animation request without answer.
    case animation(question: String)
}

/// Writes the detail of a chat notification (docs/chats.md › Notifications). A nil answer gives
/// the fallback detail. The engine calls it, so that tests can provide another implementation
/// (docs/architecture.md › HephaestusCore folders).
public protocol NotificationSummarizer: Sendable {
    /// The cleaned summary for `subject` (docs/chats.md › Summary call), or nil after a failure,
    /// a timeout or an empty answer.
    func summary(for subject: NotificationSubject) async -> String?
}

/// The summary call of the app: one `claude -p --model haiku` call per notification with the
/// prompt notification-summary, at most 2 at once besides the naming calls, 30 s timeout
/// (docs/chats.md › Summary call).
public struct HaikuNotificationSummarizer: NotificationSummarizer {
    let runtime: HaikuNamingRuntime

    public init() {
        runtime = HaikuNamingRuntime()
    }

    /// Connects the summarizer to the engine whose CLI, environment and data directory it uses.
    func attach(to engine: Engine) {
        runtime.attach(engine)
    }

    public func summary(for subject: NotificationSubject) async -> String? {
        let what = "summary of a notification"
        guard let output = await runtime.run(prompt: .notificationSummary, input: Self.input(for: subject), what: what) else {
            return nil
        }
        let outcome = Self.summary(fromOutput: output.standardOutput)
        if let failure = outcome.failure {
            output.log.warn(.claude, "\(what) failed: \(failure)")
        }
        return outcome.summary
    }

    /// The maximum length of a summary.
    static let maximumLength = 150

    // MARK: Inputs (docs/chats.md › Summary call)

    /// The `<input>` argument: the label line, then the subject's text cut at 4,000 characters.
    static func input(for subject: NotificationSubject) -> String {
        let label: String
        let body: String
        switch subject {
        case .reply(let reply):
            label = "Claude's reply:"
            body = reply
        case .permission(let toolName, let input):
            label = "Permission request:"
            let json = (try? EngineJSON.encode(input)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
            body = "Tool: \(toolName)\nInput: \(json)"
        case .questions(let questions):
            label = "Questions:"
            body = questions.sorted { $0.label < $1.label }.map { "\($0.label): \($0.question)" }.joined(separator: "\n")
        case .symbol(let question):
            label = "Symbol request:"
            body = question
        case .color(let question):
            label = "Color request:"
            body = question
        case .sound(let question):
            label = "Sound request:"
            body = question
        case .shortcut(let question):
            label = "Shortcut request:"
            body = question
        case .font(let question):
            label = "Font request:"
            body = question
        case .animation(let question):
            label = "Animation request:"
            body = question
        }
        return label + "\n" + String(body.prefix(HaikuTitleNamer.inputLimit))
    }

    // MARK: Output cleanup (docs/chats.md › Summary call)

    /// Step 1: stdout parsed as one JSON object whose `is_error` is not true; its `result`
    /// cleaned by steps 2 to 6. Returns the summary, or why the fallback detail is used.
    static func summary(fromOutput output: Data) -> (summary: String?, failure: String?) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: output), let object = value.objectValue else {
            return (nil, "the output is not a JSON object")
        }
        if object["is_error"]?.claudeBool == true { return (nil, "is_error is true") }
        guard let result = object["result"]?.stringValue else { return (nil, "the output has no result") }
        guard let summary = cleanSummary(result) else { return (nil, "the summary is empty") }
        return (summary, nil)
    }

    /// Steps 2 to 6: the trimmed result with each run of white space replaced by one space, a
    /// leading `Summary:` removed, surrounding quote characters removed repeatedly, cut at the last
    /// space at or before 150 characters; nil when nothing is left.
    static func cleanSummary(_ result: String) -> String? {
        var text = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let prefix = "summary:"
        if String(text.prefix(prefix.count)).lowercased() == prefix {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        var changed = true
        while changed {
            changed = false
            if let first = text.first, HaikuTitleNamer.quoteCharacters.contains(first) {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            if let last = text.last, HaikuTitleNamer.quoteCharacters.contains(last) {
                text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        text = cut(text, to: maximumLength)
        return text.isEmpty ? nil : text
    }

    /// Cuts a text longer than `maximum` characters at the last space at or before the
    /// `maximum`-th character, or at `maximum` characters when there is none, and trims it.
    static func cut(_ text: String, to maximum: Int) -> String {
        guard text.count > maximum else { return text }
        let characters = Array(text)
        let cut = (0...maximum).last { characters[$0] == " " } ?? maximum
        return String(characters[..<cut]).trimmingCharacters(in: .whitespaces)
    }
}
