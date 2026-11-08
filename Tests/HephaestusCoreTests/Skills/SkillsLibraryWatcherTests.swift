import Foundation
import Testing
@testable import HephaestusCore

/// The library watcher (docs/skills.md › Library): it calls nothing when the library is the same
/// as at its last call or at its start, as after the writes made just before it started.
@Suite("Skills library watcher")
struct SkillsLibraryWatcherTests {
    /// Counts the calls of a watcher.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int { lock.withLock { value } }

        func add() {
            lock.withLock { value += 1 }
        }
    }

    @Test("A snapshot changes with each write, addition and removal in the library, and only then")
    func snapshot() throws {
        try withTemporaryDirectory { folder in
            let library = folder.appendingPathComponent("Skills", isDirectory: true)
            #expect(SkillsLibraryWatcher.Snapshot.of(library).items.isEmpty)
            let skill = try writeSkill("a", in: library, description: "A.")
            let first = SkillsLibraryWatcher.Snapshot.of(library)
            #expect(first.items.count == 3)
            #expect(SkillsLibraryWatcher.Snapshot.of(library) == first)

            try writeFile("a/templates/x.md", in: library, "x")
            let added = SkillsLibraryWatcher.Snapshot.of(library)
            #expect(added != first)

            // The same content written again: only the modification date differs.
            try setModified(skill.appendingPathComponent("SKILL.md"), Date(timeIntervalSince1970: 1_000_000))
            let rewritten = SkillsLibraryWatcher.Snapshot.of(library)
            #expect(rewritten != added)

            try FileManager.default.removeItem(at: skill.appendingPathComponent("templates"))
            #expect(SkillsLibraryWatcher.Snapshot.of(library) != rewritten)
        }
    }

    @Test("Writes made just before watching started call nothing; a later write calls", .fsEvents)
    func writesBeforeStart() async throws {
        try await withTemporaryDirectory { folder in
            let library = folder.appendingPathComponent("Skills", isDirectory: true)
            for name in InternalSkills.names {
                try writeSkill(name, in: library, description: "Default.")
            }
            try writeFile(".internal-skills.json", in: library, "{}")
            let calls = Calls()
            let watcher = SkillsLibraryWatcher(folder: library, log: nil) { calls.add() }
            defer { watcher.stop() }
            try await Task.sleep(for: .seconds(2))
            #expect(calls.count == 0)

            // Written again every 2 seconds until the watcher calls: the stream is running.
            let writer = Task {
                for _ in 0..<10 {
                    try writeSkill("later", in: library, description: "Later.")
                    try await Task.sleep(for: .seconds(2))
                }
            }
            #expect(await eventually { calls.count > 0 })
            writer.cancel()
            _ = await writer.result
        }
    }
}
