import Foundation
import Testing
@testable import HephaestusCore

/// docs/search.md › Sources, › Snippets and › Engine method examples, run on `SearchInput`s built
/// from temporary folders (the engine part is in SearchEngineTests).
@Suite("Search sources")
struct SearchSourcesTests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static func project(_ id: ProjectID, name: String, root: URL, created: Date = base, docsPath: String = "docs",
                        subprojects: [String] = [], webTabs: [WebTab] = []) -> SearchProjectData {
        SearchProjectData(project: Project(id: id, name: name, created: created, docsPath: docsPath, subprojects: subprojects,
                                           webTabs: webTabs), root: root)
    }

    static func run(_ query: String, _ projects: [SearchProjectData], scopes: [SearchScope] = SearchScope.allCases, limit: Int = 200,
                    library: URL? = nil, git: SearchGit? = nil, cache: TranscriptTextCache = TranscriptTextCache()) async throws
        -> [SearchResult] {
        let input = SearchInput(terms: try #require(SearchTerms(query)), scopes: Set(scopes), limit: limit, projects: projects,
                                skillsLibrary: library, git: git)
        return await SearchRunner.run(input, transcripts: cache, log: nil)
    }

    /// The JSON blocks of docs/search.md › Engine method, as JSON values.
    static func docExamples() throws -> [JSONValue] {
        try MarkdownSource.fencedBlocks(in: try Repository.doc("search.md"))
            .filter { $0.info == "json" && $0.heading == "## Engine method" }
            .map { try jsonValue($0.text) }
    }

    static func json(_ results: [SearchResult]) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(results))
    }

    // MARK: Examples of the docs

    @Test("Example 1 of docs/search.md: a ticket by its id and the bundle listing it")
    func example1() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            var data = Self.project("HEPH", name: "Hephaestus V2", root: folder)
            data.tickets = [
                Ticket(id: "HEPH-12", title: "Locked web tabs close with Command-W", status: .inProgress, created: Self.base,
                       description: "Locked tabs close when the user presses Command-W."),
                Ticket(id: "HEPH-3", title: "Other", created: Self.base),
            ]
            data.bundles = [TicketBundle(id: "HEPH-B2", title: "Web tab polish", created: Self.base, ticketIDs: ["HEPH-3", "HEPH-12"])]
            let results = try await Self.run("heph-12", [data], scopes: [.tickets, .bundles])
            #expect(try Self.json(results) == Self.docExamples()[0])
        }
    }

    @Test("Example 2 of docs/search.md: a code line")
    func example2() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            let lines = (1...120).map { $0 == 88 ? "        guard !tab.locked else { NSSound.beep(); return }" : "// line \($0)" }
            try writeFile("Sources/HephaestusUI/Web/WebTabStrip.swift", in: folder, lines.joined(separator: "\n") + "\n")
            try writeFile("Sources/Other.swift", in: folder, "NSSound.beep\n".replacingOccurrences(of: "beep", with: "bell"))
            let results = try await Self.run("nssound.beep", [Self.project("HEPH", name: "Hephaestus V2", root: folder)], scopes: [.code])
            #expect(try Self.json(results) == Self.docExamples()[1])
        }
    }

    // MARK: Projects, tickets, bundles, web tabs

    @Test("Projects match on the identifier, the name and the folder name, without snippet")
    func projects() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            let root = folder.appendingPathComponent("hephaestus-folder", isDirectory: true)
            let data = Self.project("HEPH", name: "Hephaestus V2", root: root)
            let byID = try await Self.run("heph", [data], scopes: [.projects])
            #expect(byID == [SearchResult(id: "project:HEPH", kind: .projects, projectID: "HEPH", title: "Hephaestus V2",
                                          subtitle: "HEPH · \(root.path)", target: .project(projectID: "HEPH"))])
            #expect(try await Self.run("folder v2", [data], scopes: [.projects]).count == 1)
            #expect(try await Self.run("missing", [data], scopes: [.projects]).isEmpty)
        }
    }

    @Test("Tickets: description, comments oldest first and attachment names are body fields, in snippet order")
    func tickets() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            var data = Self.project("HEPH", name: "Hephaestus V2", root: folder)
            let newer = Comment(id: UUID(), author: .user, created: Self.base.addingTimeInterval(60), text: "Second comment mentions crash",
                                attachments: [Attachment(id: UUID(), name: "crash-log.txt", path: "attachments/HEPH-1/x-crash-log.txt")])
            let older = Comment(id: UUID(), author: .claude, created: Self.base, text: "First comment mentions crash")
            data.tickets = [Ticket(id: "HEPH-1", title: "Title", status: .done, created: Self.base,
                                   description: "Nothing here", attachments: [Attachment(id: UUID(), name: "screen.png", path: "attachments/HEPH-1/y-screen.png")],
                                   comments: [newer, older])]
            let crash = try await Self.run("crash", [data], scopes: [.tickets])
            #expect(crash.map(\.snippet) == ["First comment mentions crash"])
            #expect(crash.first?.subtitle == "Hephaestus V2 · Done")
            #expect(crash.first?.title == "HEPH-1 Title")
            #expect(try await Self.run("log.txt", [data], scopes: [.tickets]).map(\.snippet) == ["crash-log.txt"])
            #expect(try await Self.run("screen.png title", [data], scopes: [.tickets]).map(\.snippet) == ["screen.png"])
            #expect(try await Self.run("title", [data], scopes: [.tickets]).map(\.snippet) == [nil])
        }
    }

    @Test("Bundles: a member whose ticket is gone is its id alone")
    func bundles() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            var data = Self.project("HEPH", name: "Hephaestus V2", root: folder)
            data.tickets = [Ticket(id: "HEPH-1", title: "Present", created: Self.base)]
            data.bundles = [TicketBundle(id: "HEPH-B1", title: "Bundle", created: Self.base, ticketIDs: ["HEPH-1", "HEPH-7"])]
            #expect(try await Self.run("heph-7", [data], scopes: [.bundles]).map(\.snippet) == ["HEPH-7"])
            #expect(try await Self.run("present", [data], scopes: [.bundles]).map(\.snippet) == ["HEPH-1 Present"])
            #expect(try await Self.run("heph-b1", [data], scopes: [.bundles]).map(\.subtitle) == ["Hephaestus V2"])
        }
    }

    @Test("Web tabs match on the id, the title and the URL, undated, ordered by position")
    func webTabs() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            let first = WebTab(id: UUID(), title: "Docs page", url: "https://example.com/docs")
            let second = WebTab(id: UUID(), title: "Example home", url: "https://example.com/")
            let data = Self.project("HEPH", name: "Hephaestus V2", root: folder, webTabs: [first, second])
            let results = try await Self.run("example", [data], scopes: [.web])
            #expect(results.map(\.id) == ["web:HEPH:\(first.id.uuidString)", "web:HEPH:\(second.id.uuidString)"])
            #expect(results[0] == SearchResult(id: "web:HEPH:\(first.id.uuidString)", kind: .web, projectID: "HEPH", title: "Docs page",
                                               subtitle: "https://example.com/docs", target: .webTab(projectID: "HEPH", tabID: first.id)))
            let byID = try await Self.run(second.id.uuidString.lowercased(), [data], scopes: [.web])
            #expect(byID.map(\.title) == ["Example home"])
        }
    }

    // MARK: Docs

    @Test("Docs: lines are body fields, the snippet is the first line with a term, big or non-UTF-8 files match on path and title")
    func docs() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            var data = Self.project("HEPH", name: "Hephaestus V2", root: folder)
            try writeFile("docs/search.md", in: folder, "# Search\r\n\r\nThe panel opens\twith ⇧⌘F.\r\nThe panel closes.\r\n")
            try writeFile("docs/big.md", in: folder, "# Big\n" + String(repeating: "panel ", count: 200_000))
            try Data([0x23, 0x20, 0xFF, 0x0A]).write(to: folder.appendingPathComponent("docs/binary.md"))
            data.docs = [DocEntry(path: "docs/search.md", title: "Search"), DocEntry(path: "docs/big.md", title: "Big"),
                         DocEntry(path: "docs/binary.md", title: "Binary panel"), DocEntry(path: "docs/gone.md", title: "Panel gone")]
            try setModified(folder.appendingPathComponent("docs/search.md"), Self.base)
            try setModified(folder.appendingPathComponent("docs/binary.md"), Self.base.addingTimeInterval(-10))
            let results = try await Self.run("panel", [data], scopes: [.docs])
            #expect(results == [
                SearchResult(id: "doc:HEPH:docs/binary.md", kind: .docs, projectID: "HEPH", title: "Binary panel", subtitle: "docs/binary.md",
                             target: .doc(projectID: "HEPH", path: "docs/binary.md")),
                SearchResult(id: "doc:HEPH:docs/search.md", kind: .docs, projectID: "HEPH", title: "Search", subtitle: "docs/search.md",
                             snippet: "The panel opens with ⇧⌘F.", target: .doc(projectID: "HEPH", path: "docs/search.md")),
            ])
            #expect(try await Self.run("big", [data], scopes: [.docs]).map(\.id) == ["doc:HEPH:docs/big.md"])
            #expect(try await Self.run("closes opens", [data], scopes: [.docs]).map(\.snippet) == ["The panel opens with ⇧⌘F."])
        }
    }

    // MARK: Chats

    @Test("Chats: the final text of user and assistant items, re-read when the transcript changes")
    func chats() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            var data = Self.project("HEPH", name: "Hephaestus V2", root: folder)
            let chatID = UUID()
            let quiet = UUID()
            data.chats = [ChatMeta(id: chatID, title: "Planning", kind: .ticket, ticketID: "HEPH-1", created: Self.base, projectID: "HEPH"),
                          ChatMeta(id: quiet, title: "Quiet", kind: .project, created: Self.base, projectID: "HEPH")]
            let transcript = ProjectFolder(root: folder).transcriptFile(chatID)
            let writer = JSONLinesWriter()
            func append(_ op: TranscriptOp, _ item: ChatItem) throws {
                try writer.append(TranscriptLine(op: op, item: item), to: transcript)
            }
            try append(.add, .user(UserItem(id: "u1", created: Self.base, text: "Please fix the zebra bug", sender: "MacBook")))
            try append(.add, .assistant(AssistantItem(id: "a1", created: Self.base, text: "Draft about giraffes", messageID: "m1")))
            try append(.add, .thinking(ThinkingItem(id: "t1", created: Self.base, text: "thinking about penguins")))
            try append(.add, .system(SystemItem(id: "s1", created: Self.base, text: "system penguins")))
            try append(.update, .assistant(AssistantItem(id: "a1", created: Self.base, text: "Final answer about lions", messageID: "m1")))
            let cache = TranscriptTextCache()

            let zebra = try await Self.run("zebra", [data], scopes: [.chats], cache: cache)
            #expect(zebra == [SearchResult(id: "chat:\(chatID.uuidString)", kind: .chats, projectID: "HEPH", title: "Planning",
                                           subtitle: "Hephaestus V2 · ticket", snippet: "Please fix the zebra bug", target: .chat(chatID: chatID))])
            #expect(try await Self.run("lions", [data], scopes: [.chats], cache: cache).count == 1)
            #expect(try await Self.run("giraffes", [data], scopes: [.chats], cache: cache).isEmpty)
            #expect(try await Self.run("penguins", [data], scopes: [.chats], cache: cache).isEmpty)
            #expect(try await Self.run("quiet", [data], scopes: [.chats], cache: cache).map(\.title) == ["Quiet"])
            #expect(cache.count == 1)

            try append(.add, .user(UserItem(id: "u2", created: Self.base, text: "And the koala", sender: "MacBook")))
            #expect(try await Self.run("koala", [data], scopes: [.chats], cache: cache).map(\.snippet) == ["And the koala"])
            #expect(try await Self.run(chatID.uuidString.lowercased(), [data], scopes: [.chats], cache: cache).map(\.snippet) == [nil])
        }
    }

    // MARK: Skills

    @Test("Skills match on the name, the description and the body; they have no project")
    func skills() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            let library = folder.appendingPathComponent("Skills", isDirectory: true)
            try writeSkill("release-notes", in: library, description: "Writes release notes.", body: "\nUse git log.\n")
            try writeSkill("empty-description", in: library, "Body with git.\n")
            try setModified(library.appendingPathComponent("release-notes/SKILL.md"), Self.base)
            try setModified(library.appendingPathComponent("empty-description/SKILL.md"), Self.base.addingTimeInterval(-100))
            let results = try await Self.run("git", [], scopes: [.skills], library: library)
            #expect(results == [
                SearchResult(id: "skill:release-notes", kind: .skills, title: "release-notes", subtitle: "Writes release notes.",
                             snippet: "Use git log.", target: .skill(name: "release-notes")),
                SearchResult(id: "skill:empty-description", kind: .skills, title: "empty-description", snippet: "Body with git.",
                             target: .skill(name: "empty-description")),
            ])
            #expect(try await Self.run("RELEASE-NOTES", [], scopes: [.skills], library: library).map(\.snippet) == [nil])
            #expect(try await Self.run("git", [], scopes: [.skills], library: nil).isEmpty)
        }
    }

    // MARK: Scopes, ranking across kinds, limit

    @Test("Results of all scopes are ranked together and cut to the limit")
    func rankingAndLimit() async throws {
        try await withTemporaryDirectory { (folder: URL) async throws in
            let library = folder.appendingPathComponent("Skills", isDirectory: true)
            let root = folder.appendingPathComponent("root", isDirectory: true)
            try writeSkill("orbit", in: library, description: "Orbit skill.")
            try setModified(library.appendingPathComponent("orbit/SKILL.md"), Self.base.addingTimeInterval(500))
            try writeFile("notes.txt", in: root, "orbit line\n")
            try setModified(root.appendingPathComponent("notes.txt"), Self.base.addingTimeInterval(1000))
            var data = Self.project("ORB", name: "Orbit", root: root, created: Self.base.addingTimeInterval(-1000),
                                    webTabs: [WebTab(id: UUID(), title: "Orbit tab", url: "https://example.com")])
            data.tickets = [Ticket(id: "ORB-1", title: "Orbit ticket", created: Self.base),
                            Ticket(id: "ORB-2", title: "Body", created: Self.base, updated: Self.base.addingTimeInterval(2000),
                                   description: "orbit in body")]
            let results = try await Self.run("orbit", [data], library: library)
            #expect(results.map(\.id) == ["skill:orbit", "ticket:ORB-1", "project:ORB", "web:ORB:\(data.project.webTabs[0].id.uuidString)",
                                          "ticket:ORB-2", "code:ORB:notes.txt:1"])
            let limited = try await Self.run("orbit", [data], limit: 2, library: library)
            #expect(limited.map(\.id) == ["skill:orbit", "ticket:ORB-1"])
            let ticketsOnly = try await Self.run("orbit", [data], scopes: [.tickets], library: library)
            #expect(ticketsOnly.map(\.kind) == [.tickets, .tickets])
        }
    }
}
