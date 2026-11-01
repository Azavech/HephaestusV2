import Foundation
import Testing
@testable import HephaestusCore

@Suite("Model coding")
struct ModelCodingTests {
    static let created = ISODate.date(from: "2026-10-31T12:00:00Z")!

    // MARK: Unknown keys (docs/data-model.md › Unknown keys)

    @Test("Unknown keys are preserved and written after the known keys, sorted")
    func unknownKeysAfterKnownKeys() throws {
        let yaml = """
            # .hephaestus/ticket/HEPH-14.yml
            schema: 1
            id: HEPH-14
            title: Remember the console height per window
            status: todo
            created: 2026-10-31T17:00:00Z
            updated: 2026-10-31T17:00:00Z
            createdBy: user
            description: The console drawer opens at its default height in every new window.
            labels:
              - ui
              - console
            estimate: 3
            attachments: []
            comments: []
            chats: []

            """
        let ticket = try YAMLCoding.decode(Ticket.self, from: yaml)
        #expect(ticket.unknownKeys == ["estimate": .int(3), "labels": .array(["ui", "console"])])
        let encoded = try YAMLCoding.encode(ticket)
        let keys = encoded.components(separatedBy: "\n").filter { !$0.hasPrefix(" ") && !$0.hasPrefix("-") && $0.contains(":") }
            .map { String($0.prefix { $0 != ":" }) }
        #expect(keys == ["schema", "id", "title", "status", "created", "updated", "createdBy", "description",
                         "attachments", "comments", "chats", "estimate", "labels"])
    }

    @Test("A mutation keeps the unknown keys of nested types")
    func nestedUnknownKeys() throws {
        let yaml = """
            schema: 1
            id: HEPH
            name: Hephaestus V2
            created: 2026-10-31T12:00:00Z
            commands:
              build: make build
              lint: make lint
            webTabs:
              - id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7
                url: https://github.com/
                pinnedAt: 2026-10-31T12:00:00Z
            chatDefaults:
              model: opus
              temperature: 0.5
            color: blue

            """
        var project = try YAMLCoding.decode(Project.self, from: yaml)
        #expect(project.commands.unknownKeys == ["lint": "make lint"])
        #expect(project.webTabs[0].unknownKeys == ["pinnedAt": "2026-10-31T12:00:00Z"])
        #expect(project.chatDefaults?.unknownKeys == ["temperature": .double(0.5)])
        #expect(project.unknownKeys == ["color": "blue"])
        project.name = "Renamed"
        let again = try YAMLCoding.decode(Project.self, from: try YAMLCoding.encode(project))
        #expect(again.unknownKeys == project.unknownKeys)
        #expect(again.commands.unknownKeys == project.commands.unknownKeys)
        #expect(again.webTabs[0].unknownKeys == project.webTabs[0].unknownKeys)
        #expect(again.chatDefaults?.unknownKeys == project.chatDefaults?.unknownKeys)
        #expect(again.name == "Renamed")
    }

    @Test("YAML values become JSONValue by the conversion table")
    func conversionTable() throws {
        let yaml = """
            schema: 1
            projects: []
            a: ~
            b: null
            c:
            d: true
            e: yes
            f: 'true'
            g: 12
            h: '12'
            i: 1.5
            j: .inf
            k: .nan
            l: 2026-10-31T12:00:00Z
            m: 99999999999999999999
            n: [1, two]
            o: {x: 1}
            p: "quoted"
            q: NO

            """
        let registry = try YAMLCoding.decode(Registry.self, from: yaml)
        let expected: [String: JSONValue] = [
            "a": .null, "b": .null, "c": .null, "d": .bool(true), "e": .bool(true), "f": .string("true"),
            "g": .int(12), "h": .string("12"), "i": .double(1.5), "j": .string(".inf"), "k": .string(".nan"),
            "l": .string("2026-10-31T12:00:00Z"), "m": .string("99999999999999999999"),
            "n": .array([.int(1), .string("two")]), "o": .object(["x": .int(1)]), "p": .string("quoted"), "q": .bool(false),
        ]
        #expect(registry.unknownKeys == expected)
        let again = try YAMLCoding.decode(Registry.self, from: try YAMLCoding.encode(registry))
        #expect(again.unknownKeys == expected)
    }

    @Test("Unknown keys survive JSON, as in the engine API")
    func unknownKeysInJSON() throws {
        var ticket = Ticket(id: "HEPH-1", title: "A", created: Self.created)
        ticket.unknownKeys = ["estimate": 3, "labels": ["ui"]]
        let data = try StorageJSON.lineEncoder().encode(ticket)
        let decoded = try StorageJSON.decoder().decode(Ticket.self, from: data)
        #expect(decoded == ticket)
        let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
        #expect(object["estimate"] == 3)
        #expect(object["schema"] == 1)
        #expect(object["chats"] == .array([]))
        #expect(object["created"] == "2026-10-31T12:00:00Z")
    }

    // MARK: Writing rules (docs/data-model.md › Keys and values)

    @Test("Absent optionals are written as null and empty collections as [] and {}")
    func nullsAndEmptyCollections() throws {
        let meta = ChatMeta(id: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!, kind: .project, created: Self.created)
        let yaml = try YAMLCoding.encode(meta)
        #expect(yaml.contains("ticket: null\n"))
        #expect(yaml.contains("bundle: null\n"))
        #expect(!yaml.contains("projectID"))
        #expect(!yaml.contains("state"))
        let settings = try YAMLCoding.encode(HostSettings())
        #expect(settings.hasPrefix("schema: 1\nclaudePath: null\n"))
        let secrets = Secrets(pairingCode: "7K3M-Q9TX-2HVD-R4NP", mcpExternalToken: String(repeating: "a", count: 64))
        let json = String(decoding: try StorageJSON.fileEncoder().encode(secrets), as: UTF8.self)
        #expect(json.contains("\"remoteSecrets\" : {"))
        let project = try YAMLCoding.encode(Project(id: "WEB", name: "Website", created: Self.created))
        #expect(project.contains("subprojects: []\n"))
        #expect(project.contains("chatDefaults: null\n"))
    }

    @Test("Strings YAML would read as another type are quoted, multi-line strings use literal style")
    func quotingAndLiteralStyle() throws {
        var ticket = Ticket(id: "HEPH-2", title: "NO", created: Self.created)
        ticket.description = "Problem\nSomething.\n"
        ticket.comments = [Comment(id: UUID(), author: .user, created: Self.created, text: "line one\nline two")]
        let yaml = try YAMLCoding.encode(ticket)
        #expect(yaml.contains("title: 'NO'\n"))
        #expect(yaml.contains("description: |\n  Problem\n  Something.\n"))
        #expect(yaml.contains("text: |-\n"))
        #expect(yaml.contains("created: 2026-10-31T12:00:00Z\n"))
        for title in ["true", "null", "12", "1.5", "2026-10-31", "ON", "~", ""] {
            ticket.title = title
            #expect(try YAMLCoding.decode(Ticket.self, from: try YAMLCoding.encode(ticket)).title == title)
        }
    }

    // MARK: Reading rules

    @Test("A String key accepts any scalar")
    func stringAcceptsAnyScalar() throws {
        let ticket = try YAMLCoding.decode(Ticket.self, from: "id: HEPH-3\ntitle: NO\ncreated: 2026-10-31T12:00:00Z\n")
        #expect(ticket.title == "NO")
        let number = try YAMLCoding.decode(Ticket.self, from: "id: HEPH-3\ntitle: 12\ncreated: 2026-10-31T12:00:00Z\n")
        #expect(number.title == "12")
    }

    @Test("Absent keys take their defaults")
    func defaults() throws {
        let ticket = try YAMLCoding.decode(Ticket.self, from: "id: HEPH-13\ntitle: T\ncreated: 2026-10-30T15:00:00Z\n")
        #expect(ticket.schema == 1)
        #expect(ticket.status == .todo)
        #expect(ticket.createdBy == .user)
        #expect(ticket.updated == ticket.created)
        #expect(ticket.description == "")
        let settings = try YAMLCoding.decode(HostSettings.self, from: "schema: 1\n")
        #expect(settings == HostSettings())
        let project = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: Website\ncreated: 2026-10-31T09:30:00Z\n")
        #expect(project.nextTicketNumber == 1)
        #expect(project.docsPath == "docs")
        #expect(project.commands == ProjectCommands())
        #expect(project.chatDefaults == nil)
        let defaults = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\nchatDefaults:\n  model: opus\n")
        #expect(defaults.chatDefaults == ChatSettings(model: "opus"))
    }

    @Test("Booleans accept the YAML 1.1 spellings")
    func booleanSpellings() throws {
        for (text, value) in [("yes", true), ("no", false), ("on", true), ("off", false), ("True", true), ("FALSE", false)] {
            let tab = try YAMLCoding.decode(WebTab.self, from: "id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7\nurl: https://a.example/\nlocked: \(text)\n")
            #expect(tab.locked == value)
        }
    }

    @Test("Invalid files", arguments: [
        ("id: HEPH-1\ntitle: T\n", "missing required key"),
        ("id: HEPH-1\ntitle: null\ncreated: 2026-10-31T12:00:00Z\n", "required key null"),
        ("id: HEPH-1\ntitle: ~\ncreated: 2026-10-31T12:00:00Z\n", "required key ~"),
        ("schema: 2\nid: HEPH-1\ntitle: T\ncreated: 2026-10-31T12:00:00Z\n", "newer schema"),
        ("schema: 0\nid: HEPH-1\ntitle: T\ncreated: 2026-10-31T12:00:00Z\n", "schema 0"),
        ("id: heph-1\ntitle: T\ncreated: 2026-10-31T12:00:00Z\n", "malformed id"),
        ("id: HEPH-01\ntitle: T\ncreated: 2026-10-31T12:00:00Z\n", "leading zero"),
        ("id: HEPH-1\ntitle: T\ncreated: 2026-10-31\n", "date without time"),
        ("id: HEPH-1\ntitle: T\ncreated: 2026-10-31T12:00:00\n", "time without offset"),
        ("id: HEPH-1\ntitle: T\ncreated: 2026-10-31T12:00:00Z\nstatus: open\n", "unknown enum value"),
        ("id: HEPH-1\ntitle: T\ncreated: 2026-10-31T12:00:00Z\ntitle: U\n", "duplicate key"),
        ("- a\n- b\n", "root is not a mapping"),
        ("id: HEPH-1\ntitle: T\ncreated: 2026-10-31T12:00:00Z\n---\nid: HEPH-2\n", "two documents"),
        ("id: HEPH-1\ntitle: T\ncreated: 2026-10-31T12:00:00Z\nchats: [not-a-uuid]\n", "malformed chat id"),
    ])
    func invalidTicket(_ yaml: String, _ label: String) {
        #expect(throws: (any Error).self, "\(label)") { try YAMLCoding.decode(Ticket.self, from: yaml) }
    }

    @Test("Readers skip a byte order mark, accept CR LF, and refuse invalid UTF-8")
    func encodingRules() throws {
        let text = "\u{FEFF}id: HEPH-1\r\ntitle: T\r\ncreated: 2026-10-31T12:00:00Z\r\n"
        #expect(try YAMLCoding.decode(Ticket.self, from: Data(text.utf8)).title == "T")
        var invalid = Data("id: HEPH-1\ntitle: ".utf8)
        invalid.append(contentsOf: [0xFF, 0xFE])
        #expect(throws: FormatError.self) { try YAMLCoding.decode(Ticket.self, from: invalid) }
    }

    @Test("Dates accept fractions and offsets, which become whole UTC seconds")
    func dateReading() throws {
        let ticket = try YAMLCoding.decode(Ticket.self, from: "id: HEPH-1\ntitle: T\ncreated: 2026-10-31T14:03:00.75+02:00\n")
        #expect(ISODate.string(from: ticket.created) == "2026-10-31T12:03:00Z")
        #expect(try YAMLCoding.encode(ticket).contains("created: 2026-10-31T12:03:00Z\n"))
    }

    // MARK: Chat metadata

    @Test("Chat kinds must match ticket and bundle")
    func chatKinds() {
        let base = "id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301\ncreated: 2026-10-31T13:00:00Z\n"
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ticket\n") }
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: project\nticket: HEPH-1\n") }
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: bundle\nticket: HEPH-1\nbundle: HEPH-B1\n") }
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: feedback\nbundle: HEPH-B1\n") }
        #expect(throws: Never.self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: feedback\n") }
        #expect(throws: Never.self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: feedback\nticket: HEPH-12\n") }
    }

    @Test("The runtime keys of ChatMeta are ignored in files and carried in JSON")
    func chatMetaRuntimeKeys() throws {
        let yaml = "id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301\nkind: project\ncreated: 2026-10-31T13:00:00Z\nprojectID: HEPH\nstate: running\n"
        let meta = try YAMLCoding.decode(ChatMeta.self, from: yaml)
        #expect(meta.projectID == "")
        #expect(meta.state == .idle)
        #expect(meta.unknownKeys.isEmpty)
        #expect(meta.title == "New Chat")
        var api = meta
        api.projectID = "HEPH"
        api.state = .waitingAnswers
        let json = try StorageJSON.lineEncoder().encode(api)
        let decoded = try StorageJSON.decoder().decode(ChatMeta.self, from: json)
        #expect(decoded.projectID == "HEPH")
        #expect(decoded.state == .waitingAnswers)
    }

    // MARK: Chat items

    @Test("Chat items carry their type, id and created")
    func chatItems() throws {
        let created = Self.created
        let items: [ChatItem] = [
            .user(UserItem(id: "u", created: created, text: "Hi", sender: "MacBook")),
            .assistant(AssistantItem(id: "a", created: created, text: "**x**", messageID: "msg")),
            .thinking(ThinkingItem(id: "t", created: created, text: "hmm", parentToolUseID: "toolu")),
            .toolUse(ToolUseItem(id: "tu", created: created, toolUseID: "toolu", name: "Bash", input: ["command": "ls"])),
            .toolResult(ToolResultItem(id: "tr", created: created, toolUseID: "toolu", text: "ok")),
            .permissionRequest(PermissionRequestItem(id: "p", created: created, requestID: "r", toolName: "Bash", decision: .deny)),
            .questions(QuestionsItem(id: "q", created: created, questionSetID: UUID(), questions: [
                Question(label: "A", question: "?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")], recommended: "x"),
            ])),
            .system(SystemItem(id: "s", created: created, text: "Session started", level: .warning)),
            .result(ResultItem(id: "r", created: created, durationMs: 10, costUSD: 0.5)),
        ]
        for item in items {
            let data = try StorageJSON.lineEncoder().encode(TranscriptLine(op: .add, item: item))
            let decoded = try StorageJSON.decoder().decode(TranscriptLine.self, from: data)
            #expect(decoded.item == item)
            #expect(decoded.item.created == created)
            let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue?["item"]?.objectValue
            #expect(object?["type"] == .string(item.type.rawValue))
        }
        #expect(items.map(\.id) == ["u", "a", "t", "tu", "tr", "p", "q", "s", "r"])
    }

    @Test("MCP tool names are split after mcp__ at the first __")
    func toolNameSplit() {
        #expect(ToolUseItem.splitToolName("mcp__hephaestus__create_ticket") == ("hephaestus", "create_ticket"))
        #expect(ToolUseItem.splitToolName("mcp__a__b__c") == ("a", "b__c"))
        #expect(ToolUseItem.splitToolName("Bash") == (nil, "Bash"))
    }

    // MARK: SKILL.md frontmatter

    @Test("Skill frontmatter keeps extra keys and writes them sorted after name and description")
    func skillFrontmatter() throws {
        let yaml = "description: D\nname: other\nmodel: haiku\nallowed-tools: Bash(git log:*), Read\n"
        let frontmatter = try YAMLCoding.decode(SkillFrontmatter.self, from: yaml, userInfo: [ModelCoding.skillFolderNameKey: "release-notes"])
        #expect(frontmatter.name == "release-notes")
        #expect(frontmatter.extraFrontmatter == ["model": "haiku", "allowed-tools": "Bash(git log:*), Read"])
        let encoded = try YAMLCoding.encode(frontmatter)
        #expect(encoded == "name: release-notes\ndescription: D\nallowed-tools: Bash(git log:*), Read\nmodel: haiku\n")
    }
}
