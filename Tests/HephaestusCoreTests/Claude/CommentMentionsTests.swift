import Foundation
import Testing
@testable import HephaestusCore

/// docs/tickets.md › Mentioning Claude: the mention rule and the completion range.
@Suite("Comment mentions")
struct CommentMentionsTests {
    @Test("@Claude in any letter case, as a whole word")
    func wholeWord() {
        for text in ["@Claude why?", "@claude, why", "(@CLAUDE)", "@Claude's view", "Hi @cLaUdE", "@Claude", "line one\n@Claude"] {
            #expect(CommentMentions.mentionsClaude(text), "\(text)")
        }
        for text in ["@Claudette", "name@claude", "Claude, why?", "@Clau", "@_Claude", "x@Claude", "@Claude_x", "@Claude2"] {
            #expect(!CommentMentions.mentionsClaude(text), "\(text)")
        }
    }

    @Test("Mentions in code spans and code blocks do not count")
    func code() {
        #expect(!CommentMentions.mentionsClaude("Only `@Claude` here"))
        #expect(!CommentMentions.mentionsClaude("Only ``a `@Claude` b`` here"))
        #expect(!CommentMentions.mentionsClaude("A span over\n`two @Claude\nlines` here"))
        #expect(!CommentMentions.mentionsClaude("```swift\nlet a = \"@Claude\"\n```"))
        #expect(!CommentMentions.mentionsClaude("~~~\n@Claude\n~~~"))
        #expect(!CommentMentions.mentionsClaude("Text\n\n    @Claude in an indented block"))
        #expect(CommentMentions.mentionsClaude("Text\n    @Claude continues the paragraph"))
        #expect(CommentMentions.mentionsClaude("`code` then @Claude"))
        #expect(CommentMentions.mentionsClaude("An unclosed ` backtick then @Claude"))
        #expect(CommentMentions.mentionsClaude("```\ncode\n```\n@Claude after the block"))
        #expect(CommentMentions.mentionsClaude("\\`@Claude\\` escaped backticks"))
    }

    @Test("The ranges in plain text include the @ and follow the character before the text")
    func ranges() {
        let text = "@Claude and @claude."
        let found = CommentMentions.ranges(in: text).map { String(text[$0]) }
        #expect(found == ["@Claude", "@claude"])
        #expect(CommentMentions.ranges(in: "@Claude", after: "a").isEmpty)
        #expect(CommentMentions.ranges(in: "@Claude", after: " ").count == 1)
    }

    @Test("Completion: the @ and the letters before the caret that start Claude")
    func completion() {
        func range(_ text: String, _ caretOffset: Int? = nil) -> String? {
            let caret = text.index(text.startIndex, offsetBy: caretOffset ?? text.count)
            return CommentMentions.completionRange(in: text, caret: caret).map { String(text[$0]) }
        }
        #expect(range("@") == "@")
        #expect(range("Hi @cl") == "@cl")
        #expect(range("(@CLAU") == "@CLAU")
        #expect(range("@Claude") == "@Claude")
        #expect(range("@Claudes") == nil)
        #expect(range("@x") == nil)
        #expect(range("mail@cl") == nil)
        #expect(range("@cl ") == nil)
        #expect(range("@clau", 3) == nil)
        #expect(range("") == nil)
    }
}
