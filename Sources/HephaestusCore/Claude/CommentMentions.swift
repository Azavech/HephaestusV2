import Foundation

/// The mentions of Claude in the text of a ticket comment (docs/tickets.md › Mentioning Claude):
/// `@Claude` in any letter case as a whole word, outside code spans and code blocks. The engine
/// starts a comment answer for a new comment of the user that mentions Claude; the native
/// Markdown view highlights the mentions and the comment composer completes them.
public enum CommentMentions {
    /// The name that follows `@`.
    public static let name = "Claude"
    /// The text the completion inserts.
    public static let completion = "@Claude "

    // MARK: Markdown text

    /// Whether the Markdown text mentions Claude outside code spans, fenced code blocks and
    /// indented code blocks.
    public static func mentionsClaude(_ markdown: String) -> Bool {
        prose(of: markdown).contains { !ranges(in: $0).isEmpty }
    }

    /// The paragraphs of the text outside code blocks, each with its code spans replaced by a
    /// space: the text in which mentions count.
    static func prose(of markdown: String) -> [String] {
        var paragraphs: [String] = []
        var paragraph: [String] = []
        var fence: (character: Character, length: Int)?
        var previousBlank = true
        var inIndentedCode = false

        func closeParagraph() {
            if !paragraph.isEmpty {
                paragraphs.append(withoutCodeSpans(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            let blank = line.allSatisfy { $0 == " " || $0 == "\t" }
            if let open = fence {
                if let close = fenceRun(line), close.character == open.character, close.length >= open.length,
                   close.rest.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fence = nil
                }
                previousBlank = false
                continue
            }
            if blank {
                closeParagraph()
                previousBlank = true
                continue
            }
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if indented, paragraph.isEmpty, previousBlank || inIndentedCode {
                inIndentedCode = true
                previousBlank = false
                continue
            }
            inIndentedCode = false
            previousBlank = false
            if let run = fenceRun(line), run.character == "~" || !run.rest.contains("`") {
                closeParagraph()
                fence = (run.character, run.length)
                continue
            }
            paragraph.append(line)
        }
        closeParagraph()
        return paragraphs
    }

    /// A fence line: at most 3 spaces, then 3 or more backticks or tildes, and the rest of the
    /// line.
    private static func fenceRun(_ line: String) -> (character: Character, length: Int, rest: Substring)? {
        let spaces = line.prefix { $0 == " " }
        guard spaces.count <= 3 else { return nil }
        let afterSpaces = line.dropFirst(spaces.count)
        guard let first = afterSpaces.first, first == "`" || first == "~" else { return nil }
        let run = afterSpaces.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count, afterSpaces.dropFirst(run.count))
    }

    /// The text with each code span, from a backtick string to the next backtick string of the
    /// same length, replaced by a space. A backtick string without such a closing string stays as
    /// text, and so does a backtick escaped with `\`.
    static func withoutCodeSpans(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                result.append(character)
                result.append(characters[index + 1])
                index += 2
                continue
            }
            guard character == "`" else {
                result.append(character)
                index += 1
                continue
            }
            var length = 0
            while index + length < characters.count, characters[index + length] == "`" { length += 1 }
            var search = index + length
            var closing: Int?
            while search < characters.count {
                guard characters[search] == "`" else {
                    search += 1
                    continue
                }
                var run = 0
                while search + run < characters.count, characters[search + run] == "`" { run += 1 }
                if run == length {
                    closing = search
                    break
                }
                search += run
            }
            if let closing {
                result.append(" ")
                index = closing + length
            } else {
                result.append(String(repeating: "`", count: length))
                index += length
            }
        }
        return result
    }

    // MARK: Plain text

    /// Letters, digits and `_` join a mention to the word around it.
    public static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    /// The ranges of the mentions in plain text, `@` included, in order. `previous` is the
    /// character before the text, nil at the start of a text.
    public static func ranges(in text: String, after previous: Character? = nil) -> [Range<String.Index>] {
        guard text.contains("@") else { return [] }
        var result: [Range<String.Index>] = []
        var before = previous
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "@", before.map(isWordCharacter) != true {
                let start = text.index(after: index)
                if let end = text.index(start, offsetBy: name.count, limitedBy: text.endIndex),
                   text[start..<end].lowercased() == name.lowercased(),
                   end == text.endIndex || !isWordCharacter(text[end]) {
                    result.append(index..<end)
                    before = text[text.index(before: end)]
                    index = end
                    continue
                }
            }
            before = character
            index = text.index(after: index)
        }
        return result
    }

    // MARK: Completion

    /// The `@` and the letters typed after it that end at `caret`, when the `@` starts a word and
    /// the letters are the start of `Claude` in any letter case, and the word does not go on after
    /// the caret: the range the completion replaces with `@Claude `. Nil otherwise.
    public static func completionRange(in text: String, caret: String.Index) -> Range<String.Index>? {
        guard caret >= text.startIndex, caret <= text.endIndex else { return nil }
        if caret < text.endIndex, isWordCharacter(text[caret]) { return nil }
        var start = caret
        while start > text.startIndex, isWordCharacter(text[text.index(before: start)]) {
            start = text.index(before: start)
        }
        guard start > text.startIndex else { return nil }
        let at = text.index(before: start)
        guard text[at] == "@" else { return nil }
        if at > text.startIndex, isWordCharacter(text[text.index(before: at)]) { return nil }
        let typed = text[start..<caret].lowercased()
        guard name.lowercased().hasPrefix(typed) else { return nil }
        return at..<caret
    }
}
