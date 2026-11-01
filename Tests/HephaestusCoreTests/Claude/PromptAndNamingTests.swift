import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › System prompts (rendering, placeholders, rendered blocks) and › Haiku naming
/// (inputs, output cleanup), › Feedback message and › Answering.
@Suite("Prompts and naming")
struct PromptAndNamingTests {
    static func date(_ text: String) -> Date { ISODate.date(from: text)! }

    /// The HEPH-12 ticket of the `{{ticket}}` example.
    static func exampleTicket() -> Ticket {
        let description = """
        Problem
        Command-W closes the current web tab even when it is locked.

        Current Behavior
        1. Lock a web tab.
        2. Press Command-W.
        3. The locked tab closes.

        Expected
        A locked tab stays open; the app beeps and shows the tooltip "This tab is locked".

        Change
        Make Command-W skip locked tabs in the docs and in the web tab strip.

        Testing
        - Claude: a test presses Command-W on a locked tab and checks that the tab stays open.
        - User: press Command-W on a locked tab and see the beep and the tooltip.

        Docs
        - [web-tabs.md › Locking](docs/web-tabs.md#locking)
        """
        let screenshotID = UUID(uuidString: "5F2B7C10-3A4D-4E5F-8A9B-0C1D2E3F4A5B")!
        let consoleID = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
        return Ticket(
            id: "HEPH-12", title: "Locked web tabs close with Command-W", status: .inProgress, created: date("2026-10-31T12:00:00Z"),
            updated: date("2026-10-31T12:30:00Z"), createdBy: .claude, description: description,
            attachments: [Attachment(id: screenshotID, name: "screenshot.png",
                                     path: Attachment.ticketPath(ticketID: "HEPH-12", id: screenshotID, name: "screenshot.png"),
                                     contentType: "image/png", size: 183_204)],
            comments: [Comment(id: UUID(), author: .user, created: date("2026-10-31T12:10:00Z"), updated: date("2026-10-31T12:20:00Z"),
                               text: "Happens only when the tab is not focused.",
                               attachments: [Attachment(id: consoleID, name: "console.txt",
                                                        path: Attachment.ticketPath(ticketID: "HEPH-12", id: consoleID, name: "console.txt"),
                                                        contentType: "text/plain", size: 2048)])])
    }

    @Test("{{ticket}} renders the example of docs/chats.md › Rendered blocks")
    func ticketBlock() throws {
        let blocks = MarkdownSource.fencedBlocks(in: try Repository.doc("chats.md"))
        let documented = try #require(blocks.first { $0.text.hasPrefix("ID: HEPH-12\nTitle:") && $0.text.contains("<description>") })
        let rendered = Prompts.ticket(Self.exampleTicket(), projectRoot: "/Users/example/Developer/HephaestusV2",
                                      chatLines: ["- B5A4C3D2-E1F0-4A9B-8C7D-6E5F4A3B2C1D (feedback): Locked tab closes on Command-W"])
        #expect(rendered == documented.text)
    }

    @Test("{{ticket}} with empty lists, and the cut beyond 30,000 characters")
    func ticketEdges() {
        let ticket = Ticket(id: "DEMO-1", title: "T", created: Self.date("2026-10-31T12:00:00Z"), description: "")
        #expect(Prompts.ticket(ticket, projectRoot: "/p", chatLines: []) == """
        ID: DEMO-1
        Title: T
        Status: todo
        Created: 2026-10-31T12:00:00Z by user
        Updated: 2026-10-31T12:00:00Z
        <description>
        </description>
        Attachments: none
        Comments: none
        Chats: none
        """)
        let long = Prompts.truncatedTicket(String(repeating: "line of text\n", count: 4000))
        #expect(long.count <= 30_000 + 60)
        #expect(long.hasSuffix("line of text\n[Truncated: call get_ticket for the full ticket.]"))
    }

    @Test("{{bundle}} renders the tickets in full, then as single lines")
    func bundleBlock() {
        let tickets = [Prompts.BundleTicket(id: "HEPH-12", title: "Locked web tabs close with Command-W", rendering: "ID: HEPH-12\n…"),
                       Prompts.BundleTicket(id: "HEPH-13", title: "Tab titles are cut too early", rendering: "ID: HEPH-13\n…")]
        #expect(Prompts.bundle(id: "HEPH-B2", title: "Web tab polish", tickets: tickets, fullCount: 2) == """
        ID: HEPH-B2
        Title: Web tab polish
        Tickets: HEPH-12, HEPH-13

        Ticket 1 of 2:
        ID: HEPH-12
        …

        Ticket 2 of 2:
        ID: HEPH-13
        …
        """)
        #expect(Prompts.bundle(id: "HEPH-B2", title: "Web tab polish", tickets: tickets, fullCount: 1).hasSuffix(
            "\n\nTicket 2 of 2: HEPH-13 Tab titles are cut too early (call get_ticket for its content)"))
    }

    @Test("{{projectCommands}} and {{feedbackContext}}")
    func smallBlocks() {
        #expect(Prompts.projectCommands(ProjectCommands(build: "make build", run: "make run", test: "make test"))
            == "- build: make build\n- run: make run\n- test: make test")
        #expect(Prompts.projectCommands(ProjectCommands(test: "swift test")) == "- test: swift test")
        #expect(Prompts.projectCommands(ProjectCommands()) == "- none: use the repository's own commands")
        #expect(Prompts.feedbackContext(fromFirstMessage: "Hi\n\nFeedback context:\n- App: X\n- Device: Y") == "- App: X\n- Device: Y")
        #expect(Prompts.feedbackContext(fromFirstMessage: "no context") == "- none")
        #expect(Prompts.feedbackContext(fromFirstMessage: nil) == "- none")
    }

    @Test("Rendering replaces each placeholder in one pass")
    func render() {
        #expect(Prompts.render("{{a}} and {{b}}", ["a": "{{b}}", "b": "B"]) == "{{b}} and B")
        #expect(Prompts.render("{{unknown}} {{a", ["a": "x"]) == "{{unknown}} {{a")
    }

    @Test("Every prompt renders with sample values and leaves no {{")
    func everyPromptRenders() {
        let values = [
            "projectName": "Hephaestus V2", "projectID": "HEPH", "projectRoot": "/Users/example/Developer/HephaestusV2",
            "deviceName": "Studio", "docsPath": "docs", "projectCommands": "- build: make build", "ticketID": "HEPH-12",
            "ticketTitle": "Locked web tabs close with Command-W", "ticket": "ID: HEPH-12", "bundleID": "HEPH-B2",
            "bundleTitle": "Web tab polish", "bundleTicketIDs": "HEPH-12, HEPH-13", "bundle": "ID: HEPH-B2", "feedbackContext": "- App: X",
            "screenshotPath": "/Users/example/s.png",
        ]
        for name in Prompts.Name.allCases {
            let text = Prompts.text(name)
            #expect(!text.isEmpty, "\(name.rawValue)")
            #expect(!text.hasSuffix("\n"))
            #expect(!Prompts.render(text, values).contains("{{"), "\(name.rawValue)")
        }
        let prompt = Prompts.systemPrompt(kind: .ticket, values: values)
        #expect(prompt.hasPrefix("You are Claude, working inside HephaestusV2"))
        #expect(prompt.contains("\n\n# This chat\n\nThis is the chat of ticket HEPH-12"))
    }

    @Test("Bundle orchestration: the orchestrator starts one ticket chat at a time, asks retry, skip or stop, pushes once, never sets done; ticket chats commit without pushing")
    func bundleOrchestrationPrompts() {
        let common = Prompts.text(.common)
        let section = String(common[common.range(of: "# Implementing a bundle")!.lowerBound..<common.range(of: "# Project and feedback chats")!.lowerBound])
        #expect(section.contains("Take the tickets in bundle order and skip those whose status is done."))
        #expect(section.contains("call implement_ticket with its id, then end your turn"))
        #expect(section.contains("Start the next ticket's chat only after the previous one has reported back: one ticket chat runs at a time."))
        #expect(section.contains("ask the user with ask_questions whether to retry the ticket, skip it or stop the bundle"))
        #expect(section.contains("Never set a ticket to done."))
        #expect(section.contains("After every ticket has been implemented or skipped, push once"))
        #expect(section.contains("Your final reply lists each ticket with its commit hash, or with skipped and the reason."))
        #expect(section.contains("except that you commit without pushing"))
        #expect(section.contains("\" (not pushed: the bundle chat pushes at the end)\""))
        #expect(!section.contains("with its own commit, push, completion comment"))
        let ticket = Prompts.render(Prompts.text(.implementBundleTicket), ["ticketID": "HEPH-12", "ticketTitle": "Fix tabs", "bundleID": "HEPH-B2"])
        #expect(ticket.hasPrefix("Implement ticket HEPH-12: Fix tabs\n\nThe chat of bundle HEPH-B2 started this chat"))
        #expect(ticket.contains("Do not push: the bundle chat pushes once at the end."))
        let bundle = Prompts.text(.implementBundle)
        #expect(bundle.contains("start one ticket chat per ticket with implement_ticket, one at a time"))
        #expect(bundle.contains("After the last ticket, push once."))
        #expect(Prompts.text(.implementTicket).contains(", push, post the completion comment"))
    }

    @Test("Claude sets review after the completion comment, in a ticket chat and in each ticket chat of a bundle")
    func reviewAfterCompletionComment() throws {
        let common = Prompts.text(.common)
        func section(_ start: String, _ end: String) throws -> String {
            let lower = try #require(common.range(of: start)).lowerBound
            let upper = try #require(common.range(of: end)).lowerBound
            return String(common[lower..<upper])
        }
        let status = try section("# Ticket status", "# Implementing a ticket")
        #expect(status.contains("review (finished, waiting for the user's review)"))
        #expect(status.contains("When you have finished a ticket, after its completion comment, set it with set_ticket_status to done when every Claude test of its Testing section has passed and the user has said in the chat that every User test has passed; otherwise set it to review"))
        #expect(status.contains("A ticket without a Testing section goes to review."))
        #expect(status.contains("set it to in_progress before your first change and back to review after the completion comment of the correction"))
        #expect(status.contains("Never change the status of a ticket that is done"))

        // The status step follows the completion comment.
        let steps = try section("# Implementing a ticket", "# Commits")
        let comment = try #require(steps.range(of: "7. Post the completion comment"))
        let setStatus = try #require(steps.range(of: "8. Set the ticket to done or review with set_ticket_status"))
        #expect(comment.upperBound < setStatus.lowerBound)

        // Each ticket chat of a bundle follows "Implementing a ticket" completely.
        let bundle = try section("# Implementing a bundle", "# Project and feedback chats")
        #expect(bundle.contains("Follow \"Implementing a ticket\" completely, except that you commit without pushing"))
        let messages = [
            Prompts.render(Prompts.text(.implementTicket), ["ticketID": "HEPH-12", "ticketTitle": "Fix tabs"]),
            Prompts.render(Prompts.text(.implementBundleTicket), ["ticketID": "HEPH-12", "ticketTitle": "Fix tabs", "bundleID": "HEPH-B2"]),
        ]
        for message in messages {
            let comment = try #require(message.range(of: "post the completion comment"))
            let setStatus = try #require(message.range(of: "set the ticket to done or review as \"Ticket status\" describes"))
            #expect(comment.upperBound < setStatus.lowerBound)
        }
    }

    @Test("Naming inputs: the label line, then the text cut at 4,000 characters")
    func namingInputs() {
        #expect(HaikuTitleNamer.input(for: .ticket(description: "Problem\nX")) == "Ticket description:\nProblem\nX")
        #expect(HaikuTitleNamer.input(for: .bundle(tickets: [.init(id: "HEPH-12", title: "A"), .init(id: "HEPH-13", title: "B")]))
            == "Tickets:\nHEPH-12: A\nHEPH-13: B")
        #expect(HaikuTitleNamer.input(for: .chat(firstMessage: String(repeating: "a", count: 5000))).count == "First message:\n".count + 4000)
        #expect(HaikuTitleNamer.maximumLength(for: .ticket(description: "")) == 70)
        #expect(HaikuTitleNamer.maximumLength(for: .chat(firstMessage: "")) == 60)
        #expect(HaikuTitleNamer.prompt(for: .bundle(tickets: [])) == .namingBundle)
    }

    @Test("Output cleanup of docs/chats.md › Haiku naming")
    func cleanup() {
        func clean(_ text: String, _ maximum: Int = 60) -> String? { HaikuTitleNamer.cleanTitle(text, maximumLength: maximum) }
        #expect(clean("  Plan the sprint  \nsecond line") == "Plan the sprint")
        #expect(clean("TITLE: Plan the sprint") == "Plan the sprint")
        #expect(clean("Ticket title: Fix the build") == "Fix the build")
        #expect(clean("BUNDLE TITLE: Web tab polish") == "Web tab polish")
        #expect(clean("chat Title:   Plan the sprint") == "Plan the sprint")
        #expect(clean("Ticket title:") == nil)
        // Only one leading label is removed, and only at the start.
        #expect(clean("Title: Chat title: x") == "Chat title: x")
        #expect(clean("The ticket title: x") == "The ticket title: x")
        #expect(clean("“'\"Plan the sprint\"'”") == "Plan the sprint")
        #expect(clean("« Plan the sprint »") == "Plan the sprint")
        // Steps 4 and 5 repeat until neither changes the text.
        #expect(clean("`Fix it`.") == "Fix it")
        #expect(clean("\"Fix it.\"") == "Fix it")
        #expect(clean("“'Fix it.'”.") == "Fix it")
        #expect(clean("\". .\"") == nil)
        #expect(clean("Plan the sprint.", 60) == "Plan the sprint")
        #expect(clean("Alpha beta gamma", 10) == "Alpha beta")
        #expect(clean("Alpha beta gamma", 11) == "Alpha beta")
        #expect(clean("Abcdefghijklmnop", 5) == "Abcde")
        #expect(clean("  \"\"  ") == nil)
        #expect(clean("") == nil)
        let ok = HaikuTitleNamer.title(fromOutput: Data(#"{"type":"result","is_error":false,"result":"Title: \"Web tab polish\""}"#.utf8),
                                       maximumLength: 60)
        #expect(ok.title == "Web tab polish")
        #expect(HaikuTitleNamer.title(fromOutput: Data(#"{"is_error":true,"result":"x"}"#.utf8), maximumLength: 60).title == nil)
        #expect(HaikuTitleNamer.title(fromOutput: Data("nope".utf8), maximumLength: 60).title == nil)
    }

    @Test("The feedback message of the example of docs/chats.md › Feedback message")
    func feedbackMessage() throws {
        let blocks = MarkdownSource.fencedBlocks(in: try Repository.doc("chats.md"))
        let documented = try #require(blocks.first { $0.text.hasPrefix("The lock icon disappears") })
        let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "Studio", projectID: "HEPH",
                                      section: .web, item: "https://github.com/")
        let text = Engine.feedbackMessage(
            comment: "  The lock icon disappears when I drag a locked tab to another position.\n", context: context, projectName: "Hephaestus V2",
            screenshotPath: "/Users/example/Developer/HephaestusV2/.hephaestus/chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301/1B4E28BA-2FA1-11D2-883F-0016D3CCA427-screenshot.png")
        #expect(text == documented.text)
        let bare = Engine.feedbackMessage(comment: " ", context: FeedbackContext(appVersion: "1.0.0", build: 0, deviceName: "Studio",
                                                                                 mainDeviceName: "Studio"),
                                          projectName: nil, screenshotPath: "/s.png")
        #expect(bare == "(no comment)\n\nFeedback context:\n- App: HephaestusV2 v1.0.0(0)\n- Device: Studio\n- Screenshot: /s.png")
    }

    @Test("The Answers message lists the answers in label order and keeps their line breaks")
    func answersMessage() {
        let set = QuestionsItem(id: "Q", created: Date(), questionSetID: UUID(), questions: [
            Question(label: "A", question: "q", options: [QuestionOption(label: "x"), QuestionOption(label: "y")], recommended: "x"),
            Question(label: "B", question: "q", options: [QuestionOption(label: "x"), QuestionOption(label: "y")], recommended: "x"),
        ], answers: ["B": "two\nlines", "A": "Do nothing and beep"], completed: true)
        #expect(Engine.answersMessage(set) == "Answers:\nA: Do nothing and beep\nB: two\nlines")
    }

    @Test("At most 2 naming calls run at once; the others wait in first-in first-out order")
    func namingQueue() async {
        let queue = NamingQueue(limit: 2)
        await queue.acquire()
        await queue.acquire()
        let order = OrderLog()
        let third = Task {
            await queue.acquire()
            order.append(3)
        }
        #expect(await eventually(timeout: waitLimit) { await queue.waitingCount == 1 })
        let fourth = Task {
            await queue.acquire()
            order.append(4)
        }
        #expect(await eventually(timeout: waitLimit) { await queue.waitingCount == 2 })
        #expect(order.values.isEmpty)
        await queue.release()
        await third.value
        #expect(order.values == [3])
        await queue.release()
        await fourth.value
        #expect(order.values == [3, 4])
    }
}

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    func append(_ value: Int) { lock.withLock { items.append(value) } }
    var values: [Int] { lock.withLock { items } }
}
