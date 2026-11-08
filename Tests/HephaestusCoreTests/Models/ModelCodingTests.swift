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
                         "attachments", "comments", "chats", "links", "history", "estimate", "labels"])
    }

    @Test("A mutation keeps the unknown keys of nested types")
    func nestedUnknownKeys() throws {
        let yaml = """
            schema: 1
            id: HEPH
            name: Hephaestus V2
            created: 2026-10-31T12:00:00Z
            webTabs:
              - id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7
                url: https://github.com/
                pinnedAt: 2026-10-31T12:00:00Z
            chatDefaults:
              model: opus
              temperature: 0.5
            mascot: hammer

            """
        var project = try YAMLCoding.decode(Project.self, from: yaml)
        #expect(project.webTabs[0].unknownKeys == ["pinnedAt": "2026-10-31T12:00:00Z"])
        #expect(project.chatDefaults?.unknownKeys == ["temperature": .double(0.5)])
        #expect(project.unknownKeys == ["mascot": "hammer"])
        project.name = "Renamed"
        let again = try YAMLCoding.decode(Project.self, from: try YAMLCoding.encode(project))
        #expect(again.unknownKeys == project.unknownKeys)
        #expect(again.webTabs[0].unknownKeys == project.webTabs[0].unknownKeys)
        #expect(again.chatDefaults?.unknownKeys == project.chatDefaults?.unknownKeys)
        #expect(again.name == "Renamed")
    }

    @Test("The commands key of earlier versions is an unknown key of the project file, written back after the known keys")
    func commandsKeyIsUnknown() throws {
        let yaml = """
            schema: 1
            id: HEPH
            name: Hephaestus V2
            created: 2026-10-31T12:00:00Z
            docsPath: docs
            commands:
              build: make build
            webTabs: []

            """
        var project = try YAMLCoding.decode(Project.self, from: yaml)
        #expect(project.unknownKeys == ["commands": .object(["build": "make build"])])
        project.name = "Renamed"
        let encoded = try YAMLCoding.encode(project)
        let keys = encoded.components(separatedBy: "\n").filter { !$0.hasPrefix(" ") && !$0.hasPrefix("-") && $0.contains(":") }
            .map { String($0.prefix { $0 != ":" }) }
        #expect(keys == ["schema", "id", "name", "created", "type", "nextTicketNumber", "nextBundleNumber", "docsPath",
                         "useParentSettings", "subprojects", "webTabs", "skills", "chatDefaults", "environments", "deletedChats",
                         "commentAnswers", "commands"])
        #expect(try YAMLCoding.decode(Project.self, from: encoded) == project)
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(project))
        #expect(json.objectValue?["commands"] == .object(["build": "make build"]))
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
        #expect(project.chatDefaults == nil)
        #expect(project.type == .none)
        let defaults = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\nchatDefaults:\n  model: opus\n")
        #expect(defaults.chatDefaults == ChatSettings(model: "opus"))
    }

    @Test("The project type round-trips each value, is written after created and refuses other values")
    func projectType() throws {
        for type in ProjectType.allCases {
            let project = Project(id: "WEB", name: "Website", created: Self.created, type: type)
            let yaml = try YAMLCoding.encode(project)
            #expect(yaml.contains("created: 2026-10-31T12:00:00Z\ntype: \(type.rawValue)\nnextTicketNumber"))
            #expect(try YAMLCoding.decode(Project.self, from: yaml) == project)
            let json = try EngineJSON.encode(project)
            #expect(try EngineJSON.decode(Project.self, from: json).type == type)
        }
        #expect(ProjectType.allCases.map(\.label) == ["None", "Go service", "Swift application"])
        #expect(throws: (any Error).self) {
            try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\ntype: rustCrate\n")
        }
    }

    @Test("The project color is written after type when set, left out when absent, uppercased when read, and refuses other values")
    func projectColor() throws {
        let plain = Project(id: "WEB", name: "Website", created: Self.created)
        let plainYAML = try YAMLCoding.encode(plain)
        #expect(!plainYAML.contains("color"))
        #expect(try YAMLCoding.decode(Project.self, from: plainYAML).color == nil)
        let plainJSON = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(plain))
        #expect(plainJSON.objectValue?["color"] == .null)

        let colored = Project(id: "WEB", name: "Website", created: Self.created, color: "#FFD60A")
        let yaml = try YAMLCoding.encode(colored)
        #expect(yaml.contains("type: none\ncolor: '#FFD60A'\nnextTicketNumber"))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == colored)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(colored)).color == "#FFD60A")

        let lowercase = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\ncolor: '#ffd60a'\n")
        #expect(lowercase.color == "#FFD60A")
        for invalid in ["red", "'#12345'", "'#1234567'", "'#GGGGGG'", "'34C759'"] {
            #expect(throws: (any Error).self) {
                try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\ncolor: \(invalid)\n")
            }
        }
        #expect(throws: (any Error).self) {
            try Project(id: "WEB", name: "W", created: Self.created, color: "#12345").validate()
        }
    }

    @Test("The project icon is written after the color when set, left out when absent, read trimmed, and not checked against the symbols")
    func projectIcon() throws {
        let plain = Project(id: "WEB", name: "Website", created: Self.created)
        let plainYAML = try YAMLCoding.encode(plain)
        #expect(!plainYAML.contains("icon"))
        #expect(try YAMLCoding.decode(Project.self, from: plainYAML).icon == nil)
        let plainJSON = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(plain))
        #expect(plainJSON.objectValue?["icon"] == .null)

        let withIcon = Project(id: "WEB", name: "Website", created: Self.created, color: "#FFD60A", icon: "hammer")
        let yaml = try YAMLCoding.encode(withIcon)
        #expect(yaml.contains("type: none\ncolor: '#FFD60A'\nicon: hammer\nnextTicketNumber"))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == withIcon)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(withIcon)).icon == "hammer")
        let uncolored = try YAMLCoding.encode(Project(id: "WEB", name: "Website", created: Self.created, icon: "star.fill"))
        #expect(uncolored.contains("type: none\nicon: star.fill\nnextTicketNumber"))

        func read(_ value: String) throws -> String? {
            try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\nicon: \(value)\n").icon
        }
        #expect(try read("' star '") == "star")
        #expect(try read("''") == nil)
        #expect(try read("'  '") == nil)
        #expect(try read("null") == nil)
        #expect(try read("no.such.symbol") == "no.such.symbol")
        #expect(throws: (any Error).self) {
            try read("[star]")
        }
    }

    @Test("Environments are written after chatDefaults, with port and the Kubernetes keys null when absent, keep their unknown keys and need a name and a URL")
    func projectEnvironments() throws {
        let project = Project(id: "API", name: "Orders API", created: Self.created, type: .goService, environments: [
            ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080),
            ProjectEnvironment(name: "staging", url: "https://staging.example.com", context: "staging-eks", namespace: "orders",
                               deployment: "orders-api", argoCDApplication: "argocd/orders-staging", kubeconfig: "~/.kube/staging.yaml"),
        ])
        let yaml = try YAMLCoding.encode(project)
        #expect(yaml.contains("""
            chatDefaults: null
            environments:
            - name: local
              url: http://127.0.0.1
              port: 8080
              context: null
              namespace: null
              deployment: null
              argoCDApplication: null
              kubeconfig: null
            - name: staging
              url: https://staging.example.com
              port: null
              context: staging-eks
              namespace: orders
              deployment: orders-api
              argoCDApplication: argocd/orders-staging
              kubeconfig: ~/.kube/staging.yaml
            deletedChats: []

            """))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == project)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(project)) == project)
        let json = try EngineJSON.jsonValue(project.environments[0]).objectValue
        for key in ["context", "namespace", "deployment", "argoCDApplication", "kubeconfig"] {
            #expect(json?[key] == .null, "\(key)")
        }
        #expect(try YAMLCoding.encode(Project(id: "WEB", name: "Website", created: Self.created)).contains("environments: []\n"))
        #expect(try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\n").environments.isEmpty)

        var extended = try YAMLCoding.decode(Project.self, from: """
            id: API
            name: Orders API
            created: 2026-10-31T10:00:00Z
            environments:
            - name: local
              url: http://127.0.0.1
              region: eu-west-1

            """)
        #expect(extended.environments == [ProjectEnvironment(name: "local", url: "http://127.0.0.1", unknownKeys: ["region": "eu-west-1"])])
        #expect(extended.unknownKeys.isEmpty)
        extended.environments[0].name = "dev"
        let rewritten = try YAMLCoding.encode(extended)
        #expect(rewritten.contains("  kubeconfig: null\n  region: eu-west-1\n"))
        #expect(try YAMLCoding.decode(Project.self, from: rewritten).environments[0].unknownKeys == ["region": "eu-west-1"])

        for invalid in ["- url: http://127.0.0.1", "- name: local", "- name: local\n  url: http://127.0.0.1\n  port: high",
                        "- name: local\n  url: http://127.0.0.1\n  namespace: [orders]"] {
            #expect(throws: (any Error).self) {
                try YAMLCoding.decode(Project.self, from: "id: API\nname: A\ncreated: 2026-10-31T10:00:00Z\nenvironments:\n\(invalid)\n")
            }
        }
    }

    @Test("The GitHub page is written after docsPath when set, left out when absent, read without a trailing /, and refuses other values")
    func projectGithubPage() throws {
        let plain = Project(id: "WEB", name: "Website", created: Self.created)
        let plainYAML = try YAMLCoding.encode(plain)
        #expect(!plainYAML.contains("githubPage"))
        #expect(try YAMLCoding.decode(Project.self, from: plainYAML).githubPage == nil)
        let plainJSON = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(plain))
        #expect(plainJSON.objectValue?["githubPage"] == .null)

        let linked = Project(id: "WEB", name: "Website", created: Self.created, githubPage: "https://github.com/owner/name")
        let yaml = try YAMLCoding.encode(linked)
        #expect(yaml.contains("docsPath: docs\ngithubPage: https://github.com/owner/name\nuseParentSettings: true\nsubprojects"))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == linked)
        #expect(try EngineJSON.decode(Project.self, from: try EngineJSON.encode(linked)).githubPage == "https://github.com/owner/name")

        let slash = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\ngithubPage: 'https://github.com/owner/name/ '\n")
        #expect(slash.githubPage == "https://github.com/owner/name")
        for invalid in ["github.com/x", "http://github.com/owner/name", "https://github.com/owner", "https://github.com/owner/name/more",
                        "https://example.com/owner/name", "''"] {
            #expect(throws: (any Error).self) {
                try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\ngithubPage: \(invalid)\n")
            }
        }
        #expect(throws: (any Error).self) {
            try Project(id: "WEB", name: "W", created: Self.created, githubPage: "github.com/x").validate()
        }
    }

    @Test("useParentSettings is true when the key is absent, always written, and keeps false")
    func projectUseParentSettings() throws {
        let minimal = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\n")
        #expect(minimal.useParentSettings)
        #expect(try YAMLCoding.encode(minimal).contains("useParentSettings: true\n"))
        let off = try YAMLCoding.decode(Project.self, from: "id: WEB\nname: W\ncreated: 2026-10-31T09:30:00Z\nuseParentSettings: no\n")
        #expect(!off.useParentSettings)
        let yaml = try YAMLCoding.encode(off)
        #expect(yaml.contains("useParentSettings: false\n"))
        #expect(try YAMLCoding.decode(Project.self, from: yaml) == off)
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(off))
        #expect(json.objectValue?["useParentSettings"] == .bool(false))
        #expect(off.unknownKeys.isEmpty)
    }

    @Test("A web tab's originalURL is written after locked; a locked tab read without it takes its url, an unlocked tab has none")
    func webTabOriginalURL() throws {
        let tab = "id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7\nurl: https://github.com/pulls\n"
        let lockedBefore = try YAMLCoding.decode(WebTab.self, from: tab + "locked: true\n")
        #expect(lockedBefore.originalURL == "https://github.com/pulls")
        #expect(try YAMLCoding.decode(WebTab.self, from: tab + "locked: true\noriginalURL: null\n").originalURL == "https://github.com/pulls")
        let locked = try YAMLCoding.decode(WebTab.self, from: tab + "locked: true\noriginalURL: https://github.com/\n")
        #expect(locked.originalURL == "https://github.com/" && locked.unknownKeys.isEmpty)
        let unlocked = try YAMLCoding.decode(WebTab.self, from: tab + "locked: false\noriginalURL: https://github.com/\n")
        #expect(unlocked.originalURL == nil && unlocked.unknownKeys.isEmpty)
        #expect(throws: (any Error).self) {
            try YAMLCoding.decode(WebTab.self, from: tab + "locked: true\noriginalURL: [1]\n")
        }

        let yaml = try YAMLCoding.encode(locked)
        #expect(yaml.hasSuffix("locked: true\noriginalURL: https://github.com/\n"))
        #expect(try YAMLCoding.decode(WebTab.self, from: yaml) == locked)
        #expect(try YAMLCoding.encode(unlocked).hasSuffix("locked: false\noriginalURL: null\n"))
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(unlocked))
        #expect(json.objectValue?["originalURL"] == .null)
        #expect(try EngineJSON.decode(WebTab.self, from: try EngineJSON.encode(locked)) == locked)

        #expect(WebTab(id: UUID(), url: "https://example.com/", locked: true).originalURL == "https://example.com/")
        #expect(WebTab(id: UUID(), url: "https://example.com/", originalURL: "https://example.org/").originalURL == nil)
    }

    @Test("The Kubernetes keys of an environment are read trimmed, an empty value as null, and their rules are not checked")
    func projectEnvironmentKubernetesKeys() throws {
        let read = try YAMLCoding.decode(Project.self, from: """
            id: API
            name: Orders API
            created: 2026-10-31T10:00:00Z
            environments:
            - name: staging
              url: https://staging.example.com
              context: ' staging-eks '
              namespace: "orders\\t"
              deployment: '  '
              argoCDApplication: ''
              kubeconfig:
            - name: broken
              url: http://127.0.0.1
              argoCDApplication: argocd/orders/staging
              kubeconfig: kube/config

            """).environments
        #expect(read == [
            ProjectEnvironment(name: "staging", url: "https://staging.example.com", context: "staging-eks", namespace: "orders"),
            ProjectEnvironment(name: "broken", url: "http://127.0.0.1", argoCDApplication: "argocd/orders/staging", kubeconfig: "kube/config"),
        ])
        let json = #"{"name":"staging","url":"https://staging.example.com","port":null,"context":" staging-eks ","namespace":"","#
            + #""deployment":" orders-api ","argoCDApplication":" orders-staging ","kubeconfig":"\n"}"#
        #expect(try EngineJSON.decode(ProjectEnvironment.self, from: Data(json.utf8))
            == ProjectEnvironment(name: "staging", url: "https://staging.example.com", context: "staging-eks", deployment: "orders-api",
                                  argoCDApplication: "orders-staging"))
    }

    @Test("A web tab's githubTab is written after originalURL, left out of the file for any other tab and null in JSON")
    func webTabGitHubTab() throws {
        let tab = "id: 7C9E6679-7425-40DE-944B-E07FC1F90AE7\nurl: https://github.com/owner/name/actions\nlocked: true\n"
        let ci = try YAMLCoding.decode(WebTab.self, from: tab + "originalURL: https://github.com/owner/name/actions\ngithubTab: ci\n")
        #expect(ci.githubTab == .ci && ci.unknownKeys.isEmpty)
        #expect(try YAMLCoding.decode(WebTab.self, from: tab + "githubTab: page\n").githubTab == .page)
        #expect(try YAMLCoding.decode(WebTab.self, from: tab + "githubTab: null\n").githubTab == nil)
        #expect(throws: (any Error).self) {
            try YAMLCoding.decode(WebTab.self, from: tab + "githubTab: pulls\n")
        }

        let yaml = try YAMLCoding.encode(ci)
        #expect(yaml.hasSuffix("locked: true\noriginalURL: https://github.com/owner/name/actions\ngithubTab: ci\n"))
        #expect(try YAMLCoding.decode(WebTab.self, from: yaml) == ci)
        let other = WebTab(id: UUID(), url: "https://example.com/", locked: true)
        #expect(try !YAMLCoding.encode(other).contains("githubTab"))
        let json = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(other))
        #expect(json.objectValue?["githubTab"] == .null)
        let ciJSON = try JSONDecoder().decode(JSONValue.self, from: try EngineJSON.encode(ci))
        #expect(ciJSON.objectValue?["githubTab"] == .string("ci"))
        #expect(try EngineJSON.decode(WebTab.self, from: try EngineJSON.encode(ci)) == ci)
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
        // A CI chat has an orchestrator and exactly one of ticket and bundle (docs/data-model.md › Chat kinds).
        let orchestrator = "orchestrator: 1D2C3B4A-5968-4776-A5B4-C3D2E1F0A9B8\n"
        #expect(throws: Never.self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ci\nticket: HEPH-12\n" + orchestrator) }
        #expect(throws: Never.self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ci\nbundle: HEPH-B2\n" + orchestrator) }
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ci\nticket: HEPH-12\n") }
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ci\n" + orchestrator) }
        #expect(throws: (any Error).self) {
            try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ci\nticket: HEPH-12\nbundle: HEPH-B2\n" + orchestrator)
        }
        #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + "kind: project\n" + orchestrator) }
        #expect(throws: (any Error).self) {
            try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ci\nticket: HEPH-12\n" + orchestrator + "questionsBlocked: true\n")
        }
        let ci = try? YAMLCoding.decode(ChatMeta.self, from: base + "kind: ci\nbundle: HEPH-B2\n" + orchestrator)
        #expect(ci?.kind == .ci && ci?.orchestratorChatID == UUID(uuidString: "1D2C3B4A-5968-4776-A5B4-C3D2E1F0A9B8"))
    }

    @Test("questionsBlocked: false by default, written only when true, only for kind ticket")
    func chatQuestionsBlocked() throws {
        let base = "id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301\ncreated: 2026-10-31T13:00:00Z\n"
        let open = try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ticket\nticket: HEPH-1\n")
        #expect(!open.questionsBlocked)
        #expect(!(try YAMLCoding.encode(open)).contains("questionsBlocked"))
        let blocked = try YAMLCoding.decode(ChatMeta.self, from: base + "kind: ticket\nticket: HEPH-1\nquestionsBlocked: true\n")
        #expect(blocked.questionsBlocked)
        #expect(blocked.unknownKeys.isEmpty)
        #expect(try YAMLCoding.encode(blocked).contains("questionsBlocked: true\n"))
        #expect(try StorageJSON.decoder().decode(ChatMeta.self, from: try StorageJSON.lineEncoder().encode(blocked)).questionsBlocked)
        for other in ["kind: project\n", "kind: bundle\nbundle: HEPH-B1\n", "kind: feedback\n"] {
            #expect(throws: (any Error).self) { try YAMLCoding.decode(ChatMeta.self, from: base + other + "questionsBlocked: true\n") }
            #expect(throws: Never.self) { try YAMLCoding.decode(ChatMeta.self, from: base + other + "questionsBlocked: false\n") }
        }
    }

    @Test("The runtime keys of ChatMeta, backgroundWork included, are ignored in files and carried in JSON")
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
        api.backgroundWork = true
        let json = try StorageJSON.lineEncoder().encode(api)
        let decoded = try StorageJSON.decoder().decode(ChatMeta.self, from: json)
        #expect(decoded.projectID == "HEPH")
        #expect(decoded.state == .waitingAnswers)
        #expect(decoded.backgroundWork)
        #expect(decoded.unknownKeys.isEmpty)
        // backgroundWork is never written to the file and ignored when read from it; JSON without
        // it reads as false.
        let file = try YAMLCoding.encode(api)
        #expect(!file.contains("backgroundWork"))
        #expect(try YAMLCoding.decode(ChatMeta.self, from: yaml + "backgroundWork: true\n").backgroundWork == false)
        let withoutKey = try StorageJSON.decoder().decode(ChatMeta.self, from: Data(#"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","kind":"project","created":"2026-10-31T13:00:00Z"}"#.utf8))
        #expect(!withoutKey.backgroundWork)
    }

    @Test("closed of ChatMeta: false when absent, always written, persisted in files and carried in JSON")
    func chatMetaClosed() throws {
        let yaml = "id: 3F2504E0-4F89-11D3-9A0C-0305E82C3301\nkind: project\ncreated: 2026-10-31T13:00:00Z\n"
        var meta = try YAMLCoding.decode(ChatMeta.self, from: yaml)
        #expect(!meta.closed)
        #expect(meta.unknownKeys.isEmpty)
        #expect(try YAMLCoding.encode(meta).contains("sessionStarted: false\nclosed: false\n"))
        meta.closed = true
        let written = try YAMLCoding.encode(meta)
        #expect(written.contains("closed: true\n"))
        #expect(try YAMLCoding.decode(ChatMeta.self, from: written).closed)
        let json = try StorageJSON.lineEncoder().encode(meta)
        #expect(try StorageJSON.decoder().decode(ChatMeta.self, from: json).closed)
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
            .symbol(SymbolItem(id: "sy", created: created, requestID: UUID(), question: "Which?", suggestions: ["star", "heart"],
                               recommended: "star")),
            .symbol(SymbolItem(id: "sa", created: created, requestID: UUID(), question: "Which?", suggestions: ["star", "heart"],
                               recommended: "star", answer: "![](sf:heart)")),
            .color(ColorItem(id: "co", created: created, requestID: UUID(), question: "Which?", lightAndDark: false,
                             suggestions: [.color("#FF9500"), .color("systemBlue")], recommended: .color("systemBlue"))),
            .color(ColorItem(id: "cp", created: created, requestID: UUID(), question: "Which?", lightAndDark: true,
                             suggestions: [.pair(light: "#FFFFFF", dark: "#1C1C1E"), .pair(light: "white", dark: "black")],
                             recommended: .pair(light: "#FFFFFF", dark: "#1C1C1E"), answer: "Skipped")),
            .sound(SoundItem(id: "so", created: created, requestID: UUID(), question: "Which?",
                             suggestions: ["macOS/Glass.aiff", "iOS 26.1/sms-received1.caf"], recommended: "macOS/Glass.aiff",
                             answer: "![](sound:iOS 26.1/sms-received1.caf)")),
            .shortcut(ShortcutItem(id: "sc", created: created, requestID: UUID(), question: "Which?", suggestions: ["⇧⌘K", "⌘K"],
                                   recommended: "⇧⌘K", inUse: [ShortcutInUse(shortcut: "⌘N", command: "New Ticket")],
                                   answer: "![](shortcut:⌘K)")),
            .font(FontItem(id: "fo", created: created, requestID: UUID(), question: "Which?", sample: "Title",
                           suggestions: [".headline", "System/Bold/17"], recommended: ".headline")),
            .font(FontItem(id: "fa", created: created, requestID: UUID(), question: "Which?", sample: "Title",
                           suggestions: [".headline", "System/Bold/17"], recommended: ".headline", answer: "![](font:System/Bold/17)")),
            .animation(AnimationItem(id: "an", created: created, requestID: UUID(), question: "How?", suggestions: [".snappy", ".smooth"],
                                     recommended: ".snappy", answer: "![](animation:.smooth)")),
            .images(ImagesItem(id: "im", created: created, caption: "Preview", images: [
                HephaestusCore.Attachment(id: UUID(), name: "icon.png", path: "chats/C/icon.png", contentType: "image/png", size: 3),
            ])),
            .images(ImagesItem(id: "in", created: created, images: [
                HephaestusCore.Attachment(id: UUID(), name: "a.gif", path: "chats/C/a.gif", contentType: "image/gif", size: 4),
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
        #expect(items.map(\.id) == ["u", "a", "t", "tu", "tr", "p", "q", "sy", "sa", "co", "cp", "so", "sc", "fo", "fa", "an", "im", "in",
                                    "s", "r"])
    }

    @Test("The images item of docs/data-model.md › Images item: caption null when Claude gave none")
    func imagesItem() throws {
        let markdown = try Repository.doc("data-model.md")
        let start = try #require(markdown.range(of: "### Images item")).upperBound
        let line = try #require(markdown[start...].split(separator: "\n").first { $0.hasPrefix(#"{"type":"images""#) })
        let item = try StorageJSON.decoder().decode(ChatItem.self, from: Data(line.utf8))
        guard case .images(var shown) = item else {
            Issue.record("not an images item")
            return
        }
        #expect(shown.caption == "Preview of the new app icon at 1024 px.")
        #expect(shown.images.map(\.name) == ["icon-1024.png"])
        #expect(shown.images.first?.contentType == "image/png")
        shown.caption = nil
        let encoded = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(ChatItem.images(shown)))
        #expect(encoded.objectValue?["caption"] == .null)
        #expect(encoded.objectValue?["type"] == "images")
    }

    @Test("A question without kind is single, its recommended a string; a multiple one writes a list (docs/data-model.md › Questions item)")
    func questionKinds() throws {
        let old = #"{"label":"A","question":"Which?","options":[{"label":"x","description":null},{"label":"y","description":null}],"recommended":"x"}"#
        let single = try StorageJSON.decoder().decode(Question.self, from: Data(old.utf8))
        #expect(single.kind == .single && single.recommended == ["x"] && single.minChoices == nil && single.maxChoices == nil)
        let encodedSingle = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(single)).objectValue
        #expect(encodedSingle?["kind"] == .string("single") && encodedSingle?["recommended"] == .string("x"))

        let line = #"{"label":"A","question":"Which?","kind":"multiple","options":[{"label":"x"},{"label":"y"},{"label":"z"}],"recommended":["x","y"],"maxChoices":3}"#
        let multiple = try StorageJSON.decoder().decode(Question.self, from: Data(line.utf8))
        #expect(multiple.kind == .multiple && multiple.recommended == ["x", "y"] && multiple.minChoices == nil && multiple.maxChoices == 3)
        let data = try StorageJSON.lineEncoder().encode(multiple)
        #expect(try StorageJSON.decoder().decode(Question.self, from: data) == multiple)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
        #expect(encoded?["recommended"] == .array([.string("x"), .string("y")]) && encoded?["minChoices"] == .null)

        // A lone label in a multiple question reads as a list of one label.
        let lone = #"{"label":"A","question":"Which?","kind":"multiple","options":[{"label":"x"},{"label":"y"}],"recommended":"y"}"#
        #expect(try StorageJSON.decoder().decode(Question.self, from: Data(lone.utf8)).recommended == ["y"])
        let number = #"{"label":"A","question":"Which?","options":[{"label":"x"},{"label":"y"}],"recommended":1}"#
        #expect(throws: DecodingError.self) { try StorageJSON.decoder().decode(Question.self, from: Data(number.utf8)) }
    }

    @Test("The symbol item of docs/data-model.md › Symbol item: answer null until the user answers")
    func symbolItem() throws {
        let line = #"{"type":"symbol","id":"6C9D1E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F","created":"2026-11-01T14:20:01Z","requestID":"6C9D1E2F-3A4B-4C5D-8E6F-7A8B9C0D1E2F","question":"Which icon should the filter button use?","suggestions":["line.3.horizontal.decrease.circle","line.3.horizontal.decrease","slider.horizontal.3"],"recommended":"line.3.horizontal.decrease.circle","answer":"![](sf:line.3.horizontal.decrease.circle)"}"#
        let item = try StorageJSON.decoder().decode(ChatItem.self, from: Data(line.utf8))
        guard case .symbol(var request) = item else {
            Issue.record("not a symbol item")
            return
        }
        #expect(request.answer == "![](sf:line.3.horizontal.decrease.circle)")
        #expect(request.suggestions.count == 3 && request.recommended == "line.3.horizontal.decrease.circle")
        request.answer = nil
        let encoded = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(ChatItem.symbol(request)))
        #expect(encoded.objectValue?["answer"] == .null)
    }

    @Test("The color item of docs/data-model.md › Color item: pairs as objects, answer null until the user answers")
    func colorItem() throws {
        let line = ##"{"type":"color","id":"7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A","created":"2026-11-03T14:20:01Z","requestID":"7D0E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A","question":"Which background color should the card use?","lightAndDark":true,"suggestions":[{"light":"#FFFFFF","dark":"#1C1C1E"},{"light":"systemBackground","dark":"secondarySystemBackground"}],"recommended":{"light":"#FFFFFF","dark":"#1C1C1E"},"answer":"Light ![](color:#FFFFFF), Dark ![](color:#2C2C2E)"}"##
        let item = try StorageJSON.decoder().decode(ChatItem.self, from: Data(line.utf8))
        guard case .color(var request) = item else {
            Issue.record("not a color item")
            return
        }
        #expect(request.lightAndDark && request.answer == "Light ![](color:#FFFFFF), Dark ![](color:#2C2C2E)")
        #expect(request.suggestions == [.pair(light: "#FFFFFF", dark: "#1C1C1E"),
                                        .pair(light: "systemBackground", dark: "secondarySystemBackground")])
        #expect(request.recommended == .pair(light: "#FFFFFF", dark: "#1C1C1E"))
        request.answer = nil
        let encoded = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(ChatItem.color(request)))
        #expect(encoded.objectValue?["answer"] == .null)
        #expect(encoded.objectValue?["recommended"] == .object(["light": "#FFFFFF", "dark": "#1C1C1E"]))
    }

    @Test("The sound item of docs/data-model.md › Sound item: answer null until the user answers")
    func soundItem() throws {
        let line = #"{"type":"sound","id":"8E1F2A3B-4C5D-4E6F-9A7B-8C9D0E1F2A3B","created":"2026-11-03T18:40:12Z","requestID":"8E1F2A3B-4C5D-4E6F-9A7B-8C9D0E1F2A3B","question":"Which sound should the app play when a message arrives?","suggestions":["iOS 26.1/sms-received1.caf","iOS 26.1/new-mail.caf","Project/Sounds/alert.caf"],"recommended":"iOS 26.1/sms-received1.caf","answer":"![](sound:iOS 26.1/sms-received1.caf)"}"#
        let item = try StorageJSON.decoder().decode(ChatItem.self, from: Data(line.utf8))
        guard case .sound(var request) = item else {
            Issue.record("not a sound item")
            return
        }
        #expect(request.answer == "![](sound:iOS 26.1/sms-received1.caf)")
        #expect(request.suggestions.count == 3 && request.recommended == "iOS 26.1/sms-received1.caf")
        request.answer = nil
        let encoded = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(ChatItem.sound(request)))
        #expect(encoded.objectValue?["answer"] == .null)
        #expect(encoded.objectValue?["type"] == .string("sound"))
    }

    @Test("The shortcut item of docs/data-model.md › Shortcut item: answer null until the user answers")
    func shortcutItem() throws {
        let doc = try Repository.doc("data-model.md")
        let block = try #require(MarkdownSource.fencedBlocks(in: doc).first { $0.heading == "### Shortcut item" && $0.info == "json" })
        let item = try StorageJSON.decoder().decode(ChatItem.self, from: Data(block.text.utf8))
        guard case .shortcut(var request) = item else {
            Issue.record("not a shortcut item")
            return
        }
        #expect(request.answer == "![](shortcut:⇧⌘F)")
        #expect(request.suggestions == ["⇧⌘F", "⌥⌘F", "⌃⌘F"] && request.recommended == "⇧⌘F")
        #expect(request.inUse == [ShortcutInUse(shortcut: "⌘N", command: "New Ticket")])
        request.answer = nil
        let encoded = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(ChatItem.shortcut(request)))
        #expect(encoded.objectValue?["answer"] == .null)
        #expect(encoded.objectValue?["inUse"] == [["shortcut": "⌘N", "command": "New Ticket"]])
    }

    @Test("The font item of docs/data-model.md › Font item: answer null until the user answers")
    func fontItem() throws {
        let doc = try Repository.doc("data-model.md")
        let section = try #require(doc.range(of: "### Font item")).upperBound
        let start = try #require(doc.range(of: "```json\n", range: section..<doc.endIndex)).upperBound
        let end = try #require(doc.range(of: "\n```", range: start..<doc.endIndex)).lowerBound
        let item = try StorageJSON.decoder().decode(ChatItem.self, from: Data(doc[start..<end].utf8))
        guard case .font(var request) = item else {
            Issue.record("not a font item")
            return
        }
        #expect(request.answer == "![](font:Avenir Next/Demi Bold/15)")
        #expect(request.sample == "Replace the status filter with a Filter by Status menu")
        #expect(request.suggestions == ["System Rounded/Semibold/17", "Avenir Next/Demi Bold/15", ".headline"])
        #expect(request.recommended == "System Rounded/Semibold/17")
        request.answer = nil
        let encoded = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(ChatItem.font(request)))
        #expect(encoded.objectValue?["answer"] == .null)
        #expect(encoded.objectValue?["type"] == .string("font"))
    }

    @Test("The animation item of docs/data-model.md › Animation item: answer null until the user answers")
    func animationItem() throws {
        let line = #"{"type":"animation","id":"8E1F2A3B-4C5D-4E6F-9A0B-1C2D3E4F5A6B","created":"2026-11-03T14:20:01Z","requestID":"8E1F2A3B-4C5D-4E6F-9A0B-1C2D3E4F5A6B","question":"How should the sidebar slide in?","suggestions":[".snappy",".spring(duration: 0.4, bounce: 0.2)",".easeInOut(duration: 0.25)"],"recommended":".snappy","answer":"![](animation:.spring(duration: 0.4, bounce: 0.2))"}"#
        let item = try StorageJSON.decoder().decode(ChatItem.self, from: Data(line.utf8))
        guard case .animation(var request) = item else {
            Issue.record("not an animation item")
            return
        }
        #expect(request.answer == "![](animation:.spring(duration: 0.4, bounce: 0.2))")
        #expect(request.suggestions.count == 3 && request.recommended == ".snappy")
        request.answer = nil
        let encoded = try JSONDecoder().decode(JSONValue.self, from: StorageJSON.lineEncoder().encode(ChatItem.animation(request)))
        #expect(encoded.objectValue?["answer"] == .null)
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
