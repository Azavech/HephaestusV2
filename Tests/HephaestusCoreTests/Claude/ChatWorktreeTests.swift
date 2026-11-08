import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Branch and worktree and › Working directory: the branch and the worktree of an
/// orchestrated ticket chat and its working directory at launch and resume.
@Suite struct ChatWorktreeTests {
    /// Gives the engine the machine's git, makes the project root a git repository on `main` with
    /// one commit, and returns git; nil when the machine has no git.
    static func gitRepository(_ bed: ChatTestBed) async throws -> SearchGit {
        let git = try #require(await CodeSearchTests.git())
        await bed.engine.useFileTools(FileTools(environment: git.environment, git: git.executable))
        try await run(git, ["init", "-q", "-b", "main"], in: bed.root)
        try "# Demo\n".write(to: bed.root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await commit(git, "README.md", message: "first", in: bed.root)
        return git
    }

    /// Runs git in `folder` and returns its standard output, trimmed.
    @discardableResult
    static func run(_ git: SearchGit, _ arguments: [String], in folder: URL) async throws -> String {
        let request = ChildProcessRequest(executable: git.executable, arguments: ["-C", folder.path] + arguments, environment: git.environment)
        let result = try await ChildProcessRunner.run(request, timeout: waitLimit)
        #expect(result.termination.isSuccess, "git \(arguments.joined(separator: " ")): \(result.standardErrorText)")
        return result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func commit(_ git: SearchGit, _ path: String, message: String, in folder: URL) async throws {
        try await run(git, ["add", path], in: folder)
        try await run(git, ["-c", "user.name=Example", "-c", "user.email=user@example.com", "commit", "-q", "-m", message], in: folder)
    }

    /// A bundle DEMO-B1 of DEMO-1 and DEMO-2, and its bundle chat started by `implement_bundle`.
    static func orchestrator(_ bed: ChatTestBed) async throws -> ChatMeta {
        try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
        try await bed.writeTicket(Ticket(id: "DEMO-2", title: "Two", created: ISODate.now(), description: "Problem"))
        try await bed.writeBundle(TicketBundle(id: "DEMO-B1", title: "Polish", created: ISODate.now(), ticketIDs: ["DEMO-1", "DEMO-2"]))
        return try await bed.engine.call(ChatsImplementBundle.self, .init(bundleID: "DEMO-B1"), actor: .claude(chatID: Actor.externalChatID))
    }

    /// The process launched for `chatID` with `--session-id` (new) or `--resume`.
    static func process(_ bed: ChatTestBed, _ chatID: ChatID, resumed: Bool = false) async -> FakeClaudeProcess? {
        await bed.launcher.process { process in
            let arguments = process.request.arguments
            guard let index = arguments.firstIndex(of: resumed ? "--resume" : "--session-id"), index + 1 < arguments.count else { return false }
            return arguments[index + 1] == chatID.uuidString
        }
    }

    static func systemPrompt(_ process: FakeClaudeProcess) -> String? {
        let arguments = process.request.arguments
        guard let index = arguments.firstIndex(of: "--append-system-prompt"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @Test("Orchestration: implement_ticket of a bundle chat creates <bundle id>/<ticket id> in <data dir>/Worktrees/<project id>/<ticket id>; the chat's Claude process runs there at launch and resume, with a system prompt that names them")
    func branchAndWorktree() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let git = try await Self.gitRepository(bed)
            let main = try await Self.run(git, ["rev-parse", "HEAD"], in: bed.root)
            let orchestrator = try await Self.orchestrator(bed)
            let claude = Actor.claude(chatID: orchestrator.id.uuidString)
            // Both tickets start at once, each on its own branch in its own worktree.
            let first = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude)
            let second = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-2"), actor: claude)
            for (ticketID, chat) in [("DEMO-1", first), ("DEMO-2", second)] {
                let worktree = bed.dataDirectory.worktree(projectID: "DEMO", ticketID: ticketID)
                #expect(worktree.path == bed.dataDirectory.url.path + "/Worktrees/DEMO/\(ticketID)")
                #expect(try await Self.run(git, ["rev-parse", "--abbrev-ref", "HEAD"], in: worktree) == "DEMO-B1/\(ticketID)")
                #expect(try await Self.run(git, ["rev-parse", "HEAD"], in: worktree) == main)
                #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("README.md").path))
                let process = try #require(await Self.process(bed, chat.id))
                #expect(process.request.currentDirectory == worktree.path)
                #expect(Self.systemPrompt(process)?.contains(
                    "on the device \(await bed.engine.deviceInfo.name). Your working directory is the git worktree \(worktree.path) of this project, "
                        + "on the branch DEMO-B1/\(ticketID): read, change, build, test and commit the project's files there, not in the project root."
                ) == true)
            }
            // A resume starts in the worktree too.
            let process = try #require(await Self.process(bed, first.id))
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(FakeClaudeLauncher.resultLine())
            #expect(await bed.waitForState(first.id, .idle))
            process.exit(.exited(0))
            try await Task.sleep(for: .milliseconds(200))
            try await bed.send(first.id, "Go on")
            let resumed = try #require(await Self.process(bed, first.id, resumed: true))
            #expect(resumed.request.currentDirectory == bed.dataDirectory.worktree(projectID: "DEMO", ticketID: "DEMO-1").path)
            // The other chats keep the project root.
            let implement = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"))
            let other = try #require(await Self.process(bed, implement.id))
            #expect(other.request.currentDirectory == bed.root.path)
            #expect(Self.systemPrompt(other)?.contains("The project's root folder is \(bed.root.path) on the device "
                + "\(await bed.engine.deviceInfo.name). It is your working directory.") == true)
            #expect(await Self.process(bed, orchestrator.id)?.request.currentDirectory == bed.root.path)
        }
    }

    @Test("Orchestration: a retry removes the ticket's old worktree and branch and starts on a fresh branch from main; the earlier chat then works in the project root")
    func retryOnFreshBranch() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let git = try await Self.gitRepository(bed)
            let main = try await Self.run(git, ["rev-parse", "HEAD"], in: bed.root)
            let orchestrator = try await Self.orchestrator(bed)
            let claude = Actor.claude(chatID: orchestrator.id.uuidString)
            let first = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude)
            let worktree = bed.dataDirectory.worktree(projectID: "DEMO", ticketID: "DEMO-1")
            // The failed chat left a commit on its branch and a file it did not commit.
            try "partial\n".write(to: worktree.appendingPathComponent("partial.txt"), atomically: true, encoding: .utf8)
            try await Self.commit(git, "partial.txt", message: "partial", in: worktree)
            try "draft\n".write(to: worktree.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
            #expect(try await Self.run(git, ["rev-parse", "HEAD"], in: worktree) != main)

            let retry = try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude)
            #expect(retry.orchestratorChatID == orchestrator.id)
            #expect(try await Self.run(git, ["rev-parse", "--abbrev-ref", "HEAD"], in: worktree) == "DEMO-B1/DEMO-1")
            #expect(try await Self.run(git, ["rev-parse", "HEAD"], in: worktree) == main)
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("partial.txt").path))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("draft.txt").path))
            #expect(try #require(await Self.process(bed, retry.id)).request.currentDirectory == worktree.path)
            // The worktree belongs to the newest orchestrated ticket chat of the ticket.
            let earlier = try await bed.connection.call(ChatsGet.self, .init(chatID: first.id)).meta
            #expect(await bed.engine.chatWorkingDirectory(earlier, root: bed.root) == ChatWorkingDirectory(url: bed.root))
            // A worktree removed after the push leaves the newest chat in the project root.
            try await Self.run(git, ["worktree", "remove", "--force", worktree.path], in: bed.root)
            let newest = try await bed.connection.call(ChatsGet.self, .init(chatID: retry.id)).meta
            #expect(await bed.engine.chatWorkingDirectory(newest, root: bed.root) == ChatWorkingDirectory(url: bed.root))
        }
    }

    @Test("Orchestration: when the branch and worktree cannot be created, implement_ticket of a bundle chat fails with unavailable and git's message and creates no chat")
    func worktreeFailure() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let git = try #require(await CodeSearchTests.git())
            await bed.engine.useFileTools(FileTools(environment: git.environment, git: git.executable))
            let orchestrator = try await Self.orchestrator(bed)
            let claude = Actor.claude(chatID: orchestrator.id.uuidString)
            // The project is not a git repository.
            let error = try #require(await engineError { try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude) })
            #expect(error.code == .unavailable)
            #expect(error.message.hasPrefix("Cannot create the branch and worktree of DEMO-1: fatal: not a git repository"))
            // Without git.
            await bed.engine.useFileTools(FileTools(environment: [:]))
            #expect(await engineError { try await bed.engine.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"), actor: claude) }
                == EngineError(.unavailable, "Cannot create the branch and worktree of DEMO-1: git is not available"))
            #expect(try ProjectFileStore.readTicket(at: bed.folder.ticketFile("DEMO-1"), projectID: "DEMO").chatIDs.isEmpty)
            // A ticket chat that is not orchestrated needs no worktree.
            #expect(try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1")).orchestratorChatID == nil)
        }
    }
}
