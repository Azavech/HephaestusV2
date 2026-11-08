import Foundation
import Testing
@testable import HephaestusCore

/// docs/memories.md › Inherited memories, docs/chats.md › Rendered blocks and › Command line: a
/// chat of a sub project names the memory folders of its ancestors in its system prompt and may
/// read them.
@Suite struct ChatParentMemoriesTests {
    @Test("A chat of a sub project in another repository names its parent's folder with its MEMORY.md and gets a Read rule for it; a chat of the parent gets neither")
    func parentMemoriesAtLaunch() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            // DEMO's root is not a git repository: SUB, inside it, has its own memory folder.
            _ = try await bed.connection.call(ProjectsCreate.self, .init(rootPath: bed.root.appendingPathComponent("sub").path, name: "Sub",
                                                                         identifier: "SUB", parentID: "DEMO", createDirectory: true))
            let parentFolder = try await bed.connection.call(MemoriesList.self, .init(projectID: "DEMO")).path
            #expect(try await bed.connection.call(MemoriesList.self, .init(projectID: "SUB")).inherited.map(\.path) == [parentFolder])
            try FileManager.default.createDirectory(atPath: parentFolder, withIntermediateDirectories: true)
            try "- [Answer style](feedback_style.md) — Answer in short sentences\r\n".write(toFile: parentFolder + "/MEMORY.md", atomically: true,
                                                                                            encoding: .utf8)

            let chat = try await bed.connection.call(ChatsCreate.self, .init(projectID: "SUB", kind: .project,
                                                                             message: ChatMessageInput(text: "Hello")))
            let process = try #require(await ChatWorktreeTests.process(bed, chat.id))
            let prompt = try #require(ChatWorktreeTests.systemPrompt(process))
            #expect(prompt.contains("The project's type is None.\n\n" + Prompts.parentMemoriesIntro
                + "\n\nMemories of the project Demo (identifier DEMO), in the folder \(parentFolder):\n"
                + "- [Answer style](feedback_style.md) — Answer in short sentences\n\nThese rules apply in every chat."))
            let arguments = process.request.arguments
            let settings = try #require(arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] })
            // The folder, then its path with its links resolved when it differs (/var is a link to /private/var).
            let resolved = ClaudeMemoryFolderResolver.realPath(parentFolder)
            let rules = ([parentFolder] + (resolved == parentFolder ? [] : [resolved])).map { #""Read(/"# + $0 + #"/**)""# }
            #expect(settings.hasPrefix(#"{"permissions":{"allow":["# + rules.joined(separator: ",") + #"]},"hooks":"#))

            let parentChat = try await bed.createChat(message: "Hello")
            let parentProcess = try #require(await ChatWorktreeTests.process(bed, parentChat.id))
            let parentPrompt = try #require(ChatWorktreeTests.systemPrompt(parentProcess))
            #expect(!parentPrompt.contains(Prompts.parentMemoriesIntro))
            #expect(parentPrompt.contains("The project's type is None.\n\nThese rules apply in every chat."))
            #expect(!parentProcess.request.arguments.contains { $0.contains(#""permissions""#) })
        }
    }

    @Test("A parent folder that does not exist is not named; a sub project in its parent's repository names nothing")
    func noParentMemories() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            _ = try await bed.connection.call(ProjectsCreate.self, .init(rootPath: bed.root.appendingPathComponent("sub").path, name: "Sub",
                                                                         identifier: "SUB", parentID: "DEMO", createDirectory: true))
            let missing = try await bed.connection.call(ChatsCreate.self, .init(projectID: "SUB", kind: .project,
                                                                               message: ChatMessageInput(text: "Hello")))
            let missingProcess = try #require(await ChatWorktreeTests.process(bed, missing.id))
            let missingPrompt = try #require(ChatWorktreeTests.systemPrompt(missingProcess))
            #expect(!missingPrompt.contains(Prompts.parentMemoriesIntro))

            // With DEMO's root a repository, SUB shares DEMO's folder.
            try FileManager.default.createDirectory(at: bed.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let parentFolder = try await bed.connection.call(MemoriesList.self, .init(projectID: "DEMO")).path
            try FileManager.default.createDirectory(atPath: parentFolder, withIntermediateDirectories: true)
            try "- [A](a.md) — A\n".write(toFile: parentFolder + "/MEMORY.md", atomically: true, encoding: .utf8)
            let shared = try await bed.connection.call(ChatsCreate.self, .init(projectID: "SUB", kind: .project,
                                                                              message: ChatMessageInput(text: "Hello")))
            let sharedProcess = try #require(await ChatWorktreeTests.process(bed, shared.id))
            #expect(!(ChatWorktreeTests.systemPrompt(sharedProcess) ?? "").contains(Prompts.parentMemoriesIntro))
            #expect(!sharedProcess.request.arguments.contains { $0.contains(#""permissions""#) })
        }
    }
}
