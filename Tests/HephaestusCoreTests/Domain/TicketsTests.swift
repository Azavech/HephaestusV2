import Foundation
import Testing
@testable import HephaestusCore

/// tickets.* through `LocalEngineConnection` and the claude actor (docs/engine-api.md › Tickets,
/// docs/tickets.md).
@Suite("Tickets")
struct TicketsTests {
    @Test("tickets.create allocates the number, writes the ticket and emits the events")
    func create() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let events = await DomainEventRecorder.make(h)
            let ticket = try await h.connection.call(TicketsCreate.self, .init(
                projectID: "heph", title: "  Show the build number ", description: "Line one\r\nLine two\rLine three"))
            #expect(ticket.id == "HEPH-1")
            #expect(ticket.title == "Show the build number")
            #expect(ticket.status == .todo && ticket.createdBy == .user)
            #expect(ticket.description == "Line one\nLine two\nLine three")
            #expect(ticket.created == ticket.updated)
            #expect(ticket.comments.isEmpty && ticket.attachments.isEmpty && ticket.chatIDs.isEmpty)
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["project.updated", "ticket.updated", "projects.changed"])
            #expect(try events.all[0].payload(ProjectUpdatedEvent.self).project.nextTicketNumber == 2)
            #expect(try events.all[1].payload(TicketUpdatedEvent.self) == ticket)
            #expect(try events.all[2].payload(ProjectsChangedEvent.self)[0].ticketCounts == TicketCounts(todo: 1))
            let folder = ProjectFolder(root: URL(fileURLWithPath: h.path("Heph")))
            #expect(try ProjectFileStore.readTicket(at: folder.ticketFile("HEPH-1"), projectID: "HEPH") == ticket)
            #expect(try await h.connection.call(TicketsGet.self, .init(ticketID: "heph-1")) == ticket)
        }
    }

    @Test("Numbers skip existing files, are never reused and list in number order")
    func numbering() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let ticketFolder = h.projects.appendingPathComponent("Heph/.hephaestus/ticket")
            try writeFile("not: [valid", to: ticketFolder.appendingPathComponent("HEPH-1.yml"))
            try writeFile(ticketYAML(id: "HEPH-2", title: "Merged"), to: ticketFolder.appendingPathComponent("HEPH-2.yml"))
            #expect(try await h.ticket("HEPH").id == "HEPH-3")
            let project = try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project
            #expect(project.nextTicketNumber == 4)
            for _ in 4...10 {
                try await h.ticket("HEPH")
            }
            _ = try await h.connection.call(TicketsDelete.self, .init(ticketID: "HEPH-10"))
            #expect(try await h.ticket("HEPH").id == "HEPH-11")
            let list = try await h.connection.call(TicketsList.self, .init(projectID: "HEPH"))
            #expect(list.map(\.id) == ["HEPH-3", "HEPH-4", "HEPH-5", "HEPH-6", "HEPH-7", "HEPH-8", "HEPH-9", "HEPH-11"])
        }
    }

    @Test("tickets.create and tickets.get refuse malformed and unknown ids and invalid values")
    func errors() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            func create(_ params: TicketsCreate.Params) async -> EngineError? {
                await engineError { try await h.connection.call(TicketsCreate.self, params) }
            }
            #expect(await create(.init(projectID: "NONE", description: "x")) == EngineError(.notFound, "Project NONE not found."))
            #expect(await create(.init(projectID: "HEPH", description: " \n ")) == EngineError(.invalid, "The description must not be empty."))
            #expect(await create(.init(projectID: "HEPH", title: String(repeating: "a", count: 201), description: "x"))
                == EngineError(.invalid, "Title must be 1 to 200 characters on one line."))
            #expect(await create(.init(projectID: "HEPH", title: "Two\nlines", description: "x"))?.code == .invalid)
            #expect(await engineError { try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH12")) }
                == EngineError(.invalid, "\"HEPH12\" is not a valid ticket id."))
            #expect(await engineError { try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH-9")) }
                == EngineError(.notFound, "Ticket HEPH-9 not found."))
            #expect(await engineError { try await h.connection.call(TicketsGet.self, .init(ticketID: "WEB-1")) }
                == EngineError(.notFound, "Ticket WEB-1 not found."))
            let project = try await h.connection.call(ProjectsGet.self, .init(projectID: "HEPH")).project
            #expect(project.nextTicketNumber == 1)
        }
    }

    @Test("A ticket file that never loaded fails tickets.get with internal")
    func unreadableTicket() async throws {
        try await withDomainEngine(prepare: { directory, projects in
            let root = projects.appendingPathComponent("Heph")
            try writeFile(projectYAML(id: "HEPH", name: "Hephaestus V2"), to: root.appendingPathComponent(".hephaestus/project.yml"))
            try writeFile("schema: 1\nid: HEPH-4\ncreated: 2026-10-30T15:00:00Z\n", to: root.appendingPathComponent(".hephaestus/ticket/HEPH-4.yml"))
            try writeFile(registryYAML([root.path]), to: directory.registryFile)
        }) { h in
            let error = await engineError { try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH-4")) }
            #expect(error?.code == .internal)
            #expect(error?.message.hasPrefix("Ticket file HEPH-4.yml cannot be read: ") == true)
            #expect(error?.message.contains("title") == true)
            let list = try await h.connection.call(TicketsList.self, .init(projectID: "HEPH"))
            #expect(list.isEmpty)
        }
    }

    @Test("Claude creates tickets without a title and with the description template")
    func claudeCreate() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let titled = await engineError {
                try await h.call(TicketsCreate.self, .init(projectID: "HEPH", title: "Mine", description: templateDescription), as: h.claude)
            }
            #expect(titled == EngineError(.forbidden, "Claude cannot set a ticket title; Haiku names the ticket."))
            let notTemplate = await engineError {
                try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: "Problem\nExpected\n"), as: h.claude)
            }
            #expect(notTemplate == EngineError(.invalid, "Description does not follow the ticket template: heading \"Current Behavior\" "
                + "is missing or out of order. Use the headings Problem, Current Behavior, Expected, Change, Testing, Docs in this order, "
                + "each alone on its line."))
            let ticket = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            #expect(ticket.createdBy == .claude && ticket.status == .todo)
            #expect(ticket.title == "Locked tabs close with Command-W.")
            // A user may write any description.
            let user = try await h.connection.call(TicketsCreate.self, .init(projectID: "HEPH", description: "# Heading\n\nJust text"))
            #expect(user.title == "Just text")
            let untitled = try await h.connection.call(TicketsCreate.self, .init(projectID: "HEPH", title: "  ", description: "## Only"))
            #expect(untitled.title == "Untitled Ticket")
        }
    }

    @Test("Haiku's title replaces the provisional title only while it is unchanged")
    func naming() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let ticket = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            let events = await DomainEventRecorder.make(h)
            await h.engine.startTicketNaming(ticket.id, provisional: ticket.title, description: ticket.description,
                                             namer: FixedTitleNamer(title: "Keep locked web tabs open"))
            await events.wait(for: TicketUpdatedEvent.name)
            let named = try events.all[0].payload(TicketUpdatedEvent.self)
            #expect(named.title == "Keep locked web tabs open")
            #expect(events.all[0].origin == .system)
            #expect(try await h.connection.call(TicketsGet.self, .init(ticketID: ticket.id)).title == "Keep locked web tabs open")

            // A title set meanwhile wins.
            let second = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            await h.engine.startTicketNaming(second.id, provisional: second.title, description: second.description,
                                             namer: FixedTitleNamer(title: "Too late", delay: .milliseconds(200)))
            _ = try await h.connection.call(TicketsUpdate.self, .init(ticketID: second.id, title: second.title))
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await h.connection.call(TicketsGet.self, .init(ticketID: second.id)).title == second.title)

            // A failed naming keeps the provisional title.
            let third = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: h.claude)
            await h.engine.startTicketNaming(third.id, provisional: third.title, description: third.description,
                                             namer: FixedTitleNamer(title: nil))
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await h.connection.call(TicketsGet.self, .init(ticketID: third.id)).title == third.title)
        }
    }

    @Test("A feedback chat is linked to the first ticket it creates")
    func feedbackLink() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let chatID = UUID()
            let meta = ChatMeta(id: chatID, title: "Feedback", kind: .feedback, created: ISODate.now(), projectID: "HEPH")
            await h.engine.testUpsertChat(meta)
            let chat = Actor.claude(chatID: chatID.uuidString)
            let events = await DomainEventRecorder.make(h)
            let first = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: chat)
            #expect(first.chatIDs == [chatID])
            #expect(await events.wait(for: ChatUpdatedEvent.name)
                == ["project.updated", "ticket.updated", "projects.changed", "chat.updated"])
            let updated = try events.all[3].payload(ChatUpdatedEvent.self)
            #expect(updated.ticketID == first.id && updated.projectID == "HEPH" && updated.state == .idle)
            let stored = try ProjectFileStore.readChatMeta(at: ProjectFolder(root: URL(fileURLWithPath: h.path("Heph"))).chatMetaFile(chatID),
                                                           projectID: "HEPH")
            #expect(stored.ticketID == first.id)
            let second = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription), as: chat)
            #expect(second.chatIDs.isEmpty)
        }
    }

    @Test("tickets.update changes the title and the description; Claude's description follows the template")
    func update() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let ticket = try await h.ticket("HEPH")
            let events = await DomainEventRecorder.make(h)
            let updated = try await h.connection.call(TicketsUpdate.self, .init(ticketID: "heph-1", title: " New title ", description: "New"))
            #expect(updated.title == "New title" && updated.description == "New")
            #expect(updated.updated >= ticket.updated)
            #expect(await events.wait(for: TicketUpdatedEvent.name) == ["ticket.updated"])
            events.clear()
            _ = try await h.connection.call(TicketsUpdate.self, .init(ticketID: "HEPH-1", title: "New title"))
            #expect(await events.settle().isEmpty)
            #expect(await engineError { try await h.connection.call(TicketsUpdate.self, .init(ticketID: "HEPH-1", title: "")) }
                == EngineError(.invalid, "Title must be 1 to 200 characters on one line."))
            #expect(await engineError { try await h.connection.call(TicketsUpdate.self, .init(ticketID: "HEPH-1", description: " ")) }
                == EngineError(.invalid, "The description must not be empty."))
            #expect(await engineError { try await h.call(TicketsUpdate.self, .init(ticketID: "HEPH-1", description: "Plain"), as: h.claude) }?
                .code == .invalid)
            _ = try await h.call(TicketsUpdate.self, .init(ticketID: "HEPH-1", title: "By Claude", description: templateDescription), as: h.claude)
            #expect(await engineError { try await h.connection.call(TicketsUpdate.self, .init(ticketID: "HEPH-2", title: "X")) }?.code == .notFound)
        }
    }

    @Test("Status rules: the user and Claude set any status; Claude never changes a done ticket")
    func status() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            let events = await DomainEventRecorder.make(h)
            let progress = try await h.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "in_progress"), as: h.claude)
            #expect(progress.status == .inProgress)
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["ticket.updated", "projects.changed"])
            #expect(try events.all[1].payload(ProjectsChangedEvent.self)[0].ticketCounts == TicketCounts(inProgress: 1))
            events.clear()
            _ = try await h.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "in_progress"), as: h.claude)
            #expect(await events.settle().isEmpty)
            let review = try await h.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "review"), as: h.claude)
            #expect(review.status == .review)
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["ticket.updated", "projects.changed"])
            #expect(try events.all[1].payload(ProjectsChangedEvent.self)[0].ticketCounts == TicketCounts(review: 1))
            #expect(try await h.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "in_progress"), as: h.claude).status == .inProgress)
            #expect(try await h.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "review"), as: h.claude).status == .review)
            #expect(try await h.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "done"), as: h.claude).status == .done)
            for status in ["todo", "in_progress", "review", "done"] {
                #expect(await engineError { try await h.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: status), as: h.claude) }
                    == EngineError(.forbidden, "HEPH-1 is done; only the user can change its status."))
            }
            #expect(try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "review")).status == .review)
            #expect(try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "done")).status == .done)
            #expect(try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "todo")).status == .todo)
            #expect(await engineError { try await h.connection.call(TicketsSetStatus.self, .init(ticketID: "HEPH-1", status: "In Progress")) }
                == EngineError(.invalid, "Unknown status \"In Progress\". Use todo, in_progress, review or done."))
        }
    }

    @Test("tickets.delete removes the id from the bundles and moves the files to the Trash")
    func delete() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            try await h.ticket("HEPH")
            let upload = AttachmentUpload(name: "log.txt", contentType: "", dataBase64: Data("log".utf8).base64EncodedString())
            _ = try await h.connection.call(TicketsAddAttachments.self, .init(ticketID: "HEPH-1", attachments: [upload]))
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Both", ticketIDs: ["HEPH-1", "HEPH-2"]))
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Other", ticketIDs: ["HEPH-2"]))
            let chatID = UUID()
            _ = try await h.engine.linkChat(chatID, toTicket: "HEPH-1", origin: .system)
            let events = await DomainEventRecorder.make(h)
            _ = try await h.connection.call(TicketsDelete.self, .init(ticketID: "HEPH-1"))
            #expect(await events.wait(for: ProjectsChangedEvent.name) == ["bundle.updated", "ticket.deleted", "projects.changed"])
            #expect(try events.all[0].payload(BundleUpdatedEvent.self).ticketIDs == ["HEPH-2"])
            #expect(try events.all[1].payload(TicketDeletedEvent.self) == .init(projectID: "HEPH", ticketID: "HEPH-1"))
            #expect(h.trashedNames() == ["HEPH-1", "HEPH-1.yml"])
            #expect(!FileManager.default.fileExists(atPath: h.path("Heph/.hephaestus/ticket/HEPH-1.yml")))
            #expect(await engineError { try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH-1")) }?.code == .notFound)
            #expect(try await h.connection.call(TicketsList.self, .init(projectID: "HEPH")).map(\.id) == ["HEPH-2"])
        }
    }

    @Test("A Trash that cannot be used fails tickets.delete with unavailable and keeps the bundle change")
    func deleteWithoutTrash() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            _ = try await h.connection.call(BundlesCreate.self, .init(projectID: "HEPH", title: "Bundle", ticketIDs: ["HEPH-1"]))
            await h.engine.useFileTrash(.unavailable)
            let error = await engineError { try await h.connection.call(TicketsDelete.self, .init(ticketID: "HEPH-1")) }
            #expect(error == EngineError(.unavailable, "\(h.path("Heph/.hephaestus/ticket/HEPH-1.yml")) cannot be moved to the Trash: the volume has no Trash."))
            #expect(try await h.connection.call(BundlesGet.self, .init(bundleID: "HEPH-B1")).ticketIDs.isEmpty)
            #expect(try await h.connection.call(TicketsGet.self, .init(ticketID: "HEPH-1")).id == "HEPH-1")
        }
    }

    @Test("Comments: add with text or attachments, edit, delete with their files")
    func comments() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            #expect(await engineError { try await h.connection.call(TicketsAddComment.self, .init(ticketID: "HEPH-1", text: "  ")) }
                == EngineError(.invalid, "A comment needs text or at least one attachment."))
            let events = await DomainEventRecorder.make(h)
            let withText = try await h.connection.call(TicketsAddComment.self, .init(ticketID: "HEPH-1", text: "First\r\nline"))
            let comment = try #require(withText.comments.first)
            #expect(comment.author == .user && comment.text == "First\nline" && comment.updated == nil)
            #expect(await events.wait(for: TicketUpdatedEvent.name) == ["ticket.updated"])
            let upload = AttachmentUpload(name: "shot.png", contentType: "", dataBase64: Data([1, 2, 3]).base64EncodedString())
            let withFile = try await h.connection.call(TicketsAddComment.self, .init(ticketID: "HEPH-1", text: "", attachments: [upload]))
            let fileComment = withFile.comments[1]
            #expect(fileComment.attachments.count == 1 && fileComment.attachments[0].contentType == "image/png")
            let byClaude = try await h.call(TicketsAddComment.self, .init(ticketID: "HEPH-1", text: "Done"), as: h.claude)
            #expect(byClaude.comments[2].author == .claude)

            let edited = try await h.connection.call(TicketsUpdateComment.self, .init(ticketID: "HEPH-1", commentID: comment.id, text: "Edited"))
            #expect(edited.comments[0].text == "Edited" && edited.comments[0].updated != nil)
            #expect(await engineError { try await h.connection.call(TicketsUpdateComment.self, .init(ticketID: "HEPH-1", commentID: comment.id, text: "")) }
                == EngineError(.invalid, "A comment needs text or at least one attachment."))
            _ = try await h.connection.call(TicketsUpdateComment.self, .init(ticketID: "HEPH-1", commentID: fileComment.id, text: ""))
            let missing = UUID()
            #expect(await engineError { try await h.connection.call(TicketsUpdateComment.self, .init(ticketID: "HEPH-1", commentID: missing, text: "x")) }
                == EngineError(.notFound, "Comment \(missing.uuidString) not found."))

            let deleted = try await h.connection.call(TicketsDeleteComment.self, .init(ticketID: "HEPH-1", commentID: fileComment.id))
            #expect(deleted.comments.map(\.id) == [comment.id, byClaude.comments[2].id])
            #expect(h.trashedNames() == [fileComment.attachments[0].path.components(separatedBy: "/").last!])
            #expect(await engineError { try await h.connection.call(TicketsDeleteComment.self, .init(ticketID: "HEPH-1", commentID: missing)) }?
                .code == .notFound)
        }
    }

    @Test("Ticket attachments are added by the user and removed one by one")
    func attachments() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            try await h.ticket("HEPH")
            #expect(await engineError { try await h.connection.call(TicketsAddAttachments.self, .init(ticketID: "HEPH-1", attachments: [])) }?
                .code == .invalid)
            #expect(await engineError {
                try await h.call(TicketsAddAttachments.self, .init(ticketID: "HEPH-1", attachments: []), as: h.claude)
            } == EngineError(.forbidden, "tickets.addAttachments is not available to claude."))
            let upload = AttachmentUpload(name: "a/b:c\u{1}.txt", contentType: "text/x-custom", dataBase64: Data("hello".utf8).base64EncodedString())
            let ticket = try await h.connection.call(TicketsAddAttachments.self, .init(ticketID: "HEPH-1", attachments: [upload]))
            let attachment = try #require(ticket.attachments.first)
            #expect(attachment.name == "a_b_c_.txt")
            #expect(attachment.contentType == "text/x-custom")
            #expect(attachment.size == 5)
            #expect(attachment.path == "attachments/HEPH-1/\(attachment.id.uuidString)-a_b_c_.txt")
            let file = h.projects.appendingPathComponent("Heph/.hephaestus").appendingPathComponent(attachment.path)
            #expect(try readFile(file) == "hello")

            let missing = UUID()
            #expect(await engineError { try await h.connection.call(TicketsRemoveAttachment.self, .init(ticketID: "HEPH-1", attachmentID: missing)) }
                == EngineError(.notFound, "Attachment \(missing.uuidString) not found."))
            let events = await DomainEventRecorder.make(h)
            let removed = try await h.call(TicketsRemoveAttachment.self, .init(ticketID: "HEPH-1", attachmentID: attachment.id), as: h.claude)
            #expect(removed.attachments.isEmpty)
            #expect(await events.wait(for: TicketUpdatedEvent.name) == ["ticket.updated"])
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(h.trashedNames() == [file.lastPathComponent])
        }
    }

    @Test("Uploads: base64, source paths of Claude, size limits and invalid uploads")
    func uploads() async throws {
        try await withDomainEngine { h in
            try await h.create("Heph", name: "Hephaestus V2", identifier: "HEPH")
            let root = h.projects.appendingPathComponent("Heph")
            try writeFile("build output", to: root.appendingPathComponent(".build/build.log"))
            let relative = AttachmentUpload(name: "build.log", contentType: "", sourcePath: ".build/build.log")
            let ticket = try await h.call(TicketsCreate.self, .init(projectID: "HEPH", description: templateDescription,
                                                                    attachments: [relative]), as: h.claude)
            #expect(ticket.attachments.map(\.name) == ["build.log"])
            #expect(ticket.attachments[0].size == 12)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/build.log").path))

            func comment(_ uploads: [AttachmentUpload]) async -> EngineError? {
                await engineError { try await h.call(TicketsAddComment.self, .init(ticketID: ticket.id, text: "x", attachments: uploads), as: h.claude) }
            }
            #expect(await comment([AttachmentUpload(name: "x", contentType: "", sourcePath: "missing.txt")])
                == EngineError(.invalid, "missing.txt is not a readable file."))
            #expect(await comment([AttachmentUpload(name: "x", contentType: "", sourcePath: root.path)])
                == EngineError(.invalid, "\(root.path) is not a readable file."))
            #expect(await comment([AttachmentUpload(name: "x", contentType: "")])?.code == .invalid)
            #expect(await comment([AttachmentUpload(name: "x", contentType: "", dataBase64: "AA==", sourcePath: "a")])?.code == .invalid)
            #expect(await comment([AttachmentUpload(name: "x", contentType: "", dataBase64: "not base64!")])?.code == .invalid)

            let big = h.folder.appendingPathComponent("big.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(AttachmentUploads.maximumSize + 1))
            try handle.close()
            #expect(await comment([AttachmentUpload(name: "big.bin", contentType: "", sourcePath: big.path)])
                == EngineError(.invalid, "big.bin is larger than 20 MB."))
            var halves: [AttachmentUpload] = []
            for index in 0..<2 {
                let half = h.folder.appendingPathComponent("half\(index).bin")
                FileManager.default.createFile(atPath: half.path, contents: nil)
                let handle = try FileHandle(forWritingTo: half)
                try handle.truncate(atOffset: UInt64(AttachmentUploads.maximumSize / 2 + 1))
                try handle.close()
                halves.append(AttachmentUpload(name: "half\(index).bin", contentType: "", sourcePath: half.path))
            }
            #expect(await comment(halves) == EngineError(.invalid, "The attachments of one request exceed 20 MB."))
            let ticketNow = try await h.connection.call(TicketsGet.self, .init(ticketID: ticket.id))
            #expect(ticketNow.comments.isEmpty)
        }
    }

    @Test("Stored attachment names are cleaned and shortened to 213 UTF-8 bytes")
    func storedNames() {
        let id = UUID()
        #expect(AtomicFile.temporaryNameOverhead == 42)
        #expect(AttachmentUploads.maximumStoredNameBytes == 213)
        #expect(AttachmentUploads.storedName("", id: id) == "file")
        #expect(AttachmentUploads.storedName("a:b/c\u{7F}d", id: id) == "a_b_c_d")
        // 1-, 2-, 3- and 4-byte UTF-8 characters: whole characters are removed before the extension.
        for character in ["x", "é", "€", "😀"] {
            let width = character.utf8.count
            let stored = AttachmentUploads.storedName(String(repeating: character, count: 200) + ".png", id: id)
            let fileName = "\(id.uuidString)-\(stored)"
            #expect(stored.hasSuffix(".png"))
            #expect(stored.dropLast(4).allSatisfy { String($0) == character })
            #expect(fileName.utf8.count <= 213)
            #expect(fileName.utf8.count > 213 - width)
            #expect(AtomicFile.temporaryName(for: fileName).utf8.count <= 255)
        }
        let noExtension = AttachmentUploads.storedName(String(repeating: "x", count: 300), id: id)
        #expect("\(id.uuidString)-\(noExtension)".utf8.count == 213)
        // A name that fits is kept.
        let fits = String(repeating: "x", count: 172) + ".png"
        #expect(AttachmentUploads.storedName(fits, id: id) == fits)
    }

    @Test("Attachments with the longest names of 1- to 4-byte characters are written")
    func longestNamesAreWritten() throws {
        try withTemporaryDirectory { folder in
            for character in ["x", "é", "€", "😀"] {
                let id = UUID()
                let upload = PreparedUpload(name: AttachmentUploads.storedName(String(repeating: character, count: 300) + ".txt", id: id),
                                            contentType: "text/plain", data: Data("hello".utf8), id: id)
                let attachments = try AttachmentUploads.store([upload], in: folder, pathPrefix: "attachments/DEMO-1",
                                                              ownWrites: OwnWrites())
                let file = folder.appendingPathComponent("\(id.uuidString)-\(upload.name)")
                #expect(FileManager.default.contents(atPath: file.path) == Data("hello".utf8))
                #expect(attachments.first?.path == "attachments/DEMO-1/\(id.uuidString)-\(upload.name)")
            }
            // No temporary file is left.
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(names.count == 4)
            #expect(names.allSatisfy { !$0.hasPrefix(".") })
        }
    }
}
