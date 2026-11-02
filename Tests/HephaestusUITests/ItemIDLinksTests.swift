import Foundation
import HephaestusCore
import HephaestusText
import Testing
@testable import HephaestusUI

/// docs/chats.md › Item rendering, › Tool cards, › Links, images and files; docs/tickets.md ›
/// Ticket detail: ticket and bundle ids of the device's projects as links.
@Suite("Ticket and bundle id links")
struct ItemIDLinksTests {
    static let created = Date(timeIntervalSince1970: 1_800_000_000)
    static let heph21 = "<a class=\"md-id\" href=\"hephaestus-id:HEPH-21\">HEPH-21</a>"
    static let hephB14 = "<a class=\"md-id\" href=\"hephaestus-id:HEPH-B14\">HEPH-B14</a>"
    static let context = TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil,
                                                 projectIdentifiers: ["HEPH"])

    func html(_ item: ChatItem, context: TranscriptRenderContext = Self.context) -> String {
        TranscriptRenderer.fragment(for: item, in: TranscriptState(), context: context).html
    }

    @Test("Bubbles and streaming bubbles link ids of the device's projects only")
    func bubbles() {
        let text = "HEPH-21 is next, then HEPH-B14 and DEMO-3."
        let items: [ChatItem] = [
            .user(UserItem(id: "u", created: Self.created, text: text, sender: "MacBook")),
            .assistant(AssistantItem(id: "a", created: Self.created, text: text, messageID: "m")),
            .thinking(ThinkingItem(id: "t", created: Self.created, text: text)),
        ]
        for item in items {
            #expect(html(item).contains("<p>\(Self.heph21) is next, then \(Self.hephB14) and DEMO-3.</p>"), "\(item)")
            #expect(!html(item, context: TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil))
                .contains("md-id"))
        }
        #expect(TranscriptRenderer.streamHTML(kind: .text, text: text, context: Self.context).contains(Self.heph21))
        #expect(TranscriptRenderer.streamHTML(kind: .thinking, text: text, context: Self.context).contains(Self.hephB14))
        // The Copy button still copies the Markdown source.
        #expect(html(items[1]).contains("data-source=\"\(text)\""))
    }

    @Test("Tool cards link ids in the summary, the input code blocks and the result")
    func toolCards() {
        let mcp = ToolUseItem(id: "m", created: Self.created, toolUseID: "tu1", name: "get_ticket", server: "hephaestus",
                              input: ["ticketID": "HEPH-21"])
        let card = html(.toolUse(mcp))
        #expect(card.contains("<span class=\"tool-summary\">\(Self.heph21)</span>"))
        #expect(card.contains("<span class=\"tok-string\">&quot;</span>\(Self.heph21)<span class=\"tok-string\">&quot;</span>"))
        let bash = ToolUseItem(id: "b", created: Self.created, toolUseID: "tu2", name: "Bash",
                               input: ["command": "git log --grep HEPH-B14", "description": "Log"])
        let bashCard = html(.toolUse(bash))
        #expect(bashCard.contains("<span class=\"tool-summary\">git log --grep \(Self.hephB14)</span>"))
        #expect(bashCard.contains("<div class=\"md\"><div class=\"md-codeblock\">"))
        #expect(bashCard.components(separatedBy: Self.hephB14).count == 3)
        let edit = ToolUseItem(id: "e", created: Self.created, toolUseID: "tu3", name: "Edit",
                               input: ["file_path": "/tmp/a.md", "old_string": "HEPH-21", "new_string": "HEPH-B14"])
        let editCard = html(.toolUse(edit))
        #expect(editCard.contains(Self.heph21) && editCard.contains(Self.hephB14))
        let write = ToolUseItem(id: "w", created: Self.created, toolUseID: "tu4", name: "Write",
                                input: ["file_path": "/tmp/a.swift", "content": "// HEPH-21\n"])
        #expect(html(.toolUse(write)).contains(Self.heph21))
        let result = ToolResultItem(id: "r", created: Self.created, toolUseID: "tu2", text: "abc HEPH-21 <x>")
        #expect(html(.toolResult(result)).contains("<pre class=\"result-text\">abc \(Self.heph21) &lt;x&gt;</pre>"))
        let long = (1...201).map { $0 == 201 ? "HEPH-B14" : "HEPH-21" }.joined(separator: "\n")
        let longHTML = html(.toolResult(ToolResultItem(id: "r2", created: Self.created, toolUseID: "tu2", text: long)))
        #expect(longHTML.contains("<span class=\"result-rest\" hidden>\n\(Self.hephB14)</span>"))
    }

    @Test("Tool card input code blocks are unchanged without identifiers")
    func toolCardsWithoutIdentifiers() {
        let bash = ToolUseItem(id: "b", created: Self.created, toolUseID: "tu2", name: "Bash", input: ["command": "echo HEPH-21"])
        let card = html(.toolUse(bash), context: TranscriptRenderContext(projectRootPath: nil, chatIsRunning: false, displayedQuestion: nil))
        #expect(card.contains("<div class=\"md\"><div class=\"md-codeblock\">\n<div class=\"md-codeblock-bar\"><span class=\"md-codeblock-lang\">sh</span>"))
        #expect(card.contains(" HEPH-21\n</code></pre>"))
        #expect(!card.contains("md-id"))
    }

    @Test("Permission lines link ids in the tool line and the reason")
    func permissionLines() {
        let request = PermissionRequestItem(id: "p", created: Self.created, requestID: "1", toolName: "mcp__hephaestus__delete_ticket",
                                            input: ["ticketID": "HEPH-21"], reason: "Deleting HEPH-21 needs approval",
                                            decision: nil, decidedBy: nil)
        let line = html(.permissionRequest(request))
        #expect(line.contains("<div class=\"perm-reason\">Deleting \(Self.heph21) needs approval</div>"))
        let named = PermissionRequestItem(id: "p2", created: Self.created, requestID: "2", toolName: "HEPH-B14", reason: nil)
        #expect(html(.permissionRequest(named)).contains("<span class=\"perm-tool\">\(Self.hephB14)</span>"))
    }

    @Test("The Questions card links ids in question texts, option lines and answers; the Symbol card in its question and answer")
    func questionCards() {
        let setID = UUID()
        let question = Question(label: "A", question: "HEPH-21 needs Claude. Where?",
                                options: [QuestionOption(label: "This chat", description: "Runs HEPH-21 here"),
                                          QuestionOption(label: "HEPH-B14")],
                                recommended: "This chat")
        let set = QuestionsItem(id: setID.uuidString, created: Self.created, questionSetID: setID, questions: [question],
                                answers: ["A": "Like HEPH-21"], completed: true)
        let rendered = html(.questions(set))
        #expect(rendered.contains("<p>A. \(Self.heph21) needs Claude. Where?</p>"))
        #expect(rendered.contains("<li>This chat — Runs \(Self.heph21) here (recommended)</li>"))
        #expect(rendered.contains("<li>\(Self.hephB14)</li>"))
        #expect(rendered.contains("<div class=\"answer\">Answer: Like \(Self.heph21)</div>"))
        let symbol = SymbolItem(id: "s", created: Self.created, requestID: UUID(), question: "Icon for HEPH-21?",
                                suggestions: ["star.fill"], recommended: "star.fill", answer: "As HEPH-B14")
        let symbolHTML = html(.symbol(symbol))
        #expect(symbolHTML.contains("<p>Icon for \(Self.heph21)?</p>"))
        #expect(symbolHTML.contains("<div class=\"answer\">Answer: As \(Self.hephB14)</div>"))
    }

    @Test("A click on an id goes to openID and targets the ticket or the bundle")
    @MainActor
    func clicks() {
        var ids: [String] = []
        var links: [String] = []
        let context = MarkdownContext(openLink: { links.append($0) }, openID: { ids.append($0) })
        context.open("hephaestus-id:HEPH-21")
        context.open("hephaestus-id:HEPH-B14")
        context.open("docs/ui.md")
        #expect(ids == ["HEPH-21", "HEPH-B14"])
        #expect(links == ["docs/ui.md"])
        #expect(NavigationTarget.item(id: "HEPH-21") == .ticket(ticketID: "HEPH-21"))
        #expect(NavigationTarget.item(id: "HEPH-B14") == .bundle(bundleID: "HEPH-B14"))
        // Native text links carry the id through the private link URL.
        let url = MarkdownLinkURL.url(for: MarkdownItemIDs.href(for: "HEPH-21"))
        #expect(url.flatMap(MarkdownLinkURL.destination(of:)).flatMap(MarkdownItemIDs.id(fromHref:)) == "HEPH-21")
    }
}
