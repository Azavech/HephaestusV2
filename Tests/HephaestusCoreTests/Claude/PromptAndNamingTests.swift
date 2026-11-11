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

    @Test("The feedback skill describes the feedback chat without placeholders; a feedback chat's system prompt is the common skill alone")
    func feedbackChatDescription() throws {
        let feedback = try Self.skill("feedback")
        #expect(feedback.contains("This is a feedback chat. The user sent feedback about HephaestusV2 from the window they were using: "
            + "their comment, followed by the feedback context:\n\n<feedback>\n$ARGUMENTS\n</feedback>"))
        #expect(feedback.contains("Your goal is to turn the feedback into a ticket of this chat's project."))
        #expect(!feedback.contains("{{"))
        #expect(Prompts.skills(of: .feedback) == [.common])
        let values = ["projectName": "Hephaestus V2", "projectID": "HEPH"]
        #expect(Prompts.systemPrompt(kind: .feedback, values: values) == Prompts.render(.common, Prompts.text(.common), values))
    }

    /// The environments of the `{{environments}}` example of docs/chats.md › Rendered blocks: one
    /// without any Kubernetes field, one that allows invalid certificates with every field and the
    /// kubectl context of an earlier version, which the block leaves out, and one without a URL.
    static let exampleEnvironments = [
        ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080),
        ProjectEnvironment(name: "staging", url: "https://staging.example.com/", allowInvalidCertificates: true, namespace: "orders",
                           deployment: "orders-api", argoCDApplication: "argocd/orders-staging", kubeconfig: "~/.kube/staging.yaml",
                           unknownKeys: ["context": "staging-eks"]),
        ProjectEnvironment(name: "preview", port: 8080, namespace: "orders-preview", kubeconfig: "/Users/example/.kube/preview.yaml"),
    ]

    /// The line of `{{environments}}` that follows its blank line.
    static let environmentsHeader = "The project's environments, where the Go service runs; the Kubernetes, Argo CD and API tools take an environment's name:"

    @Test("{{environments}} of a Go service: a blank line, then the example of docs/chats.md › Rendered blocks")
    func environmentsBlock() throws {
        let blocks = MarkdownSource.fencedBlocks(in: try Repository.doc("chats.md"))
        let documented = try #require(blocks.first { $0.text.hasPrefix(Self.environmentsHeader + "\n") })
        #expect(Prompts.environments(Self.exampleEnvironments, current: "staging", type: .goService) == "\n\n" + documented.text)
    }

    @Test("{{environments}}: the base URL, or the name alone without URL, then each Kubernetes field set, in the documented order and as stored; an Argo CD application <name> stays <name>; then the current working environment, the first without one")
    func environmentsFields() {
        let environments = [
            ProjectEnvironment(name: "prod", url: "https://api.example.com:8443/v1/", port: 9000, deployment: "orders-api",
                               argoCDApplication: "orders-prod"),
            ProjectEnvironment(name: "Preview", url: "https://preview.example.com", namespace: "orders-preview",
                               kubeconfig: "/Users/example/.kube/preview.yaml"),
            ProjectEnvironment(name: "dev", url: "http://127.0.0.1:8080", unknownKeys: ["context": "kind-dev"]),
            ProjectEnvironment(name: "New Environment"),
            ProjectEnvironment(name: "qa", deployment: "orders-api"),
        ]
        let lines = [
            "- prod: https://api.example.com:9000/v1; deployment: orders-api; Argo CD application: orders-prod",
            "- Preview: https://preview.example.com; namespace: orders-preview; kubeconfig file: /Users/example/.kube/preview.yaml",
            "- dev: http://127.0.0.1:8080",
            "- New Environment",
            "- qa; deployment: orders-api",
        ]
        #expect(Prompts.environments(environments, current: "dev", type: .goService) == "\n\n\(Self.environmentsHeader)\n"
            + (lines + ["The current working environment is dev: use it when the user names no environment."]).joined(separator: "\n"))
        #expect(Prompts.environments(environments, current: nil, type: .goService) == "\n\n\(Self.environmentsHeader)\n"
            + (lines + ["The current working environment is prod: use it when the user names no environment."]).joined(separator: "\n"))
    }

    @Test("{{environments}}: `; invalid certificates allowed` after the base URL of an environment that allows them, before its Kubernetes fields; none without a URL or with the setting off")
    func environmentsInvalidCertificates() {
        let environments = [
            ProjectEnvironment(name: "prod", url: "https://10.0.0.5:443/orders/", allowInvalidCertificates: true, deployment: "orders-api"),
            ProjectEnvironment(name: "lab", url: "https://lab.example.com", allowInvalidCertificates: true),
            ProjectEnvironment(name: "qa", url: "https://qa.example.com", allowInvalidCertificates: false),
            ProjectEnvironment(name: "draft", allowInvalidCertificates: true, namespace: "orders"),
        ]
        #expect(Prompts.environments(environments, current: "prod", type: .goService) == "\n\n\(Self.environmentsHeader)\n" + [
            "- prod: https://10.0.0.5:443/orders; invalid certificates allowed; deployment: orders-api",
            "- lab: https://lab.example.com; invalid certificates allowed",
            "- qa: https://qa.example.com",
            "- draft; namespace: orders",
            "The current working environment is prod: use it when the user names no environment.",
        ].joined(separator: "\n"))
    }

    @Test("{{environments}}: the none line for a Go service without environments; empty for the other types, environments or not")
    func environmentsNoneAndOtherTypes() {
        #expect(Prompts.environments([], current: nil, type: .goService) == "\n\n\(Self.environmentsHeader)\n- none: the user adds them in Project Settings")
        for type in [ProjectType.none, .swiftApplication] {
            #expect(Prompts.environments(Self.exampleEnvironments, current: "local", type: type) == "", "\(type)")
            #expect(Prompts.environments([], current: nil, type: type) == "", "\(type)")
        }
    }

    @Test("The common prompt of a Go service has the environments after the project's type, then a blank line; another type has none")
    func environmentsInCommonPrompt() {
        var values = ["projectName": "Orders", "projectID": "ORD", "projectRoot": "/Users/example/Developer/orders",
                      "workingDirectory": "It is your working directory.", "deviceName": "Studio", "docsPath": "docs",
                      "projectType": "Go service",
                      "environments": Prompts.environments(Self.exampleEnvironments, current: "staging", type: .goService),
                      "parentMemories": ""]
        let go = Prompts.render(Prompts.text(.common), values)
        let block = [
            "The project's type is Go service.\n",
            Self.environmentsHeader,
            "- local: http://127.0.0.1:8080",
            "- staging: https://staging.example.com; invalid certificates allowed; namespace: orders; deployment: orders-api; "
                + "Argo CD application: argocd/orders-staging; kubeconfig file: ~/.kube/staging.yaml",
            "- preview; namespace: orders-preview; kubeconfig file: /Users/example/.kube/preview.yaml",
            "The current working environment is staging: use it when the user names no environment.\n",
            "These rules apply in every chat.",
        ].joined(separator: "\n")
        #expect(go.contains(block))

        values["environments"] = Prompts.environments([], current: nil, type: .goService)
        #expect(Prompts.render(Prompts.text(.common), values).contains("The project's type is Go service.\n\n\(Self.environmentsHeader)\n"
            + "- none: the user adds them in Project Settings\n\nThese rules apply in every chat."))

        values["projectType"] = "None"
        values["environments"] = Prompts.environments(Self.exampleEnvironments, current: "local", type: .none)
        let none = Prompts.render(Prompts.text(.common), values)
        #expect(none.contains("The project's type is None.\n\nThese rules apply in every chat."))
        #expect(!none.contains(Self.environmentsHeader))
    }

    @Test("The common prompt lists the API tools and tells Claude to call the service's API with them, not curl; api_operations is pre-approved")
    func apiToolsPrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("- The API of a Go service project: api_operations (lists the operations of its OpenAPI contract "
            + "openapi/contract.yaml), api_call (calls one of them on an environment of the project, with the credentials and headers stored "
            + "in the API Explorer).\n"))
        let lower = try #require(common.range(of: "# Environments of a Go service")).lowerBound
        let upper = try #require(common.range(of: "# When the project is HephaestusV2")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("read and change the service through its API with api_operations and api_call and the environment's name, "
            + "never with curl and a guessed URL, certificate flags or credentials"))
        let tools = ClaudeCommandLine.preApprovedTools.split(separator: ",").map(String.init)
        #expect(tools.contains("mcp__hephaestus__api_operations"))
        #expect(!tools.contains("mcp__hephaestus__api_call"))
    }

    @Test("The common prompt lists the Kubernetes and Argo CD tools and tells Claude to use them with an environment's name; the four that read are pre-approved")
    func kubernetesToolsPrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("- Kubernetes and Argo CD, in a Go service project: k8s_status, k8s_logs, k8s_events, k8s_restart, k8s_scale, "
            + "k8s_port_forward, k8s_stop_port_forward, argocd_status, argocd_sync (they act on the deployment and the Argo CD application "
            + "of an environment of the project, with its kubeconfig file and namespace).\n"))
        let lower = try #require(common.range(of: "# Environments of a Go service")).lowerBound
        let upper = try #require(common.range(of: "# When the project is HephaestusV2")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("use the Kubernetes and Argo CD tools with its name, never kubectl with a guessed kubeconfig file, namespace or "
            + "deployment: the tools use the environment's kubeconfig file, namespace, deployment and Argo CD application."))
        #expect(!common.contains("kubectl context"))
        #expect(section.contains("Stop a port forward with k8s_stop_port_forward once you no longer need it."))
        #expect(ClaudeCommandLine.preApprovedTools.contains(",mcp__hephaestus__get_chat,mcp__hephaestus__get_view_previews,mcp__hephaestus__k8s_status,mcp__hephaestus__k8s_logs,"
            + "mcp__hephaestus__k8s_events,mcp__hephaestus__argocd_status,mcp__hephaestus__api_operations,"))
    }

    @Test("{{globalMemories}}: the folder and the trimmed text of MEMORY.md, at most 200 lines and 25,000 characters")
    func globalMemoriesBlock() {
        let folder = "/Users/example/.claude/memory"
        let header = "The global memories folder is /Users/example/.claude/memory. Its MEMORY.md:"
        let truncated = "[Truncated: read /Users/example/.claude/memory/MEMORY.md for the other lines.]"
        // The example of docs/chats.md › Rendered blocks, from a file with CR LF and blank lines around.
        #expect(Prompts.globalMemories(folder: folder, index: "\n- [Short answers](answer-style.md) — the user wants short answers in every project\r\n"
            + "- [No force push](no-force-push.md) — never force-push, in any repository\n\n")
            == header + "\n- [Short answers](answer-style.md) — the user wants short answers in every project\n"
            + "- [No force push](no-force-push.md) — never force-push, in any repository")
        let none = "The global memories folder is /Users/example/.claude/memory. Its MEMORY.md has no line yet."
        #expect(Prompts.globalMemories(folder: folder, index: nil) == none)
        #expect(Prompts.globalMemories(folder: folder, index: " \r\n\n") == none)
        // 201 lines keep the first 200.
        let lines = (1...201).map { "- [m\($0)](m\($0).md) — memory \($0)" }
        #expect(Prompts.globalMemories(folder: folder, index: lines.joined(separator: "\n") + "\n")
            == header + "\n" + lines.prefix(200).joined(separator: "\n") + "\n" + truncated)
        #expect(Prompts.globalMemories(folder: folder, index: lines.prefix(200).joined(separator: "\n"))
            == header + "\n" + lines.prefix(200).joined(separator: "\n"))
        // More than 25,000 characters: cut at the last line break before the limit.
        let first = String(repeating: "a", count: 24_990)
        #expect(Prompts.globalMemories(folder: folder, index: first + "\n" + String(repeating: "b", count: 20))
            == header + "\n" + first + "\n" + truncated)
        let exact = String(repeating: "c", count: 25_000)
        #expect(Prompts.globalMemories(folder: folder, index: exact) == header + "\n" + exact)
        #expect(Prompts.globalMemories(folder: folder, index: exact + "c") == header + "\n" + truncated)
    }

    @Test("Prompt: common states the global memories rule after the global memories block")
    func globalMemoriesRule() throws {
        let common = Prompts.text(.common)
        let section = String(common[common.range(of: "# Global memories")!.lowerBound..<common.range(of: "# Environments of a Go service")!.lowerBound])
        let block = try #require(section.range(of: "\n\n{{globalMemories}}\n\n"))
        let rule = try #require(section.range(of: "a memory that holds for every project goes to the global memories folder, with its line in the global "
            + "MEMORY.md; the other memories go to the project's memory folder."))
        #expect(block.upperBound <= rule.lowerBound)
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
            "deviceName": "Studio", "docsPath": "docs", "projectType": "Go service",
            "environments": "\n\nThe project's environments, where the Go service runs; the Kubernetes, Argo CD and API tools take an environment's name:\n"
                + "- staging: https://staging.example.com; deployment: orders-api",
            "ticketID": "HEPH-12", "ticket": "ID: HEPH-12", "bundleID": "HEPH-B2", "bundle": "ID: HEPH-B2",
            "githubRepository": "Azavech/HephaestusV2", "parentMemories": "",
            "imageID": "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F", "imageVersion": "27.2.1",
            "globalMemories": "The global memories folder is /Users/example/.claude/memory. Its MEMORY.md has no line yet.",
        ]
        for skill in PromptSkill.allCases {
            let text = Prompts.text(skill)
            #expect(!text.isEmpty, "\(skill.rawValue)")
            #expect(!text.hasSuffix("\n"))
            #expect(!Prompts.render(skill, text, values).contains("{{"), "\(skill.rawValue)")
        }
        let prompt = Prompts.systemPrompt(kind: .ticket, values: values)
        #expect(prompt.hasPrefix("You are Claude, working inside HephaestusV2"))
        #expect(prompt.contains("The project's root folder is /Users/example/Developer/HephaestusV2 on the device Studio. It is your working directory. "))
        #expect(prompt.contains("of the project. The project's type is Go service.\n\nThe project's environments, where the Go service runs; "
            + "the Kubernetes, Argo CD and API tools take an environment's name:\n- staging: https://staging.example.com; deployment: orders-api\n\n"
            + "These rules apply in every chat."))
        #expect(prompt.contains("\n\n# This chat\n\nThis is the chat of ticket HEPH-12"))
        // The memories of the parent projects follow the first paragraph and, in a Go service project, its environments.
        var inherited = values
        inherited["parentMemories"] = Prompts.parentMemories([
            .init(projectName: "Suite", projectID: "SUITE", path: "/Users/example/.claude/projects/-Users-example-Developer-Suite/memory",
                  index: "- [Answer style](feedback_style.md) — Answer in short sentences\n"),
        ])
        #expect(Prompts.systemPrompt(kind: .ticket, values: inherited).contains(
            "- staging: https://staging.example.com; deployment: orders-api\n\n" + Prompts.parentMemoriesIntro
                + "\n\nMemories of the project Suite (identifier SUITE), in the folder /Users/example/.claude/projects/-Users-example-Developer-Suite/memory:\n"
                + "- [Answer style](feedback_style.md) — Answer in short sentences\n\nThese rules apply in every chat."))
    }

    @Test("{{parentMemories}} renders the example of docs/chats.md › Rendered blocks, and nothing without inherited folder")
    func parentMemoriesBlock() throws {
        let blocks = MarkdownSource.fencedBlocks(in: try Repository.doc("chats.md"))
        let documented = try #require(blocks.first { $0.text.hasPrefix("This project is a sub project:") })
        let rendered = Prompts.parentMemories([
            .init(projectName: "Suite", projectID: "SUITE", path: "/Users/example/.claude/projects/-Users-example-Developer-Suite/memory",
                  index: "- [User role](user-role.md) — The user is a backend developer who is new to SwiftUI\n"
                      + "- [Answer style](feedback_style.md) — Answer in short sentences\n"),
        ])
        #expect(rendered == "\n\n" + documented.text)
        #expect(Prompts.parentMemories([]) == "")
        // Nearest parent first, each part after a blank line; a missing or empty MEMORY.md.
        let two = Prompts.parentMemories([
            .init(projectName: "App", projectID: "APP", path: "/m/app", index: nil),
            .init(projectName: "Suite", projectID: "SUITE", path: "/m/suite", index: " \r\n\n"),
        ])
        #expect(two == "\n\n" + Prompts.parentMemoriesIntro
            + "\n\nMemories of the project App (identifier APP), in the folder /m/app:\nThis folder has no MEMORY.md."
            + "\n\nMemories of the project Suite (identifier SUITE), in the folder /m/suite:\nThis folder has no MEMORY.md.")
    }

    @Test("The MEMORY.md of an inherited folder: line breaks, white space, then the CLI's limits of 200 lines and 25,000 UTF-16 units")
    func parentMemoryIndexLines() {
        let truncated = "\n[Truncated: read /m/MEMORY.md for the rest.]"
        #expect(Prompts.memoryIndexLines("\u{FEFF}\n- [A](a.md) — A\r\n- [B](b.md) — B\r\r\n  \n", folder: "/m")
            == "- [A](a.md) — A\n- [B](b.md) — B")
        #expect(Prompts.memoryIndexLines(" \n\t", folder: "/m") == "")
        let lines = (1...201).map { "- line \($0)" }
        #expect(Prompts.memoryIndexLines(lines.prefix(200).joined(separator: "\n"), folder: "/m") == lines.prefix(200).joined(separator: "\n"))
        #expect(Prompts.memoryIndexLines(lines.joined(separator: "\n"), folder: "/m") == lines.prefix(200).joined(separator: "\n") + truncated)
        // 150 lines of 200 units: the 124 lines whose line break comes within 25,000 units.
        let long = (1...150).map { _ in String(repeating: "x", count: 200) }
        #expect(Prompts.memoryIndexLines(long.joined(separator: "\n"), folder: "/m") == long.prefix(124).joined(separator: "\n") + truncated)
        // A line break at offset 25,000 still ends the kept text; without one, what fits is kept.
        let edge = String(repeating: "a", count: 25_000)
        #expect(Prompts.memoryIndexLines(edge + "\nb", folder: "/m") == edge + truncated)
        let early = "x\n" + String(repeating: "a", count: 24_998)
        #expect(Prompts.memoryIndexLines(early + "\nb", folder: "/m") == early + truncated)
        #expect(Prompts.memoryIndexLines(early + "a\nb", folder: "/m") == "x" + truncated)
        #expect(Prompts.memoryIndexLines(edge, folder: "/m") == edge)
        #expect(Prompts.memoryIndexLines(edge + "b", folder: "/m") == edge + truncated)
        let emoji = String(repeating: "a", count: 24_999) + "😀"
        #expect(Prompts.memoryIndexLines(emoji, folder: "/m") == String(repeating: "a", count: 24_999) + truncated)
    }

    /// The default SKILL.md of an internal skill, as text (docs/skills.md › Default SKILL.md files).
    static func skill(_ name: String) throws -> String {
        String(decoding: try #require(InternalSkills.defaultContent(name)), as: UTF8.self)
    }

    /// The part of `text` from `start` to `end`, or to its end without `end`.
    static func part(_ text: String, _ start: String, _ end: String? = nil) throws -> String {
        let lower = try #require(text.range(of: start)).lowerBound
        guard let end else { return String(text[lower...]) }
        let upper = try #require(text.range(of: end, range: lower..<text.endIndex)).lowerBound
        return String(text[lower..<upper])
    }

    @Test("Bundle orchestration: the orchestrator starts every ticket that waits for nothing at once, merges by rebase and fast-forward, asks retry, skip or stop, builds, tests and pushes once, never sets done; ticket chats commit on their branch without pushing")
    func bundleOrchestrationPrompts() throws {
        let section = try Self.skill("implement-bundle")
        #expect(section.contains("Argument: $ARGUMENTS, the id of the bundle to implement."))
        #expect(section.contains("A ticket waits for the tickets of this bundle that it declares a Depends on link to and that are not done; "
            + "Related links and tickets outside the bundle never make it wait."))
        #expect(section.contains("Call implement_ticket for every ticket that waits for nothing, all in the same turn, then end your turn."))
        #expect(section.contains("whose first message calls hephaestus-skills:implement-ticket with the ticket id and the bundle id"))
        #expect(section.contains("Merge a branch into main by rebasing it onto main in its worktree (git -C <worktree> rebase <main>), "
            + "then fast-forwarding main to it in the project root (git merge --ff-only <branch>)"))
        #expect(section.contains("ask the user with ask_questions whether to retry the ticket, skip it or stop the bundle; the other ticket chats keep running."))
        #expect(section.contains("Skip every ticket of the bundle that depends on it too"))
        #expect(section.contains("start no other ticket chat and let the running ones finish; merge nothing, do not push, keep every branch and worktree, "
            + "and close none of the chats you started: a stopped bundle is not done."))
        #expect(section.contains("Then build and test main once, as step 5 of hephaestus-skills:implement-ticket describes."))
        #expect(section.contains("change the first line of each ticket's completion comment so that it names the hash of the ticket's commit on main."))
        #expect(!section.contains("one ticket chat runs at a time"))
        #expect(!section.contains("one at a time"))
        #expect(section.contains("- Never set a ticket to done, except after CI as \"Waiting for CI\" of hephaestus-skills:finish-implementation describes, "
            + "and in step 6 of its \"When the project is a Go service\" in a Go service project."))
        #expect(section.contains("After every ticket has reported back or been skipped, merge the branches not merged yet, in bundle order."))
        #expect(section.contains("When the build or the tests fail, do not push and ask the user with ask_questions how to proceed. Otherwise push once"))
        #expect(section.contains("- Your task is then done: close the ticket chats and CI chats you started, then your own chat, as \"Closing chats\" describes."))
        #expect(section.contains("Your final reply lists each ticket with the hash of its commit on main, or with skipped and the reason, "
            + "and names the conflicts you resolved and the chats that close_chat did not close."))
        #expect(section.contains("when the project has no remote, do not push. Then remove the worktree and the branch of each merged ticket"))
        #expect(!section.contains("with its own commit, push, completion comment"))
        // A ticket chat started by the bundle chat: the second argument of implement-ticket.
        let ticket = try Self.skill("implement-ticket")
        #expect(ticket.contains("Arguments: $ARGUMENTS\n\nThe first argument is the id of the ticket to implement. A second argument, when there is one, "
            + "is the id of the bundle whose bundle chat started this chat"))
        #expect(ticket.contains("Follow the steps above completely, except that you commit on your branch without pushing: "
            + "the bundle chat merges your branch and pushes once at the end."))
        #expect(ticket.contains("\" (not pushed: the bundle chat pushes at the end)\""))
        #expect(ticket.contains("6. Commit with a message of the form \"<type>: <summary> (<TICKET-ID>)\", then push, as \"Commits\" and \"Pushing\" describe."))
    }

    @Test("Go service projects: tickets have only Claude tests; after the push the chat waits for CI, runs the test service and the checks, fixing what fails, updates the completion comments and sets the status; bundle ticket chats leave their Claude tests to the bundle chat")
    func goServicePrompts() throws {
        let common = Prompts.text(.common)
        let finish = try Self.skill("finish-implementation")
        #expect(common.contains("of the project. The project's type is {{projectType}}.{{environments}}{{parentMemories}}\n"))
        let go = try Self.part(finish, "## When the project is a Go service")
        #expect(go.contains("- The Testing section of a ticket has only Claude bullets, each a check of the behaviour on the test service; it has no User bullet."))
        #expect(go.contains("The implement chat of a single ticket, started by Implement or by implement_ticket from a chat that is not a bundle chat, "
            + "posts its completion comment after its push, with the result waiting for the test service on each Claude line, then follows the steps below."))
        #expect(go.contains("In a bundle, the ticket chats do not run their Claude tests"))
        #expect(go.contains("1. CI: when the project has a GitHub page, follow \"Waiting for CI\", and go on with step 2 once the CI chat has reported "
            + "\"CI passed.\" or \"CI not checked.\". Otherwise wait with the gh CLI for the CI runs of the pushed commit until they end"))
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
            + "Then stop the test service and close the chats you started, as \"Closing chats\" describes. The bundle chat then closes its chat."))
        #expect(go.contains("these are the exceptions to \"Do not implement the tickets yourself\" and \"Never set a ticket to done\""))
        #expect(go.contains("It still asks as hephaestus-skills:implement-bundle describes after a ticket chat ends in error or is stopped"))
        // The environments stay in the common prompt.
        #expect(try Self.part(common, "# Environments of a Go service", "# When the project is HephaestusV2").contains(
            "When the project's type is Go service, its environments, listed at the start of these instructions, are where the service runs."))

        // The other sections and skills refer to it.
        #expect(try Self.part(common, "# Writing tickets", "# Ticket status").contains(
            "In a project whose type is Go service, the Testing section has only Claude bullets"))
        #expect(try Self.part(common, "# Ticket status", "# Implementation skills").contains(
            "- In a project whose type is Go service, the implement chat of a single ticket and the bundle chat set the tickets to done or review after the checks on the test service"))
        let ticket = try Self.skill("implement-ticket")
        #expect(ticket.contains("then follows \"When the project is a Go service\" of hephaestus-skills:finish-implementation, whose step 6 replaces step 8"))
        #expect(try Self.part(common, "# Commits", "# Pushing").contains(
            "Each fix of a failed CI run, and in a Go service project each fix of a failed check, gets its own commit too"))
        #expect(try Self.part(finish, "## Completion comment", "## Waiting for CI").contains(
            "the result of a Claude line is waiting for the test service until the checks on the test service have run"))
        let bundle = try Self.skill("implement-bundle")
        #expect(bundle.contains("Do not implement the tickets yourself, except the fix of a failed CI run after Fix and check again "
            + "(\"Waiting for CI\" of hephaestus-skills:finish-implementation) and the fixes of its \"When the project is a Go service\" in a Go service project."))
        #expect(bundle.contains("- In a project with a GitHub page, then follow \"Waiting for CI\" of hephaestus-skills:finish-implementation for the merged tickets; "
            + "in a Go service project, then follow its \"When the project is a Go service\" for them."))
        #expect(ticket.contains("- In a Go service project, do not run the Claude tests of your ticket: each Claude line of your completion comment "
            + "reads waiting for the test service, and you set the ticket to review."))
    }

    @Test("Claude sets review after the completion comment, in a ticket chat and in each ticket chat of a bundle")
    func reviewAfterCompletionComment() throws {
        let common = Prompts.text(.common)
        let status = try Self.part(common, "# Ticket status", "# Implementation skills")
        #expect(status.contains("review (finished, waiting for the user's review)"))
        #expect(status.contains("When you have finished a ticket, after its completion comment, set it with set_ticket_status to done when every Claude test of its Testing section has passed and the user has said in the chat that every User test has passed; otherwise set it to review"))
        #expect(status.contains("A ticket without a Testing section goes to review."))
        #expect(status.contains("set it to in_progress before your first change and back to review after the completion comment of the correction"))
        #expect(status.contains("Never change the status of a ticket that is done"))

        // The status step follows the completion comment, in every ticket chat.
        let ticket = try Self.skill("implement-ticket")
        let steps = try Self.part(ticket, "## Steps", "## Ticket chat started by a bundle chat")
        let comment = try #require(steps.range(of: "7. Post the completion comment"))
        let setStatus = try #require(steps.range(of: "8. Set the ticket to done or review with set_ticket_status"))
        #expect(comment.upperBound < setStatus.lowerBound)
        #expect(try Self.part(ticket, "## Ticket chat started by a bundle chat").contains("Follow the steps above completely"))
    }

    @Test("Testing lists no code tests, and a code-test bullet passes once a CI release contains the commit")
    func codeTestsOutOfTesting() throws {
        let common = Prompts.text(.common)
        let writing = try Self.part(common, "# Writing tickets", "# Ticket status")
        #expect(writing.contains("- Change: what changes in the docs and in the code, naming the docs files and the code areas, limited to what has been decided. It can name the code tests to add."))
        #expect(writing.contains("- Testing: one bullet per check of the behaviour in the running app that decides whether the ticket is done"))
        #expect(writing.contains("Never write a code test there: no bullet for a build or test command such as swift test, a unit test, a test file or the docs conformance tests."))
        #expect(writing.contains("name the tests to add under Change, and add them and run the build and test step before you commit"))

        let status = try Self.part(common, "# Ticket status", "# Implementation skills")
        #expect(status.contains("counts as passed once a release built by CI contains the ticket's commit."))

        let comment = try Self.part(try Self.skill("finish-implementation"), "## Completion comment", "## Waiting for CI")
        #expect(comment.contains("passed, failed, waiting for the user, or waiting for the release for a code-test bullet while no release built by CI contains the commit"))

        let tool = try #require(MCPToolCatalog.tool(named: "set_ticket_status", debugTools: false))
        #expect(tool.description.contains("A code-test bullet of the Testing section"))
        #expect(tool.description.contains("counts as passed once a release built by CI contains the ticket's commit."))
    }

    @Test("Testing: a User bullet only for the user's own accounts, data or hardware; Claude runs the other checks, in a VM when an isolated instance cannot")
    func userBulletsAndVMChecks() throws {
        let common = Prompts.text(.common)
        let writing = try Self.part(common, "# Writing tickets", "# Ticket status")
        #expect(writing.contains("- Claude: <test> for a check you run, on an isolated instance or in a virtual machine, or - User: <test> for a check the user performs."))
        #expect(writing.contains("Write a User bullet only for a check that needs the user's own accounts, data or hardware; every other check is a Claude bullet."))
        #expect(writing.contains("In a project whose type is Go service, the Testing section has only Claude bullets"))
        let hephaestus = try Self.part(common, "# When the project is HephaestusV2")
        #expect(hephaestus.contains("and a virtual machine for what those tools cannot do, as docs/development.md › VM checks describes"))

        let steps = try Self.part(try Self.skill("implement-ticket"), "## Steps", "## Ticket chat started by a bundle chat")
        let build = try #require(steps.range(of: "5. Build and test."))
        let commit = try #require(steps.range(of: "6. Commit"))
        let step5 = String(steps[build.lowerBound..<commit.lowerBound])
        #expect(step5.contains("Then run the Claude tests of the ticket's Testing section; in a project whose type is Go service, "
            + "they run on the test service after the push instead."))
        #expect(step5.contains("Run a check that needs what an isolated instance cannot do, for example menus, typed text, list rows, scrolling, "
            + "system dialogs or permission prompts, in a virtual machine, without asking, as \"Virtual machines\" describes: copy the build in "
            + "with vm_copy_in, run it there, and drive and observe it with the VM tools."))
        #expect(step5.contains("A check that cannot run, for example because vm_start fails, gets the result failed with the reason."))

        let comment = try Self.part(try Self.skill("finish-implementation"), "## Completion comment", "## Waiting for CI")
        #expect(comment.contains("You run the check of each Claude line yourself, in a virtual machine when an isolated instance cannot do it, "
            + "as step 5 of hephaestus-skills:implement-ticket describes."))
    }

    @Test("CI: the chat that pushed starts a CI chat with watch_ci and waits for CI before the status; a CI chat gets the ci prompt alone")
    func ciPrompts() throws {
        let common = Prompts.text(.common)
        let waiting = try Self.part(try Self.skill("finish-implementation"), "## Waiting for CI", "## When the project is a Go service")
        #expect(waiting.contains("1. After the push and the completion comment, call watch_ci with the full hash of the pushed commit (git rev-parse HEAD), "
            + "then end your turn."))
        #expect(waiting.contains("\"CI chat finished its turn:\" followed by that final reply, \"CI chat ended in error: <error message>\", "
            + "or \"CI chat was stopped.\"."))
        #expect(waiting.contains("set no ticket to done or review and do not close your chat until the CI chat has reported \"CI passed.\" "
            + "or \"CI not checked.\", or the user has chosen Finish without green CI."))
        #expect(waiting.contains("with the options Fix and check again, Re-run the failed runs and Finish without green CI"))
        #expect(waiting.contains("HephaestusV2 accepts this question also in an implement chat in which the user has not written."))
        #expect(waiting.contains("- Re-run the failed runs: run gh run rerun <run id> --repo <owner>/<name> --failed for each failed run, "
            + "<owner>/<name> being the project's GitHub page without https://github.com/, then call watch_ci with the same commit."))
        #expect(waiting.contains("A project or feedback chat that implements a ticket starts no CI chat, and neither does a chat that pushed no commit"))
        let ticket = try Self.skill("implement-ticket")
        #expect(ticket.contains("In a project with a GitHub page, in a ticket or bundle chat, then call watch_ci and wait for CI, as its \"Waiting for CI\" describes."))
        #expect(ticket.contains("Then close the CI chats you started, as \"Closing chats\" describes."))
        #expect(ticket.contains("- In a project with a GitHub page, set your ticket to review even when every test has passed: the bundle chat sets it after CI."))
        #expect(try #require(Prompts.text(.ci).range(of: "stop that background task with TaskStop and run gh run watch again")) != nil)
        #expect(try Self.part(common, "# Asking questions", "# Writing tickets").contains(
            "Only the question about a failed CI that hephaestus-skills:finish-implementation describes is accepted there."))
        let hephaestus = try Self.part(common, "# When the project is HephaestusV2")
        #expect(!common.contains("Do not wait for the pipeline"))
        #expect(hephaestus.contains("- Pushing to main starts a release: CI builds it, and the app installs it and restarts once no chat is running, "
            + "so after your CI chat and you have finished. The project has a GitHub page: wait for CI as hephaestus-skills:finish-implementation describes."))
        #expect(try Self.skill("implement-bundle").contains(
            "- In a project with a GitHub page, then follow \"Waiting for CI\" of hephaestus-skills:finish-implementation for the merged tickets"))

        // The CI chat's system prompt is the ci prompt alone, without the common prompt.
        let values = ["projectName": "Hephaestus V2", "projectID": "HEPH", "projectRoot": "/Users/example/Developer/HephaestusV2",
                      "deviceName": "Studio", "githubRepository": "Azavech/HephaestusV2"]
        let prompt = Prompts.systemPrompt(kind: .ci, values: values)
        #expect(prompt == Prompts.render(Prompts.text(.ci), values))
        #expect(prompt.hasPrefix("You are Claude, working inside HephaestusV2, a macOS app that coordinates the work on many projects. "
            + "This is a CI chat of the project Hephaestus V2 (identifier HEPH)"))
        #expect(prompt.contains("The project's GitHub repository is Azavech/HephaestusV2.\n\nThe first message names the commit by its full hash."))
        #expect(prompt.contains("gh run list --repo Azavech/HephaestusV2 --commit <hash>"))
        #expect(prompt.contains("- CI passed. when every run ended with success, neutral or skipped"))
        #expect(prompt.contains("- CI failed. when a run ended otherwise"))
        #expect(prompt.contains("- CI not checked. when no run of the commit appeared within 2 minutes"))
        #expect(!prompt.contains("# HephaestusV2 tools"))
        #expect(!prompt.contains("{{"))
        #expect(Prompts.skills(of: .ci) == [.ci])
        #expect(GitHubPage.repository(of: "https://github.com/Azavech/HephaestusV2") == "Azavech/HephaestusV2")
        #expect(GitHubPage.repository(of: "https://github.com/owner/name.git") == "owner/name.git")
        #expect(GitHubPage.repository(of: "https://gitlab.com/owner/name") == nil)
    }

    @Test("The common prompt lists close_chat and says when to call it, for other chats only when the user asks or for the chats an orchestrator started once its task is done")
    func closeChatPrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("- Chats: list_chats, get_chat (a chat and its transcript, for example another chat of the same ticket), rename_chat, close_chat (closes the chat you run in, the chats you started as their orchestrator, or chats of the project that the user asks you to close), watch_ci (starts a CI chat that follows the CI of a commit you pushed)."))
        let lower = try #require(common.range(of: "# Closing chats")).lowerBound
        let upper = try #require(common.range(of: "# When the project is HephaestusV2")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("After the call, finish your reply: when your turn ends, HephaestusV2 ends your session"))
        #expect(section.contains("- when the user asks you to close the chat;"))
        #expect(section.contains("- in a ticket chat, once you have set its ticket to done;"))
        #expect(section.contains("- in a bundle chat, once every ticket has been implemented or skipped and you have pushed, and, in a project with a GitHub page "
            + "or a Go service project, once hephaestus-skills:finish-implementation lets you finish;"))
        #expect(section.contains("- in a feedback chat, once you have created its ticket."))
        #expect(section.contains("Close a project chat only when the user asks for it."))
        #expect(section.contains("To close other chats of the project, call close_chat with chatIDs"))
        #expect(section.contains("Close another chat only when the user asks you to close it, never on your own, except the chats you orchestrate, below."))
        #expect(section.contains("Tell the user which chats were not closed and why."))
        // An orchestrator closes the chats it started once its task is done (docs/workflow.md › Project and feedback chats).
        #expect(section.contains("You orchestrate the chats whose orchestrator is the id of your chat: the ticket chats you start with implement_ticket "
            + "from a bundle chat for the tickets of its bundle, and the CI chats you start with watch_ci; the results of these tools and list_chats show "
            + "their orchestrator. When your task is done, close all of them on your own, "
            + "with one close_chat call whose chatIDs lists their ids; HephaestusV2 runs it without a permission prompt, also when chatIDs lists your own chat's id:"))
        #expect(section.contains("- in a bundle chat, after your push and, when you follow hephaestus-skills:finish-implementation, after it, "
            + "just before you close your own chat; when the user decided to stop the bundle, it is not done: close none of them;"))
        #expect(section.contains("- in a ticket chat that started CI chats, once you have set its ticket's status."))
        #expect(section.contains("Name the chats that were not closed in your final reply."))
        #expect(try Self.skill("implement-ticket").contains("Then close the CI chats you started, as \"Closing chats\" describes."))
        #expect(try Self.skill("implement-bundle").contains("- Your task is then done: close the ticket chats and CI chats you started, then your own chat, "
            + "as \"Closing chats\" describes."))
    }

    @Test("Claude asks only true unknowns and decides evident points, in every chat kind and in comment answers")
    func onlyTrueUnknowns() throws {
        let values = ["projectName": "Hephaestus V2", "projectID": "HEPH", "projectRoot": "/Users/example/Developer/HephaestusV2",
                      "deviceName": "Studio", "docsPath": "docs"]
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

    @Test("The rendered common prompt tells Claude to write an SF Symbol as ![](sf:<name>) in replies, ask_questions, ticket descriptions and comments")
    func sfSymbolPrompt() throws {
        let rule = "# SF Symbols\n\nWhen you name an SF Symbol in a reply, in ask_questions, or in a ticket description or a comment that "
            + "you write (create_ticket, update_ticket, add_comment, update_comment), write it as ![](sf:<name>), "
            + "for example ![](sf:line.3.horizontal.decrease.circle): HephaestusV2 shows the symbol's icon followed by its name there.\n\n"
        let values = ["projectName": "Hephaestus V2", "projectID": "HEPH", "projectRoot": "/Users/example/Developer/HephaestusV2",
                      "deviceName": "Studio", "docsPath": "docs"]
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
                      "deviceName": "Studio", "docsPath": "docs"]
        let common = Prompts.render(Prompts.text(.common), values)
        let lower = try #require(common.range(of: "# Colors\n\n")).lowerBound
        let upper = try #require(common.range(of: "# Sounds")).lowerBound
        let section = String(common[lower..<upper])
        #expect(section.contains("When you name a color in a reply, in ask_questions, or in a ticket description or a comment that you write, "
            + "write it as ![](color:<color>)"))
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

    @Test("The common prompt tells Claude to write sound, shortcut, font and animation markers in replies, ticket descriptions and comments")
    func ticketMarkersPrompt() throws {
        let common = Prompts.text(.common)
        func section(_ heading: String, before next: String) throws -> String {
            let lower = try #require(common.range(of: "# \(heading)\n")).lowerBound
            let upper = try #require(common.range(of: "# \(next)\n")).lowerBound
            return String(common[lower..<upper])
        }
        #expect(try section("Sounds", before: "Keyboard shortcuts").contains("When you name a sound in a reply, or in a ticket description or a "
            + "comment that you write, write it as ![](sound:<name>), <name> being a sound name as above, written as it is, spaces included"))
        #expect(try section("Keyboard shortcuts", before: "Fonts").contains("When you name a keyboard shortcut in a reply, or in a ticket "
            + "description or a comment that you write, write it as ![](shortcut:<shortcut>), <shortcut> being in this menu notation, its key an uppercase "
            + "letter, a digit or punctuation as typed without Shift, ↩ ⌤ ⎋ ⇥ Space ⌫ ⌦ ← → ↑ ↓ ↖ ↘ ⇞ ⇟, or F1 to F20, with a key (, ) or \\ "
            + "written with a \\ before it"))
        #expect(try section("Fonts", before: "Animations").contains("When you name a font in a reply, or in a ticket description or a "
            + "comment that you write, write it as ![](font:<font>)"))
        #expect(try section("Animations", before: "Images").contains("When you name an animation in a reply, or in a ticket description "
            + "or a comment that you write, write it as ![](animation:<expression>)"))
    }

    @Test("The comment-answer prompt tells Claude to write the six markers in its answer and in the ticket's description")
    func commentAnswerMarkersPrompt() throws {
        let answer = Prompts.text(.commentAnswer)
        let lower = try #require(answer.range(of: "# Markers\n")).lowerBound
        let upper = try #require(answer.range(of: "# Questions\n")).lowerBound
        let section = String(answer[lower..<upper])
        #expect(section.contains("When you name an SF Symbol, a color, a font, a keyboard shortcut, a sound or an animation in your reply "
            + "or in the ticket's description, write it as its marker, which HephaestusV2 draws there:"))
        for marker in ["![](sf:<name>)", "![](color:<color>)", "![](font:<font>)", "![](shortcut:<shortcut>)", "![](sound:<name>)",
                       "![](animation:<expression>)"] {
            #expect(section.contains("as \(marker), "), "\(marker)")
        }
        #expect(section.contains("the modifiers ⌃ ⌥ ⇧ ⌘ in this order, then one key, an uppercase letter, a digit or punctuation as typed "
            + "without Shift, ↩ ⌤ ⎋ ⇥ Space ⌫ ⌦ ← → ↑ ↓ ↖ ↘ ⇞ ⇟, or F1 to F20"))
        #expect(section.contains("<runtime> being the runtime's name in xcrun simctl list runtimes"))
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
                          "deviceName": "Studio", "docsPath": "docs"]
            #expect(Prompts.systemPrompt(kind: kind, values: values).contains("ask with ask_font"), "\(kind)")
        }
    }

    @Test("The common prompt lists show_image and tells Claude to show every image with it; show_image is pre-approved")
    func showImagePrompt() throws {
        let common = Prompts.text(.common)
        #expect(common.contains("- Images: show_image (shows images in this chat).\n"))
        let lower = try #require(common.range(of: "# Images\n")).lowerBound
        let upper = try #require(common.range(of: "# Environments of a Go service")).lowerBound
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
        let documented = try #require(blocks.first { $0.text.hasPrefix("/hephaestus-skills:feedback\nThe lock icon disappears") })
        let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "Studio", projectID: "HEPH",
                                      section: .web, item: "https://github.com/")
        let text = Engine.feedbackMessage(
            comment: "  The lock icon disappears when I drag a locked tab to another position.\n", context: context, projectName: "Hephaestus V2",
            screenshotPath: "/Users/example/Developer/HephaestusV2/.hephaestus/chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301/1B4E28BA-2FA1-11D2-883F-0016D3CCA427-screenshot.png")
        #expect(text == documented.text)
        let bareContext = FeedbackContext(appVersion: "1.0.0", build: 0, deviceName: "Studio", mainDeviceName: "Studio")
        let bare = Engine.feedbackMessage(comment: " ", context: bareContext, projectName: nil, screenshotPath: "/s.png")
        #expect(bare == "/hephaestus-skills:feedback\n(no comment)\n\nFeedback context:\n- App: HephaestusV2 v1.0.0(0)\n- Device: Studio\n- Screenshot: /s.png")
        // Feedback sent without a screenshot has no Screenshot line.
        let withoutScreenshot = Engine.feedbackMessage(comment: "Hello", context: bareContext, projectName: nil, screenshotPath: nil)
        #expect(withoutScreenshot == "/hephaestus-skills:feedback\nHello\n\nFeedback context:\n- App: HephaestusV2 v1.0.0(0)\n- Device: Studio")
    }

    @Test("The Attachment lines of the example of docs/chats.md › Feedback message end the feedback message, one per added file in order")
    func feedbackMessageAttachments() throws {
        let blocks = MarkdownSource.fencedBlocks(in: try Repository.doc("chats.md"))
        let documented = try #require(blocks.first { $0.text.hasPrefix("- Screenshot: /Users/example/") })
        let paths = documented.lines.map { String($0.drop { $0 != "/" }) }
        #expect(documented.lines.map { String($0.prefix { $0 != "/" }) } == ["- Screenshot: ", "- Attachment: ", "- Attachment: "])
        let context = FeedbackContext(appVersion: "0.4.0", build: 57, deviceName: "MacBook", mainDeviceName: "Studio", projectID: "HEPH",
                                      section: .web, item: "https://github.com/")
        let text = Engine.feedbackMessage(comment: "The lock icon disappears.", context: context, projectName: "Hephaestus V2",
                                          screenshotPath: paths[0], attachmentPaths: Array(paths.dropFirst()))
        #expect(text.hasSuffix("\n- Item: https://github.com/\n" + documented.text))
        // Without an added file the message ends with the Screenshot line.
        let bare = Engine.feedbackMessage(comment: "The lock icon disappears.", context: context, projectName: "Hephaestus V2",
                                          screenshotPath: paths[0], attachmentPaths: [])
        #expect(bare.hasSuffix("\n- Item: https://github.com/\n" + documented.lines[0]))
        // Without a screenshot the Attachment lines follow the last context line.
        let filesOnly = Engine.feedbackMessage(comment: "The lock icon disappears.", context: context, projectName: "Hephaestus V2",
                                               screenshotPath: nil, attachmentPaths: Array(paths.dropFirst()))
        #expect(filesOnly.hasSuffix("\n- Item: https://github.com/\n" + documented.lines.dropFirst().joined(separator: "\n")))
        #expect(!filesOnly.contains("Screenshot:"))
    }

    @Test("The first messages of Implement, of an orchestrated ticket chat and of Implement All call the internal skills")
    func implementMessages() {
        #expect(Engine.implementTicketMessage(ticketID: "HEPH-12", bundleID: nil) == "/hephaestus-skills:implement-ticket HEPH-12")
        #expect(Engine.implementTicketMessage(ticketID: "HEPH-12", bundleID: "HEPH-B2") == "/hephaestus-skills:implement-ticket HEPH-12 HEPH-B2")
        #expect(Engine.implementBundleMessage(bundleID: "HEPH-B2") == "/hephaestus-skills:implement-bundle HEPH-B2")
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
