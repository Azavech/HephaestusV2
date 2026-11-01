import Foundation

/// The ticket description template, its validation and the provisional title
/// (docs/tickets.md › Description template, Template validation, Titles and naming).
public enum TicketTemplate {
    /// The five headings, in order.
    public static let headings = ["Problem", "Current Behavior", "Expected", "Change", "Docs"]

    /// The text the New Ticket sheet starts with.
    public static let text = """
        Problem
        (Explain the problem)

        Current Behavior
        (Explain the current behaviour)

        Expected
        (Explain the behaviour that should be expected)

        Change
        (Explain what should change)

        Docs
        (List all docs files and paragraphs relevant to the issue)
        """

    /// The provisional title when the description has no usable line.
    public static let untitled = "Untitled Ticket"

    private static let patterns: [NSRegularExpression] = headings.map { heading in
        let escaped = NSRegularExpression.escapedPattern(for: heading)
        return try! NSRegularExpression(pattern: "^\\s*#*\\s*\(escaped)\\s*:?\\s*$", options: [.caseInsensitive])
    }

    /// Splits text into lines at LF, CR LF or CR.
    public static func lines(of text: String) -> [String] {
        ModelRules.normalizedLineBreaks(text).components(separatedBy: "\n")
    }

    /// The index in `headings` of the heading `line` is a heading line for, or nil.
    /// A heading line matches `^\s*#*\s*H\s*:?\s*$`, ignoring letter case.
    public static func headingIndex(of line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        return patterns.firstIndex { $0.firstMatch(in: line, options: [], range: range) != nil }
    }

    /// The heading that is missing or out of order, or nil when the description follows the
    /// template.
    public static func missingHeading(in description: String) -> String? {
        var k = 0
        for line in lines(of: description) where k < headings.count {
            let range = NSRange(line.startIndex..., in: line)
            if patterns[k].firstMatch(in: line, options: [], range: range) != nil {
                k += 1
            }
        }
        return k == headings.count ? nil : headings[k]
    }

    /// The message of an invalid description.
    public static func validationMessage(missing heading: String) -> String {
        "Description does not follow the ticket template: heading \"\(heading)\" is missing or out of order. "
            + "Use the headings Problem, Current Behavior, Expected, Change, Docs in this order, each alone on its line."
    }

    /// Checks a description written by Claude; fails with `invalid` and the message of
    /// docs/tickets.md › Template validation.
    public static func validate(_ description: String) throws {
        if let missing = missingHeading(in: description) {
            throw ValidationError(field: "description", message: validationMessage(missing: missing))
        }
    }

    /// The provisional title used until Haiku answers: the first line that is not empty after
    /// trimming and is not a heading line, trimmed, cut to its first 60 characters and trimmed
    /// again; `Untitled Ticket` when there is none. A heading line starts with `#` after
    /// trimming or is a template heading line.
    public static func provisionalTitle(for description: String) -> String {
        for line in lines(of: description) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), headingIndex(of: line) == nil else { continue }
            return String(trimmed.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return untitled
    }

    /// The provisional title of a bundle: its ticket titles joined with `, ` in bundle order
    /// and cut to their first 60 characters (docs/tickets.md › Bundle rules).
    public static func provisionalBundleTitle(ticketTitles: [String]) -> String {
        String(ticketTitles.joined(separator: ", ").prefix(60))
    }
}
