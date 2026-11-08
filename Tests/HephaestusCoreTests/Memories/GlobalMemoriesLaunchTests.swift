import Foundation
import Testing
@testable import HephaestusCore

/// docs/memories.md › In chats: every chat launch creates the global memories folder, names it
/// with the lines of its `MEMORY.md` in the prompt and passes it with `--add-dir`.
@Suite("Global memories in chats")
struct GlobalMemoriesLaunchTests {
    @Test("A launch creates the missing global memories folder, names it in the prompt and passes it with --add-dir, as the last argument")
    func launch() async throws {
        try await withChatEngine { bed in
            // The test configuration's config folder, next to the data directory.
            let global = bed.dataDirectory.url.deletingLastPathComponent().appendingPathComponent("Claude/memory").path
            #expect(!FileManager.default.fileExists(atPath: global))
            _ = try await bed.createChat(message: "Remember this")
            let first = try #require(await bed.launcher.chatProcess(0))
            var isFolder: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: global, isDirectory: &isFolder) && isFolder.boolValue)
            #expect(Array(first.request.arguments.suffix(2)) == ["--add-dir", global])
            let prompt = try #require(Self.systemPrompt(first))
            #expect(prompt.contains("\n\n# Global memories\n\n"))
            #expect(prompt.contains("\n\nThe global memories folder is \(global). Its MEMORY.md has no line yet.\n\n"))

            // A later launch reads the MEMORY.md of the folder again.
            try Data("- [Short answers](answer-style.md) — the user wants short answers in every project\n".utf8)
                .write(to: URL(fileURLWithPath: global).appendingPathComponent("MEMORY.md"))
            _ = try await bed.createChat(message: "And this")
            let second = try #require(await bed.launcher.chatProcess(1))
            #expect(try #require(Self.systemPrompt(second)).contains("The global memories folder is \(global). Its MEMORY.md:\n"
                + "- [Short answers](answer-style.md) — the user wants short answers in every project\n\n"))
        }
    }

    @Test("A global memories folder that cannot be created leaves --add-dir out; the prompt still names the folder")
    func folderNotCreated() async throws {
        try await withChatEngine { bed in
            let config = bed.dataDirectory.url.deletingLastPathComponent().appendingPathComponent("Claude")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            // A file where the folder should be.
            try Data("not a folder".utf8).write(to: config.appendingPathComponent("memory"))
            _ = try await bed.createChat(message: "Remember this")
            let process = try #require(await bed.launcher.chatProcess())
            #expect(!process.request.arguments.contains("--add-dir"))
            #expect(try #require(Self.systemPrompt(process)).contains("The global memories folder is \(config.path)/memory. Its MEMORY.md has no line yet."))
        }
    }

    @Test("A CI chat gets the global memories folder with --add-dir but no {{globalMemories}}: its system prompt is the ci prompt alone")
    func ciChat() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let global = bed.dataDirectory.url.deletingLastPathComponent().appendingPathComponent("Claude/memory").path
            let chats = try await CIChatTests.implementChatWithCIChat(bed)
            let process = try #require(await ChatWorktreeTests.process(bed, chats.ci.id))
            #expect(Array(process.request.arguments.suffix(2)) == ["--add-dir", global])
            let prompt = try #require(Self.systemPrompt(process))
            #expect(!prompt.contains("# Global memories") && !prompt.contains("The global memories folder is"))
        }
    }

    static func systemPrompt(_ process: FakeClaudeProcess) -> String? {
        process.request.arguments.firstIndex(of: "--append-system-prompt").map { process.request.arguments[$0 + 1] }
    }
}
