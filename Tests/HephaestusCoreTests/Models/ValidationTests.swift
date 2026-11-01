import Foundation
import Testing
@testable import HephaestusCore

@Suite("Identifiers")
struct IdentifierTests {
    @Test("Project identifiers: ^[A-Z]{2,8}$")
    func projectIdentifiers() throws {
        for valid in ["HEPH", "AB", "ABCDEFGH"] { #expect(Identifiers.isProjectID(valid)) }
        for invalid in ["A", "ABCDEFGHI", "heph", "HE1", "HÉ", "HE PH", ""] { #expect(!Identifiers.isProjectID(invalid)) }
        #expect(Identifiers.normalizedProjectID("heph") == "HEPH")
        #expect(Identifiers.normalizedProjectID("h") == nil)
        #expect(throws: ValidationError.invalid("identifier", "use 2 to 8 letters A–Z")) { try ModelRules.projectIdentifier("H3") }
        #expect(try ModelRules.projectIdentifier("heph") == "HEPH")
        #expect(ValidationError.invalid("identifier", "use 2 to 8 letters A–Z").message == "identifier: use 2 to 8 letters A–Z.")
    }

    @Test("Ticket ids: ^[A-Z]{2,8}-[1-9][0-9]*$")
    func ticketIDs() throws {
        for valid in ["HEPH-12", "AB-1", "ABCDEFGH-1000"] { #expect(Identifiers.isTicketID(valid)) }
        for invalid in ["HEPH-0", "HEPH-012", "heph-12", "HEPH12", "HEPH-B2", "H-1", "HEPH-", "HEPH-1a", "HEPH--1"] {
            #expect(!Identifiers.isTicketID(invalid))
        }
        #expect(Identifiers.parseTicketID("HEPH-12")! == ("HEPH", 12))
        #expect(Identifiers.normalizedTicketID("heph-12") == "HEPH-12")
        #expect(Identifiers.ticketID(project: "HEPH", number: 12) == "HEPH-12")
        #expect(throws: ValidationError(field: "ticketID", message: "\"x\" is not a valid ticket id.")) { try ModelRules.ticketID("x") }
    }

    @Test("Bundle ids: ^[A-Z]{2,8}-B[1-9][0-9]*$")
    func bundleIDs() throws {
        for valid in ["HEPH-B2", "AB-B1"] { #expect(Identifiers.isBundleID(valid)) }
        for invalid in ["HEPH-2", "HEPH-B0", "HEPH-b2", "HEPH-B02", "HEPH-BB2"] { #expect(!Identifiers.isBundleID(invalid)) }
        #expect(Identifiers.parseBundleID("HEPH-B2")! == ("HEPH", 2))
        #expect(Identifiers.normalizedBundleID("heph-b2") == "HEPH-B2")
        #expect(Identifiers.bundleID(project: "HEPH", number: 2) == "HEPH-B2")
        #expect(Identifiers.projectID(of: "WEB-B7") == "WEB")
        #expect(throws: ValidationError(field: "bundleID", message: "\"x\" is not a valid bundle id.")) { try ModelRules.bundleID("x") }
    }

    @Test("Other ids of docs/data-model.md › Ids")
    func otherIDs() {
        #expect(Identifiers.isUUID("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        #expect(Identifiers.isUUID("3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
        #expect(!Identifiers.isUppercaseUUID("3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
        #expect(!Identifiers.isUUID("3F2504E0-4F89-11D3-9A0C-0305E82C330"))
        #expect(Identifiers.isSkillName("release-notes"))
        #expect(Identifiers.isSkillName(String(repeating: "a", count: 64)))
        for invalid in ["Release", "-a", "a-", "a--b", "my skill", ".git", String(repeating: "a", count: 65), ""] {
            #expect(!Identifiers.isSkillName(invalid))
        }
        #expect(Identifiers.isPairingCode("7K3M-Q9TX-2HVD-R4NP"))
        #expect(!Identifiers.isPairingCode("7K3M-Q9TX-2HVD-R4NI"))
        #expect(!Identifiers.isPairingCode("7K3MQ9TX2HVDR4NP"))
        #expect(Identifiers.isExternalToken("5e0c8f2a9b4d7e1f3a6c9b2d5e8f1a4c7b0d3e6f9a2c5b8d1e4f7a0c3b6d9e2f"))
        #expect(!Identifiers.isExternalToken(String(repeating: "A", count: 64)))
    }

    @Test("Generated secrets have their formats")
    func generatedSecrets() {
        for _ in 0..<20 {
            #expect(Identifiers.isPairingCode(RandomIDs.pairingCode()))
            #expect(Identifiers.isExternalToken(RandomIDs.externalToken()))
        }
        #expect(Identifiers.isUppercaseUUID(RandomIDs.uuidString()))
    }

    @Test("The identifier suggested from a name")
    func suggestion() {
        #expect(Identifiers.suggestedProjectID(fromName: "Hephaestus V2") == "HEPH")
        #expect(Identifiers.suggestedProjectID(fromName: "Go API") == "GOAP")
        #expect(Identifiers.suggestedProjectID(fromName: "Été") == "ETE")
        #expect(Identifiers.suggestedProjectID(fromName: "A1") == "")
    }
}

@Suite("Ticket template")
struct TicketTemplateTests {
    @Test("Heading lines of docs/tickets.md › Template validation", arguments: [
        ("Problem", "Problem"), ("## Problem", "Problem"), ("Current Behavior:", "Current Behavior"),
        ("### current behavior", "Current Behavior"), ("  Docs  ", "Docs"), ("#Expected:", "Expected"),
    ])
    func headingLines(_ line: String, _ heading: String) {
        #expect(TicketTemplate.headingIndex(of: line).map { TicketTemplate.headings[$0] } == heading)
    }

    @Test("Lines that are not heading lines", arguments: ["**Problem**", "Problem: tabs close", "1. Expected", "Current Behaviour", "Change::"])
    func notHeadingLines(_ line: String) {
        #expect(TicketTemplate.headingIndex(of: line) == nil)
    }

    @Test("The template itself and a filled description are valid")
    func validDescriptions() throws {
        try TicketTemplate.validate(TicketTemplate.text)
        let filled = "## Problem\r\nTabs close.\r\nCurrent Behavior:\rStep.\nExpected\nStay.\nchange\nDo it.\n# Docs\n- x\n"
        try TicketTemplate.validate(filled)
    }

    @Test("A heading missing or out of order fails with its message")
    func invalidDescriptions() {
        let message = TicketTemplate.validationMessage(missing: "Expected")
        #expect(message == "Description does not follow the ticket template: heading \"Expected\" is missing or out of order. "
            + "Use the headings Problem, Current Behavior, Expected, Change, Docs in this order, each alone on its line.")
        #expect(throws: ValidationError(field: "description", message: message)) {
            try TicketTemplate.validate("Problem\nCurrent Behavior\nChange\nDocs\n")
        }
        #expect(TicketTemplate.missingHeading(in: "Docs\nChange\nExpected\nCurrent Behavior\nProblem") == "Current Behavior")
        #expect(TicketTemplate.missingHeading(in: "") == "Problem")
    }

    @Test("The provisional title")
    func provisionalTitle() {
        #expect(TicketTemplate.provisionalTitle(for: "Problem\nA locked web tab can be closed.\n") == "A locked web tab can be closed.")
        #expect(TicketTemplate.provisionalTitle(for: "# Heading\n\n  **Bold** text  \n") == "**Bold** text")
        #expect(TicketTemplate.provisionalTitle(for: "Problem\n\nDocs\n") == "Untitled Ticket")
        let long = String(repeating: "x", count: 59) + " y"
        #expect(TicketTemplate.provisionalTitle(for: long) == String(repeating: "x", count: 59))
        #expect(TicketTemplate.provisionalBundleTitle(ticketTitles: ["A", "B"]) == "A, B")
    }
}

@Suite("Write rules")
struct WriteRuleTests {
    static let created = ISODate.date(from: "2026-10-31T12:00:00Z")!

    @Test("Titles and names")
    func titles() throws {
        #expect(try ModelRules.ticketTitle("  Title  ") == "Title")
        #expect(throws: ValidationError(field: "title", message: "Title must be 1 to 200 characters on one line.")) {
            try ModelRules.ticketTitle("two\nlines")
        }
        #expect(throws: ValidationError.self) { try ModelRules.ticketTitle(String(repeating: "x", count: 201)) }
        #expect(throws: ValidationError.self) { try ModelRules.ticketTitle("   ") }
        #expect(throws: ValidationError.self) { try ModelRules.chatTitle(String(repeating: "x", count: 101)) }
        #expect(throws: ValidationError.self) { try ModelRules.projectName("") }
        #expect(throws: ValidationError(field: "description", message: "The description must not be empty.")) {
            try ModelRules.ticketDescription(" \n ")
        }
        #expect(try ModelRules.ticketDescription("a\r\nb\rc") == "a\nb\nc")
    }

    @Test("Paths")
    func paths() {
        for valid in ["docs", "apps/ios", "a/b/c"] { #expect(ModelRules.isRelativePath(valid)) }
        for invalid in ["", "/docs", "docs/", "a//b", "./a", "a/../b", ".."] { #expect(!ModelRules.isRelativePath(invalid)) }
        for valid in ["/Users/example/Developer/HephaestusV2", "/"] { #expect(ModelRules.isAbsolutePath(valid)) }
        for invalid in ["relative", "/a/", "/a/./b", "/a/../b", "~/x"] { #expect(!ModelRules.isAbsolutePath(invalid)) }
        #expect(ModelRules.isAttachmentPath("attachments/HEPH-12/5F2B6A1C-3D4E-4F50-8A6B-7C8D9E0F1A2B-screenshot.png"))
        #expect(ModelRules.isAttachmentPath("chats/3F2504E0-4F89-11D3-9A0C-0305E82C3301/x.png"))
        #expect(!ModelRules.isAttachmentPath("attachments/HEPH-12/../x"))
        #expect(!ModelRules.isAttachmentPath("ticket/HEPH-12.yml"))
    }

    @Test("Project rules")
    func projectRules() throws {
        var project = Project(id: "HEPH", name: "Hephaestus V2", created: Self.created)
        try project.validate()
        project.subprojects = ["backend", "backend"]
        #expect(throws: ValidationError(field: "subprojects", message: "backend is listed more than once.")) { try project.validate() }
        project.subprojects = ["../outside"]
        #expect(throws: ValidationError.self) { try project.validate() }
        project.subprojects = []
        project.webTabs = [WebTab(id: UUID(), url: "ftp://example.com/")]
        #expect(throws: ValidationError.invalid("url", "use an absolute http or https URL")) { try project.validate() }
        project.webTabs = [WebTab(id: UUID(), url: "http://localhost:8080/")]
        try project.validate()
        project.skills = ["release-notes", "release-notes"]
        #expect(throws: ValidationError.self) { try project.validate() }
        project.skills = []
        project.chatDefaults = ChatSettings(model: "two words")
        #expect(throws: ValidationError.self) { try project.validate() }
        #expect(ProjectCommands(build: "  make build ", run: "   ", test: nil).normalized() == ProjectCommands(build: "make build"))
        #expect(ModelRules.normalizedWebTabTitle("a\nb") == "a b")
        #expect(ModelRules.normalizedWebTabTitle(String(repeating: "x", count: 600)).count == 500)
    }

    @Test("Ticket, comment and bundle rules")
    func ticketRules() throws {
        var ticket = Ticket(id: "HEPH-1", title: "T", created: Self.created)
        try ticket.validate()
        ticket.comments = [Comment(id: UUID(), author: .user, created: Self.created)]
        #expect(throws: ValidationError(field: "text", message: "A comment needs text or at least one attachment.")) { try ticket.validate() }
        let chat = UUID()
        ticket.comments = []
        ticket.chatIDs = [chat, chat]
        #expect(throws: ValidationError.self) { try ticket.validate() }

        var bundle = TicketBundle(id: "HEPH-B1", title: "B", created: Self.created, ticketIDs: ["HEPH-1", "HEPH-2"])
        try bundle.validate()
        bundle.ticketIDs = ["HEPH-1", "HEPH-1"]
        #expect(throws: ValidationError(field: "tickets", message: "HEPH-1 is listed more than once.")) { try bundle.validate() }
        bundle.ticketIDs = ["WEB-1"]
        #expect(throws: ValidationError(field: "tickets", message: "WEB-1 does not belong to project HEPH.")) { try bundle.validate() }
    }

    @Test("Attachment rules")
    func attachmentRules() throws {
        let id = UUID(uuidString: "5F2B6A1C-3D4E-4F50-8A6B-7C8D9E0F1A2B")!
        #expect(try ModelRules.attachmentName("screenshot.png", id: id) == "screenshot.png")
        #expect(throws: ValidationError.self) { try ModelRules.attachmentName("a/b.png", id: id) }
        #expect(throws: ValidationError.self) { try ModelRules.attachmentName(String(repeating: "x", count: 219), id: id) }
        #expect(try ModelRules.attachmentName(String(repeating: "x", count: 218), id: id).count == 218)
        #expect(Attachment.ticketPath(ticketID: "HEPH-12", id: id, name: "a.png") == "attachments/HEPH-12/5F2B6A1C-3D4E-4F50-8A6B-7C8D9E0F1A2B-a.png")
        #expect(Attachment.contentType(given: nil, name: "a.png") == "image/png")
        #expect(Attachment.contentType(given: "text/plain", name: "a.png") == "text/plain")
        #expect(Attachment.contentType(given: nil, name: "noextension") == "application/octet-stream")
    }

    @Test("Device, settings and remote rules")
    func deviceRules() throws {
        #expect(try ModelRules.deviceName("  ") == nil)
        #expect(try ModelRules.deviceName(" Studio ") == "Studio")
        #expect(throws: ValidationError.self) { try ModelRules.deviceName(String(repeating: "é", count: 32)) }
        var settings = HostSettings()
        try settings.validate(homeDirectory: "/Users/example")
        settings.syncPort = settings.mcpPort
        #expect(throws: ValidationError.self) { try settings.validate(homeDirectory: "/Users/example") }
        settings = HostSettings(mcpPort: 80)
        #expect(throws: ValidationError.self) { try settings.validate(homeDirectory: "/Users/example") }
        settings = HostSettings(updateCheckIntervalMinutes: 4)
        #expect(throws: ValidationError.self) { try settings.validate(homeDirectory: "/Users/example") }
        settings = HostSettings(skillsLibraryPath: "~/.claude/skills")
        #expect(throws: ValidationError.invalid("skillsLibraryPath", "use a folder that is not inside ~/.claude")) {
            try settings.validate(homeDirectory: "/Users/example")
        }
        settings = HostSettings(claudePath: "~/bin/claude", skillsLibraryPath: "~/Skills")
        try settings.validate(homeDirectory: "/Users/example")
        #expect(settings.resolvedClaudePath(homeDirectory: "/Users/example") == "/Users/example/bin/claude")
        let directory = DataDirectory(url: URL(fileURLWithPath: "/Users/example/Data"))
        #expect(settings.skillsLibraryURL(dataDirectory: directory, homeDirectory: "/Users/example").path == "/Users/example/Skills")
        #expect(HostSettings().skillsLibraryURL(dataDirectory: directory).path == "/Users/example/Data/Skills")
        #expect(throws: ValidationError.self) { try RemoteDevice(id: UUID(), name: "M", host: "[::1]", port: 47821).validate() }
        #expect(throws: ValidationError.self) { try RemoteDevice(id: UUID(), name: "M", host: "h", port: 0).validate() }
    }

    @Test("Question rules of docs/workflow.md › Validation, in order")
    func questionRules() throws {
        func question(_ label: String, _ options: [String], recommended: String? = nil, text: String = "Q?") -> Question {
            Question(label: label, question: text, options: options.map { QuestionOption(label: $0) }, recommended: recommended ?? options.first ?? "")
        }
        try ModelRules.questions([question("A", ["x", "y"]), question("B", ["x", "y"])])
        let cases: [([Question], String)] = [
            ([], "ask_questions needs 1 to 26 questions."),
            ([question("B", ["x", "y"])], "Question 1 must have the label \"A\"."),
            ([question("A", ["x", "y"], text: "  ")], "Question A has no text."),
            ([question("A", ["x"])], "Question A needs 2 to 10 options."),
            ([question("A", ["x", "X"])], "Question A has an empty or repeated option label."),
            ([question("A", ["x", " "])], "Question A has an empty or repeated option label."),
            ([question("A", ["x", String(repeating: "y", count: 201)])],
             "Question A has an option label longer than 200 characters or on several lines."),
            ([question("A", ["x", "y"], recommended: "z")], "Question A: the recommended answer must be one of its option labels."),
        ]
        for (questions, message) in cases {
            #expect(throws: ValidationError(field: "questions", message: message)) { try ModelRules.questions(questions) }
        }
    }
}
