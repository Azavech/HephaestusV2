import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › CI chats and › Reports to the orchestrator, docs/engine-api.md ›
/// chats.watchCI, docs/workflow.md › Waiting for CI: the CI chat that the chat that pushed starts
/// with `watch_ci`, its reports, and the question an implement chat may then ask.
@Suite("CI chats")
struct CIChatTests {
    static let commit = "4F9C2AB0D1E2F3A4B5C6D7E8F9A0B1C2D3E4F5A6"
    static let page = "https://github.com/owner/name"

    /// Gives the project DEMO a GitHub page.
    static func githubPage(_ bed: ChatTestBed) async throws {
        _ = try await bed.connection.call(ProjectsUpdate.self, .init(projectID: "DEMO", githubPage: .set(page)))
    }

    /// The user items of a chat whose text starts with `prefix`.
    static func userItems(_ bed: ChatTestBed, _ chatID: ChatID, prefix: String = "") async throws -> [UserItem] {
        try await bed.transcript(chatID).compactMap { item -> UserItem? in
            if case .user(let user) = item, user.text.hasPrefix(prefix) { return user }
            return nil
        }
    }

    /// A turn of the process that ends with `reply` as its final reply.
    static func finishTurn(_ process: FakeClaudeProcess, reply: String, messageID: String) {
        process.emit(FakeClaudeLauncher.initLine())
        for line in FakeClaudeLauncher.textReply(messageID: messageID, text: reply) { process.emit(line) }
        process.emit(FakeClaudeLauncher.resultLine())
    }

    /// An implement chat of DEMO-1 in a project with a GitHub page, and the CI chat it starts with
    /// `watch_ci`; their processes are the first two of the launcher.
    static func implementChatWithCIChat(_ bed: ChatTestBed) async throws -> (orchestrator: ChatMeta, ci: ChatMeta) {
        try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
        try await githubPage(bed)
        let orchestrator = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"))
        let ci = try await bed.engine.call(ChatsWatchCI.self, .init(commit: commit), actor: .claude(chatID: orchestrator.id.uuidString))
        return (orchestrator, ci)
    }

    @Test("watch_ci from an implement chat: a CI chat linked to the ticket and to the calling chat, with its settings, the CI message and the ci prompt alone")
    func fromImplementChat() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await Self.githubPage(bed)
            let settings = ChatSettings(model: "sonnet", effort: .low, permissionMode: .bypassPermissions, ultracode: true)
            let orchestrator = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1", settings: settings))
            let ci = try await bed.engine.call(ChatsWatchCI.self, .init(commit: Self.commit), actor: .claude(chatID: orchestrator.id.uuidString))
            #expect(ci.kind == .ci && ci.ticketID == "DEMO-1" && ci.bundleID == nil && ci.orchestratorChatID == orchestrator.id)
            #expect(ci.settings == settings && !ci.questionsBlocked)
            let file = try String(contentsOf: bed.folder.chatMetaFile(ci.id), encoding: .utf8)
            #expect(file.contains("\nkind: ci\nticket: DEMO-1\nbundle: null\norchestrator: \(orchestrator.id.uuidString)\n"))
            #expect(!file.contains("questionsBlocked"))
            #expect(try ProjectFileStore.readTicket(at: bed.folder.ticketFile("DEMO-1"), projectID: "DEMO").chatIDs == [orchestrator.id, ci.id])

            // The CI message, sent by Claude, in lowercase.
            let first = try await Self.userItems(bed, ci.id).first
            #expect(first?.text == "Watch the CI of commit 4f9c2ab0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6.")
            #expect(first?.sender == "Claude")

            // The ci prompt alone, with the project's repository, in the project root.
            let process = try #require(await launcher.chatProcess(1))
            #expect(process.request.arguments.contains(ci.id.uuidString))
            let prompt = try #require(ChatWorktreeTests.systemPrompt(process))
            #expect(prompt.hasPrefix("You are Claude, working inside HephaestusV2, a macOS app that coordinates the work on many projects. "
                + "This is a CI chat of the project Demo (identifier DEMO)"))
            #expect(prompt.contains("The project's root folder is \(bed.root.path) on the device "))
            #expect(prompt.contains("The project's GitHub repository is owner/name.\n\nThe first message names the commit by its full hash."))
            #expect(prompt.contains("gh run view <run id> --repo owner/name --log-failed"))
            #expect(!prompt.contains("# HephaestusV2 tools") && !prompt.contains("{{"))
            #expect(process.request.currentDirectory == bed.root.path)
        }
    }

    @Test("watch_ci from a bundle chat: the CI chat is linked to the bundle and comes after the bundle chat in the bundle's chats")
    func fromBundleChat() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1"]))
            try await Self.githubPage(bed)
            let settings = ChatSettings(model: "opus", effort: .max, permissionMode: .acceptEdits)
            let orchestrator = try await bed.connection.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1", settings: settings))
            let ci = try await bed.engine.call(ChatsWatchCI.self, .init(commit: String(repeating: "ab", count: 32)),
                                               actor: .claude(chatID: orchestrator.id.uuidString))
            #expect(ci.kind == .ci && ci.bundleID == "DEMO-B1" && ci.ticketID == nil && ci.orchestratorChatID == orchestrator.id)
            #expect(ci.settings == settings)
            let bundle = try ProjectFileStore.readBundle(at: bed.folder.bundleFile("DEMO-B1"), projectID: "DEMO")
            #expect(bundle.chatIDs == [orchestrator.id, ci.id])
            #expect(bundle.status == .inProgress)
            #expect(try await Self.userItems(bed, ci.id).first?.text == "Watch the CI of commit \(String(repeating: "ab", count: 32)).")
        }
    }

    @Test("watch_ci is refused for the external token, for a chat that is not a ticket or bundle chat or that another chat started, for a commit that is not a full hash and in a project without a GitHub page; chats.create refuses kind ci")
    func refusals() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            let orchestrator = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"))
            let claude = Actor.claude(chatID: orchestrator.id.uuidString)
            func watch(_ actor: Actor, commit: String = Self.commit) async -> EngineError? {
                await engineError { _ = try await bed.engine.call(ChatsWatchCI.self, .init(commit: commit), actor: actor) }
            }
            // The external token has no chat to report to.
            #expect(await watch(.claude(chatID: Actor.externalChatID)) == ActorRules.ownChatCIOnly)
            #expect(ActorRules.ownChatCIOnly == EngineError(.forbidden, "Only a chat's own Claude can start a CI chat."))
            // A project chat cannot start one.
            let project = try await bed.createChat()
            #expect(await watch(.claude(chatID: project.id.uuidString))
                == EngineError(.forbidden, "Only a ticket or bundle chat that no other chat started can start a CI chat."))
            // A commit that is not a full hash.
            let invalid = EngineError(.invalid, "commit: give the full hash of the pushed commit, 40 or 64 hexadecimal characters.")
            #expect(await watch(claude, commit: "4f9c2ab") == invalid)
            #expect(await watch(claude, commit: String(repeating: "g", count: 40)) == invalid)
            #expect(await watch(claude, commit: String(Self.commit.dropLast())) == invalid)
            // A project without a GitHub page.
            #expect(await watch(claude) == EngineError(.conflict, "DEMO has no GitHub page."))
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).allSatisfy { $0.kind != .ci })
            // With a page, the CI chat itself cannot start another one.
            try await Self.githubPage(bed)
            let ci = try await bed.engine.call(ChatsWatchCI.self, .init(commit: Self.commit), actor: claude)
            #expect(await watch(.claude(chatID: ci.id.uuidString))
                == EngineError(.forbidden, "Only a ticket or bundle chat that no other chat started can start a CI chat."))
            // CI chats are created by chats.watchCI only.
            #expect(await engineError { _ = try await bed.createChat(kind: .ci, ticketID: "DEMO-1") }
                == EngineError(.invalid, "kind: CI chats are created by chats.watchCI."))
        }
    }

    @Test("The CI chat's turns report to its orchestrator: CI chat finished its turn with the final reply, ended in error, was stopped")
    func reports() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (orchestrator, ci) = try await Self.implementChatWithCIChat(bed)
            @Sendable func reports() async throws -> [UserItem] {
                try await Self.userItems(bed, orchestrator.id, prefix: "CI chat ")
            }
            let process = try #require(await launcher.chatProcess(1))
            Self.finishTurn(process, reply: "CI passed.\n\n- Release: https://github.com/owner/name/actions/runs/1", messageID: "msg_1")
            #expect(await eventually(timeout: waitLimit) { (try? await reports().count) == 1 })
            let report = try await reports()[0]
            #expect(report.text == "CI chat finished its turn:\n\nCI passed.\n\n- Release: https://github.com/owner/name/actions/runs/1")
            #expect(report.sender == (await bed.engine.deviceInfo.name))

            // A turn that ends in error.
            try await bed.send(ci.id, "Check again")
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_max_turns", errors: ["Too many turns."]))
            #expect(await eventually(timeout: waitLimit) { (try? await reports().count) == 2 })
            #expect(try await reports()[1].text == "CI chat ended in error: Too many turns.")

            // A stopped turn.
            try await bed.send(ci.id, "Again")
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(ci.id, .running))
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: ci.id))
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_during_execution"))
            #expect(await eventually(timeout: waitLimit) { (try? await reports().count) == 3 })
            #expect(try await reports()[2].text == "CI chat was stopped.")
            // The reports are not the reports of a ticket chat.
            #expect(try await Self.userItems(bed, orchestrator.id, prefix: "Chat of ").isEmpty)
        }
    }

    @Test("A CI failure report, an error or a stop lets an implement chat post one question set; a pass, CI not checked and no report do not; the other requests stay refused")
    func questionAfterFailure() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (orchestrator, ci) = try await Self.implementChatWithCIChat(bed)
            #expect(orchestrator.questionsBlocked)
            let refusal = ImplementChatQuestionsTests.refusal
            let refused = Array(repeating: refusal as EngineError?, count: 7)
            @Sendable func reportCount() async throws -> Int {
                try await Self.userItems(bed, orchestrator.id, prefix: "CI chat ").count
            }
            func answer(_ set: QuestionSet) async throws {
                _ = try await bed.connection.call(ChatsAnswerQuestion.self, .init(chatID: orchestrator.id, questionSetID: set.questionSetID,
                                                                                  label: "A", answer: "lightAndDark"))
            }
            func ask() async throws -> QuestionSet {
                try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: orchestrator.id, questions: [ImplementChatQuestionsTests.question]),
                                          actor: .claude(chatID: orchestrator.id.uuidString))
            }
            func openSet() async throws -> QuestionSet {
                let items = try await bed.transcript(orchestrator.id)
                let item = try #require(items.compactMap { item -> QuestionsItem? in
                    if case .questions(let questions) = item { return questions }
                    return nil
                }.last)
                return QuestionSet(questionSetID: item.questionSetID, chatID: orchestrator.id, questions: item.questions)
            }
            let process = try #require(await launcher.chatProcess(1))

            // No report yet.
            #expect(await ImplementChatQuestionsTests.requestErrors(bed, orchestrator.id) == refused)
            // CI passed, and CI not checked: still refused.
            Self.finishTurn(process, reply: "CI passed.\n\nEvery run succeeded.", messageID: "msg_1")
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 1 })
            #expect(await ImplementChatQuestionsTests.requestErrors(bed, orchestrator.id) == refused)
            try await bed.send(ci.id, "Again")
            Self.finishTurn(process, reply: "\n  CI not checked.  \nNo workflow run exists for the commit.", messageID: "msg_2")
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 2 })
            #expect(await ImplementChatQuestionsTests.requestErrors(bed, orchestrator.id) == refused)

            // CI failed: one question set passes, the six other requests stay refused.
            try await bed.send(ci.id, "Again")
            Self.finishTurn(process, reply: "CI failed.\n\n- Release (run 2): the job Test failed.", messageID: "msg_3")
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 3 })
            #expect(await ImplementChatQuestionsTests.requestErrors(bed, orchestrator.id) == [nil] + Array(repeating: refusal, count: 6))
            // The permission is used up: the next question set is refused again.
            try await answer(try await openSet())
            #expect(await engineError { _ = try await ask() } == refusal)

            // A reply that does not start with a result line counts as a failure.
            try await bed.send(ci.id, "Again")
            Self.finishTurn(process, reply: "The runs could not be listed.", messageID: "msg_4")
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 4 })
            try await answer(try await ask())

            // An error: one question set passes again.
            try await bed.send(ci.id, "Again")
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_max_turns", errors: ["Too many turns."]))
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 5 })
            try await answer(try await ask())
            // A failure gives the permission again; a later report that is not a failure removes it.
            try await bed.send(ci.id, "Again")
            Self.finishTurn(process, reply: "CI failed.", messageID: "msg_5")
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 6 })
            try await bed.send(ci.id, "Again")
            Self.finishTurn(process, reply: "CI passed.", messageID: "msg_6")
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 7 })
            #expect(await engineError { _ = try await ask() } == refusal)

            // A stop.
            try await bed.send(ci.id, "Again")
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(ci.id, .running))
            _ = try await bed.connection.call(ChatsInterrupt.self, .init(chatID: ci.id))
            process.emit(FakeClaudeLauncher.resultLine(isError: true, subtype: "error_during_execution"))
            #expect(await eventually(timeout: waitLimit) { (try? await reportCount()) == 8 })
            let set = try await ask()
            #expect(set.chatID == orchestrator.id)
            // The key itself stays until the user writes in the implement chat.
            #expect(try await ImplementChatQuestionsTests.meta(bed, orchestrator.id).questionsBlocked)
        }
    }

    @Test("The orchestrator starts its turn on the report before the CI chat is seen idle, so the clients never see both idle")
    func reportBeforeIdle() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let (orchestrator, ci) = try await Self.implementChatWithCIChat(bed)
            let orchestratorProcess = try #require(await launcher.chatProcess(0))
            orchestratorProcess.emit(FakeClaudeLauncher.initLine())
            orchestratorProcess.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(orchestrator.id, .idle))
            let ciProcess = try #require(await launcher.chatProcess(1))
            Self.finishTurn(ciProcess, reply: "CI passed.", messageID: "msg_1")
            // The CI chat's turn: running, then its first idle.
            @Sendable func turnEnd(_ updates: [ChatMeta]) -> Int? {
                guard let running = updates.firstIndex(where: { $0.id == ci.id && $0.state == .running }) else { return nil }
                return updates[running...].firstIndex { $0.id == ci.id && $0.state == .idle }
            }
            #expect(await eventually(timeout: waitLimit) { turnEnd(await bed.events.named("chat.updated").compactMap(\.chatMeta)) != nil })
            let updates = await bed.events.named("chat.updated").compactMap(\.chatMeta)
            let ciIdle = try #require(turnEnd(updates))
            // The orchestrator was idle before; the report starts its turn before the CI chat is seen idle.
            let orchestratorIdle = try #require(updates[..<ciIdle].lastIndex { $0.id == orchestrator.id && $0.state == .idle })
            #expect(updates[orchestratorIdle..<ciIdle].contains { $0.id == orchestrator.id && Engine.turnStates.contains($0.state) })
        }
    }

    @Test("The report of a CI chat is a CI failure report unless its final reply starts with CI passed. or CI not checked.")
    func failureReport() {
        func report(_ reply: String?, stopped: Bool = false, resultError: String? = nil) -> TurnReport {
            var report = TurnReport()
            report.reply = reply
            report.stopped = stopped
            report.resultError = resultError
            return report
        }
        #expect(!report("CI passed.\n\nEvery run succeeded.").isCIFailure(state: .idle))
        #expect(!report("\n\n  CI not checked. \nNo run.").isCIFailure(state: .idle))
        #expect(report("CI failed.\n\nRelease failed.").isCIFailure(state: .idle))
        #expect(report("**CI passed.**").isCIFailure(state: .idle))
        #expect(report("CI passed").isCIFailure(state: .idle))
        #expect(report(nil).isCIFailure(state: .idle))
        #expect(report("CI passed.").isCIFailure(state: .error))
        #expect(report("CI passed.", stopped: true).isCIFailure(state: .idle))
        #expect(report("CI passed.", resultError: "Too many turns.").isCIFailure(state: .idle))
        #expect(report("CI passed.").message(subject: "CI chat", state: .idle) == "CI chat finished its turn:\n\nCI passed.")
        #expect(report(nil, stopped: true).message(subject: "CI chat", state: .idle) == "CI chat was stopped.")
        #expect(report(nil, resultError: "Too many turns.").message(subject: "Chat of DEMO-1", state: .idle)
            == "Chat of DEMO-1 ended in error: Too many turns.")
    }

    @Test("An implement chat posts no finished notification while its CI chat works; the CI chat posts none")
    func notifications() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            try await Self.githubPage(bed)
            let orchestrator = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"))
            let orchestratorProcess = try #require(await launcher.chatProcess(0))
            orchestratorProcess.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(orchestrator.id, .running))
            let ci = try await bed.engine.call(ChatsWatchCI.self, .init(commit: Self.commit), actor: .claude(chatID: orchestrator.id.uuidString))
            let ciProcess = try #require(await launcher.chatProcess(1))
            ciProcess.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(ci.id, .running))
            // The implement chat ends its turn while its CI chat works: no finished.
            orchestratorProcess.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(orchestrator.id, .idle))
            try await Task.sleep(for: .milliseconds(200))
            #expect(await ChatNotificationTests.notifications(bed, orchestrator.id).isEmpty)
            // The CI chat's turn ends: its report starts a turn of the implement chat, which then finishes.
            for line in FakeClaudeLauncher.textReply(messageID: "msg_1", text: "CI passed.") { ciProcess.emit(line) }
            ciProcess.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(ci.id, .idle))
            #expect(await bed.waitForState(orchestrator.id, .running))
            orchestratorProcess.emit(FakeClaudeLauncher.initLine())
            orchestratorProcess.emit(FakeClaudeLauncher.resultLine())
            #expect(await ChatNotificationTests.waitFor(bed, orchestrator.id, .finished, .immediate) != nil)
            #expect(await ChatNotificationTests.notifications(bed, ci.id).isEmpty)
        }
    }

    @Test("An orchestrated ticket chat cannot start a CI chat, and a CI chat in a ticket's chats does not take the worktree of the ticket's orchestrated ticket chat")
    func workingDirectory() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            // An orchestrated ticket chat needs a git repository for its branch and worktree.
            _ = try await ChatWorktreeTests.gitRepository(bed)
            try await Self.githubPage(bed)
            let bundleChat = try await ChatWorktreeTests.orchestrator(bed)
            let orchestrated = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"),
                                                         actor: .claude(chatID: bundleChat.id.uuidString))
            // An orchestrated ticket chat does not push: watch_ci refuses it.
            #expect(await engineError {
                _ = try await bed.engine.call(ChatsWatchCI.self, .init(commit: Self.commit), actor: .claude(chatID: orchestrated.id.uuidString))
            } == ActorRules.ciOrchestratorOnly)
            // An implement chat of the same ticket pushes and starts a CI chat, linked to DEMO-1 after it.
            let implement = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"))
            let ci = try await bed.engine.call(ChatsWatchCI.self, .init(commit: Self.commit), actor: .claude(chatID: implement.id.uuidString))
            #expect(try ProjectFileStore.readTicket(at: bed.folder.ticketFile("DEMO-1"), projectID: "DEMO").chatIDs.last == ci.id)
            let meta = try await bed.connection.call(ChatsGet.self, .init(chatID: orchestrated.id)).meta
            let directory = await bed.engine.chatWorkingDirectory(meta, root: bed.root)
            #expect(directory.worktree?.branch == "DEMO-B1/DEMO-1")
            let ciMeta = try await bed.connection.call(ChatsGet.self, .init(chatID: ci.id)).meta
            #expect(await bed.engine.chatWorkingDirectory(ciMeta, root: bed.root).worktree == nil)
        }
    }
}
