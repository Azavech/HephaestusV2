import Darwin
import Foundation
import Testing
@testable import HephaestusCore

extension Engine {
    /// Sets the timeout and the SIGKILL grace of the comment answers.
    func useAnswerTimings(timeout: Duration, killGrace: Duration = .milliseconds(200)) {
        commentAnswers.timeout = timeout
        commentAnswers.killGrace = killGrace
    }

    /// No call runs and no comment has an answer state.
    var commentAnswersIdle: Bool {
        commentAnswers.calls.isEmpty && commentAnswers.states.isEmpty
    }
}

extension EngineEventEnvelope {
    /// The ticket of a `ticket.updated` event.
    var ticket: Ticket? { try? payload(TicketUpdatedEvent.self) }
}

/// docs/chats.md › Comment answers, docs/tickets.md › Comment answers: the call, its command line
/// and input, the answer comment, the state of the row, failures, the timeout, Retry, the stops and
/// the cost.
@Suite("Comment answers")
struct CommentAnswerTests {
    /// A ticket of DEMO.
    static func ticket(_ bed: ChatTestBed, title: String = "Fix the login crash") async throws -> Ticket {
        try await bed.connection.call(TicketsCreate.self, .init(projectID: "DEMO", title: title, description: "Problem\nIt crashes."))
    }

    static func comment(_ bed: ChatTestBed, _ ticketID: TicketID, _ text: String) async throws -> Ticket {
        try await bed.connection.call(TicketsAddComment.self, .init(ticketID: ticketID, text: text))
    }

    /// The first `ticket.updated` of the ticket that satisfies `predicate`.
    static func update(_ bed: ChatTestBed, _ ticketID: TicketID, where predicate: @escaping @Sendable (Ticket) -> Bool) async -> Ticket? {
        await bed.events.wait(for: "ticket.updated") { event in
            guard let ticket = event.ticket, ticket.id == ticketID else { return false }
            return predicate(ticket)
        }?.ticket
    }

    @Test("A user's mention runs one call with the documented command line and input, then Claude's answer is a new comment")
    func answer() async throws {
        try await withChatEngine { bed in
            let ticket = try await Self.ticket(bed)
            let posted = try await Self.comment(bed, ticket.id, "@Claude why does it crash?")
            let commentID = try #require(posted.comments.first?.id)
            let replying = await Self.update(bed, ticket.id) { $0.comments.first?.answer == .replying }
            #expect(replying != nil)
            let answered = try #require(await Self.update(bed, ticket.id) { $0.comments.count == 2 })
            #expect(answered.comments[0].id == commentID && answered.comments[0].answer == nil)
            #expect(answered.comments[1].author == .claude && answered.comments[1].text == "Here is my answer.")
            #expect(answered.comments[1].answer == nil)

            let process = try #require(bed.launcher.answerProcesses.first)
            #expect(bed.launcher.answerProcesses.count == 1)
            let arguments = process.arguments
            let defaults = HostSettings().defaultChatSettings
            let configPath = bed.dataDirectory.mcpConfigFolder.path + "/answer-"
            #expect(Array(arguments.prefix(17)) == [
                "-p", "--output-format", "json", "--no-session-persistence", "--model", defaults.model, "--effort",
                defaults.effort.rawValue, "--permission-mode", "dontAsk", "--tools", "Read,Grep,Glob", "--allowedTools",
                ClaudeCommandLine.answerTools, "--strict-mcp-config", "--mcp-config", arguments[16],
            ])
            #expect(arguments[16].hasPrefix(configPath) && arguments[16].hasSuffix(".json"))
            #expect(!FileManager.default.fileExists(atPath: arguments[16]))
            #expect(arguments[17] == "--append-system-prompt")
            #expect(arguments[18].contains("comment of the ticket \(ticket.id) of the project Demo (identifier DEMO)"))
            #expect(arguments[18].contains(bed.root.path))
            #expect(arguments.count == 20)
            let input = arguments[19]
            #expect(input.hasPrefix("Ticket:\nID: \(ticket.id)\nTitle: Fix the login crash\n"))
            let created = ISODate.string(from: posted.comments[0].created)
            #expect(input.hasSuffix("\n\nComment to answer:\n- \(created) by user:\n  @Claude why does it crash?"))
            #expect(input.contains("Comments:\n- \(created) by user:\n  @Claude why does it crash?\nChats: none\n"))
            #expect(process.request.currentDirectory == bed.root.path)
            #expect(process.request.environment.keys.allSatisfy { !$0.hasPrefix("HEPHAESTUS_") })
            #expect(ClaudeCommandLine.answerTools == "Read,Grep,Glob,mcp__hephaestus__list_projects,mcp__hephaestus__get_project,"
                + "mcp__hephaestus__list_tickets,mcp__hephaestus__get_ticket,mcp__hephaestus__update_ticket,"
                + "mcp__hephaestus__set_ticket_status,mcp__hephaestus__list_bundles,mcp__hephaestus__get_bundle,mcp__hephaestus__search,"
                + "mcp__hephaestus__list_docs,mcp__hephaestus__list_web_tabs,mcp__hephaestus__list_skills,mcp__hephaestus__get_skill,"
                + "mcp__hephaestus__list_chats,mcp__hephaestus__get_chat")

            // No chat; the cost is in the project file and in the totals.
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).isEmpty)
            let summary = await bed.events.wait(for: "projects.changed") { event in
                (try? event.payload(ProjectsChangedEvent.self))?.first { $0.id == "DEMO" }.map { $0.ownCostUSD == 0.25 } == true
            }
            #expect(summary != nil)
            let project = try ProjectFileStore.readProject(bed.folder)
            #expect(project.commentAnswers.map(\.ticketID) == [ticket.id])
            #expect(project.commentAnswers.first?.costUSD == 0.25 && project.commentAnswers.first?.title == "Fix the login crash")
            let summaries = try await bed.connection.call(ProjectsList.self, Empty())
            #expect(summaries.first { $0.id == "DEMO" }?.commentAnswersRunning == 0)
        }
    }

    @Test("Claude's comments, mentions in code, edits and comments without a mention start no call")
    func noTrigger() async throws {
        try await withChatEngine { bed in
            let ticket = try await Self.ticket(bed)
            _ = try await bed.engine.call(TicketsAddComment.self, .init(ticketID: ticket.id, text: "@Claude from a chat"),
                                          actor: .claude(chatID: UUID().uuidString))
            _ = try await Self.comment(bed, ticket.id, "Only `@Claude` in code")
            let plain = try await Self.comment(bed, ticket.id, "No mention")
            let edited = try #require(plain.comments.last)
            _ = try await bed.connection.call(TicketsUpdateComment.self, .init(ticketID: ticket.id, commentID: edited.id,
                                                                               text: "@Claude now"))
            // A last mention runs the only call.
            _ = try await Self.comment(bed, ticket.id, "@claude in lower case")
            let answered = await Self.update(bed, ticket.id) { $0.comments.count == 5 }
            #expect(answered?.comments.last?.author == .claude)
            #expect(bed.launcher.answerProcesses.count == 1)
            #expect(bed.launcher.answerProcesses.first?.arguments.last?.hasSuffix("  @claude in lower case") == true)
        }
    }

    @Test("A failed call posts nothing, the row reads failed, its cost counts; Retry answers on the ticket as it is then")
    func failureAndRetry() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.answerOutput = #"{"type":"result","is_error":true,"result":"API Error","total_cost_usd":0.1}"#
        try await withChatEngine(launcher: launcher) { bed in
            let ticket = try await Self.ticket(bed)
            let posted = try await Self.comment(bed, ticket.id, "@Claude please")
            let commentID = try #require(posted.comments.first?.id)
            let failed = try #require(await Self.update(bed, ticket.id) { $0.comments.first?.answer == .failed })
            #expect(failed.comments.count == 1)
            let log = try String(contentsOf: bed.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(log.contains("comment answer for \(ticket.id) failed: is_error is true"))
            #expect(try ProjectFileStore.readProject(bed.folder).commentAnswers.map(\.costUSD) == [0.1])
            // Retry while not failed is refused; a failed answer runs again.
            launcher.answerOutput = #"{"type":"result","is_error":false,"result":"Done.","total_cost_usd":0.2}"#
            _ = try await bed.connection.call(TicketsUpdate.self, .init(ticketID: ticket.id, title: "Renamed"))
            let retried = try await bed.connection.call(TicketsRetryAnswer.self, .init(ticketID: ticket.id, commentID: commentID))
            #expect(retried.id == ticket.id)
            let answered = try #require(await Self.update(bed, ticket.id) { $0.comments.count == 2 })
            #expect(answered.comments[1].text == "Done." && answered.comments[0].answer == nil)
            #expect(bed.launcher.answerProcesses.count == 2)
            #expect(bed.launcher.answerProcesses.last?.arguments.last?.contains("Title: Renamed") == true)
            await #expect(throws: EngineError(.conflict, "Comment \(commentID.uuidString) has no failed answer to retry.")) {
                _ = try await bed.connection.call(TicketsRetryAnswer.self, .init(ticketID: ticket.id, commentID: commentID))
            }
            let project = try ProjectFileStore.readProject(bed.folder)
            #expect(project.commentAnswers.map(\.costUSD) == [0.1, 0.2])
            #expect(project.commentAnswers.map(\.title) == ["Fix the login crash", "Renamed"])
        }
    }

    @Test("A call still running at the timeout gets SIGTERM, posts nothing and the row reads failed")
    func timeout() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.answerScript = { _ in }
        try await withChatEngine(launcher: launcher) { bed in
            await bed.engine.useAnswerTimings(timeout: .milliseconds(300))
            let ticket = try await Self.ticket(bed)
            _ = try await Self.comment(bed, ticket.id, "@Claude slow")
            let failed = await Self.update(bed, ticket.id) { $0.comments.first?.answer == .failed }
            #expect(failed?.comments.count == 1)
            #expect(bed.launcher.answerProcesses.first?.receivedSignals.first == SIGTERM)
            #expect(try ProjectFileStore.readProject(bed.folder).commentAnswers.isEmpty)
            let log = try String(contentsOf: bed.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(log.contains("comment answer for \(ticket.id) failed: timeout"))
        }
    }

    @Test("Deleting the comment or the ticket stops its call, which posts nothing")
    func stops() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.answerScript = { _ in }
        try await withChatEngine(launcher: launcher) { bed in
            let ticket = try await Self.ticket(bed)
            let posted = try await Self.comment(bed, ticket.id, "@Claude first")
            let comment = try #require(posted.comments.first)
            let first = try #require(await bed.launcher.process(where: FakeClaudeLauncher.isAnswer))
            let running = await bed.events.wait(for: "projects.changed") { event in
                (try? event.payload(ProjectsChangedEvent.self))?.first { $0.id == "DEMO" }?.commentAnswersRunning == 1
            }
            #expect(running != nil)
            let deleted = try await bed.connection.call(TicketsDeleteComment.self, .init(ticketID: ticket.id, commentID: comment.id))
            #expect(deleted.comments.isEmpty)
            #expect(await first.waitForExit() == .signaled(SIGTERM))
            let idle = await bed.events.wait(for: "projects.changed") { event in
                (try? event.payload(ProjectsChangedEvent.self))?.first { $0.id == "DEMO" }?.commentAnswersRunning == 0
            }
            #expect(idle != nil)

            _ = try await Self.comment(bed, ticket.id, "@Claude second")
            let second = try #require(await bed.launcher.process(where: { FakeClaudeLauncher.isAnswer($0) && $0 !== first }))
            _ = try await bed.connection.call(TicketsDelete.self, .init(ticketID: ticket.id))
            #expect(await second.waitForExit() == .signaled(SIGTERM))
            try await Task.sleep(for: .milliseconds(100))
            #expect(await bed.engine.commentAnswersIdle)
        }
    }

    @Test("Answer outcomes: the cost, the trimmed result and the failure reasons")
    func outcomes() {
        func result(_ output: String, _ termination: ProcessTermination? = .exited(0), timedOut: Bool = false) -> CommentAnswerOutcome {
            CommentAnswerOutcome.read(HelperResult(termination: termination, standardOutput: Data(output.utf8), standardError: Data(),
                                                   timedOut: timedOut, spawnError: nil))
        }
        #expect(result(#"{"result":" Yes \n","total_cost_usd":0.5}"#) == CommentAnswerOutcome(costUSD: 0.5, answer: "Yes"))
        #expect(result(#"{"result":"  ","total_cost_usd":-1}"#) == CommentAnswerOutcome(failure: "the result is empty"))
        #expect(result("nope") == CommentAnswerOutcome(failure: "the output is not a JSON object"))
        #expect(result(#"{"result":"x","total_cost_usd":0.1}"#, .exited(2)) == CommentAnswerOutcome(costUSD: 0.1, failure: "exit code 2"))
        #expect(result("", .signaled(9)) == CommentAnswerOutcome(failure: "exit code 137"))
        #expect(result("", timedOut: true) == CommentAnswerOutcome(failure: "timeout"))
    }
}
