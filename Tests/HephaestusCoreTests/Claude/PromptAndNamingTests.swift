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
        Make Command-W skip locked tabs in the docs and in the web tab strip, with a test that Command-W leaves a locked tab open.

        Testing
        - Claude: on an isolated instance, press Command-W on a locked tab and check that the tab stays open.
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
                                                        contentType: "text/plain", size: 2048)])],
            links: [TicketLink(kind: .dependsOn, ticketID: "HEPH-9")],
            inverseLinks: [TicketInverseLink(kind: .related, ticketID: "HEPH-13")])
    }

    @Test("{{ticket}} renders the example of docs/chats.md › Rendered blocks")
    func ticketBlock() throws {
        let blocks = MarkdownSource.fencedBlocks(in: try Repository.doc("chats.md"))
        let documented = try #require(blocks.first { $0.text.hasPrefix("ID: HEPH-12\nTitle:") && $0.text.contains("<description>") })
        let rendered = Prompts.ticket(Self.exampleTicket(), projectRoot: "/Users/example/Developer/HephaestusV2",
                                      chatLines: ["- B5A4C3D2-E1F0-4A9B-8C7D-6E5F4A3B2C1D (feedback): Locked tab closes on Command-W"])
        #expect(rendered == documented.text)
    }

    @Test("{{ticket}} Links: the groups Depends on, Blocks and Related, ids in ascending ticket number")
    func ticketLinks() {
        let ticket = Ticket(id: "HEPH-12", title: "T", created: Self.date("2026-10-31T12:00:00Z"),
                            links: [TicketLink(kind: .related, ticketID: "HEPH-20"), TicketLink(kind: .dependsOn, ticketID: "HEPH-16"),
                                    TicketLink(kind: .dependsOn, ticketID: "HEPH-15")],
                            inverseLinks: [TicketInverseLink(kind: .blocks, ticketID: "HEPH-30"),
                                           TicketInverseLink(kind: .related, ticketID: "HEPH-9")])
        #expect(Prompts.linksText(ticket) == "Depends on HEPH-15, HEPH-16 · Blocks HEPH-30 · Related HEPH-9, HEPH-20")
        let blocksOnly = Ticket(id: "HEPH-1", title: "T", created: Self.date("2026-10-31T12:00:00Z"),
                                inverseLinks: [TicketInverseLink(kind: .blocks, ticketID: "HEPH-3")])
        #expect(Prompts.linksText(blocksOnly) == "Blocks HEPH-3")
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
        Links: none
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
            "workingDirectory": "It is your working directory.",
            "deviceName": "Studio", "docsPath": "docs", "projectType": "Go service", "projectCommands": "- build: make build", "ticketID": "HEPH-12",
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
        #expect(prompt.contains("The project's root folder is /Users/example/Developer/HephaestusV2 on the device Studio. It is your working directory. "))
        #expect(prompt.contains("of the project. The project's type is Go service.\n\nThe project's commands:\n"))
        #expect(prompt.contains("\n\n# This chat\n\nThis is the chat of ticket HEPH-12"))
    }

    @Test("Bundle orchestration: the orchestrator starts every ticket that waits for nothing at once, merges by rebase and fast-forward, asks retry, skip or stop, builds, tests and pushes once, never sets done; ticket chats commit on their branch without pushing")
    func bundleOrchestrationPrompts() {
        let common = Prompts.text(.common)
        let section = String(common[common.range(of: "# Implementing a bundle")!.lowerBound..<common.range(of: "# Project and feedback chats")!.lowerBound])
        #expect(section.contains("A ticket waits for the tickets of this bundle that it declares a Depends on link to and that are not done; "
            + "Related links and tickets outside the bundle never make it wait."))
        #expect(section.contains("Call implement_ticket for every ticket that waits for nothing, all in the same turn, then end your turn."))
        #expect(section.contains("Merge a branch into main by rebasing it onto main in its worktree (git -C <worktree> rebase <main>), "
            + "then fast-forwarding main to it in the project root (git merge --ff-only <branch>)"))
        #expect(section.contains("ask the user with ask_questions whether to retry the ticket, skip it or stop the bundle; the other ticket chats keep running."))
        #expect(section.contains("Skip every ticket of the bundle that depends on it too"))
        #expect(section.contains("start no other ticket chat and let the running ones finish; merge nothing, do not push, and keep every branch and worktree."))
        #expect(section.contains("Then build and test main once"))
        #expect(section.contains("change the first line of each ticket's completion comment so that it names the hash of the ticket's commit on main."))
        #expect(section.contains("you commit on your branch without pushing"))
        #expect(!section.contains("one ticket chat runs at a time"))
        #expect(section.contains("- Never set a ticket to done, except in step 6 of \"When the project is a Go service\" in a Go service project."))
        #expect(section.contains("After every ticket has reported back or been skipped, merge the branches not merged yet, in bundle order."))
        #expect(section.contains("When the build or the tests fail, do not push and ask the user with ask_questions how to proceed. Otherwise push once"))
        #expect(section.contains("Your final reply lists each ticket with the hash of its commit on main, or with skipped and the reason, "
            + "and names the conflicts you resolved."))
        #expect(section.contains("when the project has no remote, do not push. Then remove the worktree and the branch of each merged ticket"))
        #expect(section.contains("\" (not pushed: the bundle chat pushes at the end)\""))
        #expect(!section.contains("with its own commit, push, completion comment"))
        let ticket = Prompts.render(Prompts.text(.implementBundleTicket), ["ticketID": "HEPH-12", "ticketTitle": "Fix tabs", "bundleID": "HEPH-B2"])
        #expect(ticket.hasPrefix("Implement ticket HEPH-12: Fix tabs\n\nThe chat of bundle HEPH-B2 started this chat"))
        #expect(ticket.contains("Do not push: the bundle chat merges your branch and pushes once at the end."))
        #expect(ticket.contains("commit on your branch with a message"))
        let bundle = Prompts.text(.implementBundle)
        #expect(bundle.contains("in this turn start with implement_ticket a ticket chat for every ticket that waits for no other ticket of the bundle"))
        #expect(bundle.contains("After the last report, merge the remaining branches in this order, build and test main, push once, then remove the merged tickets' worktrees and branches."))
        #expect(!bundle.contains("one at a time"))
        #expect(Prompts.text(.implementTicket).contains(", push, post the completion comment"))
    }

    @Test("Go service projects: tickets have only Claude tests; after the push the chat waits for CI, runs the test service and the checks, fixing what fails, updates the completion comments and sets the status; bundle ticket chats leave their Claude tests to the bundle chat")
    func goServicePrompts() throws {
        let common = Prompts.text(.common)
        func section(_ start: String, _ end: String) throws -> String {
            let lower = try #require(common.range(of: start)).lowerBound
            let upper = try #require(common.range(of: end, range: lower..<common.endIndex)).lowerBound
            return String(common[lower..<upper])
        }
        #expect(common.contains("of the project. The project's type is {{projectType}}.\n"))
        let go = try section("# When the project is a Go service", "# When the project is HephaestusV2")
        #expect(go.contains("- The Testing section of a ticket has only Claude bullets, each a check of the behaviour on the test service; it has no User bullet."))
        #expect(go.contains("The implement chat of a single ticket, started by Implement or by implement_ticket from a chat that is not a bundle chat, "
            + "posts its completion comment after its push, with the result waiting for the test service on each Claude line, then follows the steps below."))
        #expect(go.contains("In a bundle, the ticket chats do not run their Claude tests"))
        #expect(go.contains("1. CI: wait with the gh CLI for the CI runs of the pushed commit until they end"))
        #expect(go.contains("commit the fix as fix: <summary> (<TICKET-ID>) with the id of the ticket whose change caused the failure"))
        #expect(go.contains("When there is no run to wait for (no workflow, no gh CLI or no remote), skip the wait, go on with step 2, "
            + "and say in your final reply that CI was not checked."))
        #expect(go.contains("2. Test service: build the Docker image from the repository's Dockerfile and run it with docker, "
            + "with a temporary postgres when the service uses one, and mocks of the services it calls."))
        #expect(go.contains("3. Checks: run every Claude bullet of each ticket's Testing section against the test service."))
        #expect(go.contains("4. When the test service cannot start (no Dockerfile, docker not available, the container exits)"))
        #expect(go.contains("5. Update each ticket's completion comment with update_comment: each Testing line gets its result, "
            + "and Notes lists each fix commit of that ticket with its short hash and subject."))
        #expect(go.contains("6. Set each ticket whose Claude tests have all passed to done, following \"Ticket status\"; set the other tickets to review. "
            + "Then stop the test service. The bundle chat then closes its chat."))
        #expect(go.contains("these are the exceptions to \"Do not implement the tickets yourself\" and \"Never set a ticket to done\""))

        // The other sections refer to it.
        #expect(try section("# Writing tickets", "# Ticket status").contains(
            "In a project whose type is Go service, the Testing section has only Claude bullets"))
        #expect(try section("# Ticket status", "# Implementing a ticket").contains(
            "- In a project whose type is Go service, the implement chat of a single ticket and the bundle chat set the tickets to done or review after the checks on the test service"))
        #expect(try section("# Implementing a ticket", "# Commits").contains("then follows \"When the project is a Go service\", whose step 6 replaces step 8"))
        #expect(try section("# Commits", "# Pushing").contains("In a Go service project, each fix of a failed CI run or of a failed check gets its own commit too"))
        #expect(try section("# Completion comment", "# Implementing a bundle").contains(
            "the result of a Claude line is waiting for the test service until the checks on the test service have run"))
        let bundle = try section("# Implementing a bundle", "# Project and feedback chats")
        #expect(bundle.contains("Do not implement the tickets yourself, except the fixes of \"When the project is a Go service\" in a Go service project."))
        #expect(bundle.contains("- Never set a ticket to done, except in step 6 of \"When the project is a Go service\" in a Go service project."))
        #expect(bundle.contains("- In a Go service project, then follow \"When the project is a Go service\" for the merged tickets."))
        #expect(bundle.contains("- In a Go service project, do not run the Claude tests of your ticket: each Claude line of your completion comment "
            + "reads waiting for the test service, and you set the ticket to review."))

        // The implement messages.
        #expect(Prompts.text(.implementTicket).hasSuffix("\n\nIn a Go service project, follow \"When the project is a Go service\" after the push: "
            + "post the completion comment with the Claude tests waiting for the test service, wait for CI, run the test service and the checks, "
            + "then update the completion comment and set the status."))
        #expect(Prompts.text(.implementBundleTicket).hasSuffix("\n\nIn a Go service project, do not run the Claude tests: "
            + "they wait for the test service that the bundle chat runs after its push, and you set the ticket to review."))
        #expect(Prompts.text(.implementBundle).hasSuffix("\n\nIn a Go service project, follow \"When the project is a Go service\" after the push: "
            + "wait for CI, run the test service and every ticket's Claude tests, fixing what fails, update the completion comments, "
            + "set the tickets to done or review, then close your chat."))
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
        #expect(bundle.contains("Follow \"Implementing a ticket\" completely, except that you commit on your branch without pushing"))
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

    @Test("Testing lists no code tests, and a code-test bullet passes once a CI release contains the commit")
    func codeTestsOutOfTesting() throws {
        let common = Prompts.text(.common)
        func section(_ start: String, _ end: String) throws -> String {
            let lower = try #require(common.range(of: start)).lowerBound
            let upper = try #require(common.range(of: end)).lowerBound
            return String(common[lower..<upper])
        }
        let writing = try section("# Writing tickets", "# Ticket status")
        #expect(writing.contains("- Change: what changes in the docs and in the code, naming the docs files and the code areas, limited to what has been decided. It can name the code tests to add."))
        #expect(writing.contains("- Testing: one bullet per check of the behaviour in the running app that decides whether the ticket is done"))
        #expect(writing.contains("Never write a code test there: no bullet for a build or test command such as swift test, a unit test, a test file or the docs conformance tests."))
        #expect(writing.contains("name the tests to add under Change, and add them and run the build and test step before you commit"))

        let status = try section("# Ticket status", "# Implementing a ticket")
        #expect(status.contains("counts as passed once a release built by CI contains the ticket's commit."))

        let comment = try section("# Completion comment", "# Implementing a bundle")
        #expect(comment.contains("passed, failed, waiting for the user, or waiting for the release for a code-test bullet while no release built by CI contains the commit"))

        let tool = try #require(MCPToolCatalog.tool(named: "set_ticket_status", debugTools: false))
        #expect(tool.description.contains("A code-test bullet of the Testing section"))
        #expect(tool.description.contains("counts as passed once a release built by CI contains the ticket's commit."))
    }

    @Test("The common prompt lists close_chat and says when to call it, for other chats only when the user asks")
    func closeChatPrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("- Chats: list_chats, get_chat (a chat and its transcript, for example another chat of the same ticket), rename_chat, close_chat (closes the chat you run in, or chats of the project that the user asks you to close)."))
        let lower = try #require(common.range(of: "# Closing chats")).lowerBound
        let upper = try #require(common.range(of: "# When the project is HephaestusV2")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("After the call, finish your reply: when your turn ends, HephaestusV2 ends your session"))
        #expect(section.contains("- when the user asks you to close the chat;"))
        #expect(section.contains("- in a ticket chat, once you have set its ticket to done;"))
        #expect(section.contains("- in a bundle chat, once every ticket has been implemented or skipped and you have pushed, and in a Go service "
            + "project once you have finished step 6 of \"When the project is a Go service\";"))
        #expect(section.contains("- in a feedback chat, once you have created its ticket."))
        #expect(section.contains("Close a project chat only when the user asks for it."))
        #expect(section.contains("To close other chats of the project, call close_chat with chatIDs"))
        #expect(section.contains("Close another chat only when the user asks you to close it, never on your own."))
        #expect(section.contains("Tell the user which chats were not closed and why."))
    }

    @Test("Claude asks only true unknowns and decides evident points, in every chat kind and in comment answers")
    func onlyTrueUnknowns() throws {
        let values = ["projectName": "Hephaestus V2", "projectID": "HEPH", "projectRoot": "/Users/example/Developer/HephaestusV2",
                      "deviceName": "Studio", "docsPath": "docs", "projectCommands": "- build: make build"]
        let unknowns = "- Ask only true unknowns: points where several answers are reasonable and neither the user's messages, "
            + "the ticket with its comments, the docs, the code nor the answers already given settle them.\n"
        let evident = "- A point with one evident answer, one that follows from the user's request, the docs, the code or a decision "
            + "already made, is not an unknown: decide it without asking. When you write a ticket, state such a point in it as decided.\n"
        let asking = "# Asking questions\n\n- Ask only the true unknowns that \"Never invent\" defines: "
            + "never ask about a point with an evident answer.\n"
        for kind in [ChatKind.project, .ticket, .bundle, .feedback] {
            let prompt = Prompts.systemPrompt(kind: kind, values: values)
            let lower = try #require(prompt.range(of: "# Never invent")).lowerBound
            let upper = try #require(prompt.range(of: "# Asking questions")).lowerBound
            let neverInvent = String(prompt[lower..<upper])
            #expect(neverInvent.contains(unknowns), "\(kind)")
            #expect(neverInvent.contains(evident), "\(kind)")
            #expect(!neverInvent.contains("Ask only what is still unknown."), "\(kind)")
            #expect(prompt.contains(asking), "\(kind)")
        }

        let answer = Prompts.text(.commentAnswer)
        #expect(answer.contains("- Ask only true unknowns: points where several answers are reasonable and neither the comment, "
            + "the ticket with its comments, the docs, the code nor the answers already given settle them.\n"))
        #expect(answer.contains("- A point with one evident answer, one that follows from the comment, the docs, the code or a decision "
            + "already made, is not an unknown: decide it without asking. When you rewrite the ticket's description, state such a point in it as decided.\n"))
        #expect(answer.contains("When something you need is a true unknown, or when statements contradict each other, do not guess"))
        #expect(answer.contains("Put every true unknown into them and no point with an evident answer,"))
    }

    @Test("The rendered common prompt tells Claude to write an SF Symbol as ![](sf:<name>)")
    func sfSymbolPrompt() throws {
        let rule = "# SF Symbols\n\nWhen you name an SF Symbol in a reply or in ask_questions, write it as ![](sf:<name>), "
            + "for example ![](sf:line.3.horizontal.decrease.circle): HephaestusV2 shows the symbol's icon followed by its name there.\n\n"
        let values = ["projectName": "Hephaestus V2", "projectID": "HEPH", "projectRoot": "/Users/example/Developer/HephaestusV2",
                      "deviceName": "Studio", "docsPath": "docs", "projectCommands": "- build: make build"]
        let common = Prompts.render(Prompts.text(.common), values)
        let range = try #require(common.range(of: rule))
        #expect(common[range.upperBound...].hasPrefix("When you need the user to choose an SF Symbol, ask with ask_symbol"))
        for kind in [ChatKind.project, .ticket, .bundle, .feedback] {
            #expect(Prompts.systemPrompt(kind: kind, values: values).contains(rule), "\(kind)")
        }
    }

    @Test("The common prompt lists ask_symbol and tells Claude to use it to have the user choose an SF Symbol")
    func askSymbolPrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("- Questions to the user: ask_questions, ask_symbol (asks the user to choose an SF Symbol), "
            + "ask_color (asks the user to choose a color), ask_sound (asks the user to choose a sound, in a Swift application "
            + "project), ask_shortcut (asks the user to choose a keyboard shortcut, in a Swift application project), ask_font "
            + "(asks the user to choose a font), ask_animation (asks the user to choose a SwiftUI animation, in a Swift application "
            + "project).\n"))
        #expect(common.contains("- Never call ask_questions while earlier questions, a symbol request, a color request, a sound "
            + "request, a shortcut request, a font request or an animation request of this chat still wait for their answers.\n"))
        let lower = try #require(common.range(of: "# SF Symbols")).lowerBound
        let upper = try #require(common.range(of: "# Colors")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("When you need the user to choose an SF Symbol, ask with ask_symbol, never with symbol names as options of ask_questions"))
        #expect(section.contains("After ask_symbol returns, end your turn"))
        #expect(section.contains("Symbol: ![](sf:<name>) for a chosen symbol, Symbol: <answer> for an answer in the user's own words, or Symbol: Skipped"))
        #expect(section.contains("Never call ask_symbol while questions, a symbol request, a color request, a sound request, a "
            + "shortcut request, a font request or an animation request of this chat still wait for their answers."))
    }

    @Test("The common prompt tells Claude to write colors as ![](color:<color>) and to ask for colors with ask_color")
    func askColorPrompt() throws {
        let values = ["projectName": "Hephaestus V2", "projectID": "HEPH", "projectRoot": "/Users/example/Developer/HephaestusV2",
                      "deviceName": "Studio", "docsPath": "docs", "projectCommands": "- build: make build"]
        let common = Prompts.render(Prompts.text(.common), values)
        let lower = try #require(common.range(of: "# Colors\n\n")).lowerBound
        let upper = try #require(common.range(of: "# Sounds")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("When you name a color in a reply or in ask_questions, write it as ![](color:<color>)"))
        #expect(section.contains("When you need the user to choose a color, ask with ask_color, never with color values as options of ask_questions"))
        #expect(section.contains("When the destination of the color supports light and dark appearances, for example an asset catalog "
            + "color set, set lightAndDark"))
        #expect(section.contains("After ask_color returns, end your turn"))
        #expect(section.contains("Color: ![](color:<color>) for one color, Color: Light ![](color:<color>), Dark ![](color:<color>) for a "
            + "light and dark pair, Color: <answer> for an answer in the user's own words, or Color: Skipped"))
        #expect(section.contains("Never call ask_color while questions, a symbol request, a color request, a sound request, a "
            + "shortcut request, a font request or an animation request of this chat still wait for their answers."))
        for kind in [ChatKind.project, .ticket, .bundle, .feedback] {
            #expect(Prompts.systemPrompt(kind: kind, values: values).contains(section), "\(kind)")
        }
    }

    @Test("The common prompt tells Claude to use ask_sound in a Swift application project to have the user choose a sound")
    func askSoundPrompt() throws {
        let common = Prompts.text(.common)
        let lower = try #require(common.range(of: "# Sounds\n")).lowerBound
        let upper = try #require(common.range(of: "# Keyboard shortcuts")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("When the project's type is Swift application (get_project gives it) and you need the user to choose a "
            + "sound for an app of an Apple platform, ask with ask_sound, never with sound names as options of ask_questions"))
        #expect(section.contains("macOS/<file> for a sound of /System/Library/Sounds"))
        #expect(section.contains("iOS 26.1/sms-received1.caf"))
        #expect(section.contains("Project/<path from the project root>"))
        #expect(section.contains("After ask_sound returns, end your turn"))
        #expect(section.contains("Sound: ![](sound:<name>) for a chosen sound, Sound: <answer> for an answer in the user's own words, or "
            + "Sound: Skipped"))
        #expect(section.contains("Never call ask_sound while questions, a symbol request, a color request, a sound request, a "
            + "shortcut request, a font request or an animation request of this chat still wait for their answers."))
        #expect(ClaudeCommandLine.preApprovedTools.contains("mcp__hephaestus__ask_color,mcp__hephaestus__ask_sound,mcp__hephaestus__ask_shortcut,"
            + "mcp__hephaestus__ask_font,mcp__hephaestus__ask_animation,"))
    }

    @Test("The common prompt tells Claude to use ask_shortcut in a Swift application project, with the app's shortcuts in inUse")
    func askShortcutPrompt() throws {
        let common = Prompts.text(.common)
        let lower = try #require(common.range(of: "# Keyboard shortcuts\n")).lowerBound
        let upper = try #require(common.range(of: "# Fonts")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("When the project's type is Swift application (get_project gives it) and you need the user to choose a "
            + "keyboard shortcut, ask with ask_shortcut, never with shortcuts as options of ask_questions"))
        #expect(section.contains("the modifiers ⌃ ⌥ ⇧ ⌘ in this order, then one key, for example ⇧⌘K"))
        #expect(section.contains("and in inUse every shortcut the app already uses, each with the name of its command."))
        #expect(section.contains("After ask_shortcut returns, end your turn"))
        #expect(section.contains("Shortcut: ![](shortcut:<shortcut>) for a chosen or recorded shortcut, Shortcut: <answer> for an answer "
            + "in the user's own words, or Shortcut: Skipped; handle Skipped as for a skipped question."))
        #expect(section.contains("Never call ask_shortcut while questions, a symbol request, a color request, a sound request, a "
            + "shortcut request, a font request or an animation request of this chat still wait for their answers."))
    }

    @Test("The common prompt lists ask_font and tells Claude to use it, with a sample text, to have the user choose a font")
    func askFontPrompt() throws {
        let common = Prompts.text(.common)
        let lower = try #require(common.range(of: "# Fonts")).lowerBound
        let upper = try #require(common.range(of: "# Animations")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("When you need the user to choose a font, ask with ask_font, never with font names as options of ask_questions"))
        #expect(section.contains("a sample text taken from where the font will be used"))
        #expect(section.contains("Write a font as a Dynamic Type text style, for example .headline, or as <family>/<weight>/<size>, for example System Rounded/Semibold/17"))
        #expect(section.contains("After ask_font returns, end your turn"))
        #expect(section.contains("Font: ![](font:<font>) for a chosen font, Font: <answer> for an answer in the user's own words, or Font: Skipped"))
        #expect(section.contains("Never call ask_font while questions, a symbol request, a color request, a sound request, a shortcut "
            + "request, a font request or an animation request of this chat still wait for their answers."))
        for kind in [ChatKind.project, .ticket, .bundle, .feedback] {
            let values = ["projectName": "App", "projectID": "APP", "projectRoot": "/Users/example/App", "workingDirectory": "",
                          "deviceName": "Studio", "docsPath": "docs", "projectCommands": "- build: make build"]
            #expect(Prompts.systemPrompt(kind: kind, values: values).contains("ask with ask_font"), "\(kind)")
        }
    }

    @Test("The common prompt lists show_image and tells Claude to show every image with it; show_image is pre-approved")
    func showImagePrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("- Images: show_image (shows images in this chat).\n"))
        let lower = try #require(common.range(of: "# Images\n")).lowerBound
        let upper = try #require(common.range(of: "# When the project is a Go service")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("Whenever you show the user an image"))
        #expect(section.contains("call show_image with the paths of the image files and an optional caption in Markdown"))
        #expect(section.contains("show_image accepts PNG, JPEG, GIF and WebP files"))
        #expect(section.contains("show_image asks the user nothing: after it returns, continue your work."))
        #expect(ClaudeCommandLine.preApprovedTools.contains("mcp__hephaestus__ask_animation,mcp__hephaestus__show_image,"))
    }

    @Test("The common prompt lists ask_animation and tells Claude to use it in a Swift application project")
    func askAnimationPrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("ask_animation (asks the user to choose a SwiftUI animation, in a Swift application project).\n"))
        let lower = try #require(common.range(of: "# Animations")).lowerBound
        let upper = try #require(common.range(of: "# When the project is HephaestusV2")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("When the project's type is Swift application (get_project gives it) and you need the user to choose an animation, ask with ask_animation, never with animation expressions as options of ask_questions"))
        #expect(section.contains(".smooth, .snappy or .bouncy with (duration:extraBounce:), .spring with (duration:bounce:), or .easeIn, .easeOut, .easeInOut or .linear with (duration:)"))
        #expect(section.contains("duration goes from 0.1 to 2, bounce from -1 to 1 and extraBounce from 0 to 1"))
        #expect(section.contains("After ask_animation returns, end your turn"))
        #expect(section.contains("Animation: ![](animation:<expression>) for a chosen animation, Animation: <answer> for an answer in the user's own words, or Animation: Skipped"))
        #expect(section.contains("Never call ask_animation while questions, a symbol request, a color request, a sound request, a shortcut request, a font "
            + "request or an animation request of this chat still wait for their answers."))
        #expect(Prompts.text(.notificationSummary).contains(#"- "Animation request:": Claude waits for the user to choose an animation for this question."#))
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

    @Test("A multiple answer reads <label>: then one line per checked option and per text; a skipped one reads <label>: Skipped")
    func multipleAnswersMessage() {
        let options = [QuestionOption(label: "Option 1"), QuestionOption(label: "Option 2")]
        let set = QuestionsItem(id: "Q", created: Date(), questionSetID: UUID(), questions: [
            Question(label: "A", question: "q", kind: .multiple, options: options, recommended: ["Option 1"]),
            Question(label: "B", question: "q", kind: .multiple, options: options, recommended: ["Option 2"]),
            Question(label: "C", question: "q", options: options, recommended: "Option 1"),
        ], answers: ["A": "- Option 1\n- My own text", "B": "Skipped", "C": "Option 2"], completed: true)
        #expect(Engine.answersMessage(set) == "Answers:\nA:\n- Option 1\n- My own text\nB: Skipped\nC: Option 2")
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
