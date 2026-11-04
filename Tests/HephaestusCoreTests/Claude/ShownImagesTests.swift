import Foundation
import Testing
@testable import HephaestusCore

/// Shown images: the image rules of `chats.postImages`, the copy into the chat's attachment folder
/// and the `images` item (docs/chats.md › Shown images, docs/mcp.md › Image rules).
@Suite("Shown images")
struct ShownImagesTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("png body".utf8)
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("jpeg body".utf8)
    static let gif = Data("GIF87a".utf8) + Data([1, 2, 3])
    static let webp = Data("RIFF".utf8) + Data([0x10, 0, 0, 0]) + Data("WEBPVP8 ".utf8)

    static func post(_ bed: ChatTestBed, _ chatID: ChatID, _ paths: [String], caption: String? = nil,
                     actor: Actor? = nil) async throws -> [HephaestusCore.Attachment] {
        try await bed.engine.call(ChatsPostImages.self, .init(chatID: chatID, paths: paths, caption: caption),
                                  actor: actor ?? .claude(chatID: chatID.uuidString))
    }

    static func imagesItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [ImagesItem] {
        try await bed.transcript(chatID).compactMap { item -> ImagesItem? in
            if case .images(let shown) = item { return shown }
            return nil
        }
    }

    /// Writes a file in the folder `Renders` next to the project root, outside the project.
    static func render(_ bed: ChatTestBed, _ name: String, _ data: Data) throws -> String {
        let folder = bed.root.deletingLastPathComponent().appendingPathComponent("Renders", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    /// The files of the chat's attachment folder, its agents files aside.
    static func storedFiles(_ bed: ChatTestBed, _ chatID: ChatID) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bed.folder.chatAttachmentsFolder(chatID).path)) ?? []
        return names.filter { !$0.hasPrefix("agents") }
    }

    @Test("The image format comes from the file's signature: PNG, JPEG, GIF and WebP, nothing else")
    func signatures() {
        #expect(ChatAttachments.imageContentType(Self.png) == "image/png")
        #expect(ChatAttachments.imageContentType(Self.jpeg) == "image/jpeg")
        #expect(ChatAttachments.imageContentType(Self.gif) == "image/gif")
        #expect(ChatAttachments.imageContentType(Data("GIF89a;".utf8)) == "image/gif")
        #expect(ChatAttachments.imageContentType(Self.webp) == "image/webp")
        #expect(ChatAttachments.imageContentType(Data("RIFF\u{10}\0\0\0WAVEfmt ".utf8)) == nil)
        #expect(ChatAttachments.imageContentType(Data("RIFF".utf8)) == nil)
        #expect(ChatAttachments.imageContentType(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == nil)
        #expect(ChatAttachments.imageContentType(Data("Notes".utf8)) == nil)
        #expect(ChatAttachments.imageContentType(Data()) == nil)
    }

    @Test("show_image validation: the chat's own Claude, 1 to 10 readable PNG, JPEG, GIF or WebP files; a failure stores nothing")
    func validation() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Render the icon")
            #expect(await bed.waitForState(chat.id, .idle))
            func refusal(_ paths: [String], actor: Actor? = nil) async -> EngineError? {
                await engineError { try await Self.post(bed, chat.id, paths, caption: "Icon", actor: actor) }
            }
            let png = try Self.render(bed, "icon.png", Self.png)
            let text = try Self.render(bed, "notes.txt", Data("Notes".utf8))
            let fake = try Self.render(bed, "fake.png", Data("not an image".utf8))
            let missing = bed.root.deletingLastPathComponent().appendingPathComponent("Renders/missing.png").path
            let folder = bed.root.deletingLastPathComponent().appendingPathComponent("Renders").path

            let notOwn = EngineError(.forbidden, "Only the chat's own Claude can show images.")
            #expect(await refusal([png], actor: .claude(chatID: Actor.externalChatID)) == notOwn)
            #expect(await refusal([png], actor: .claude(chatID: UUID().uuidString)) == notOwn)
            #expect(await refusal([]) == EngineError(.invalid, "show_image needs 1 to 10 images."))
            #expect(await refusal(Array(repeating: png, count: 11)) == EngineError(.invalid, "show_image needs 1 to 10 images."))
            #expect(await refusal([png, missing]) == EngineError(.invalid, "\(missing) is not a readable file."))
            #expect(await refusal([folder]) == EngineError(.invalid, "\(folder) is not a readable file."))
            #expect(await refusal([png, text]) == EngineError(.invalid, "\(text) is not a PNG, JPEG, GIF or WebP image."))
            #expect(await refusal([fake]) == EngineError(.invalid, "\(fake) is not a PNG, JPEG, GIF or WebP image."))
            #expect(await engineError {
                try await bed.engine.call(ChatsPostImages.self, .init(chatID: UUID(), paths: [png]), actor: .system)
            }?.code == .notFound)

            // Nothing was stored and the transcript shows nothing new.
            #expect(try await Self.imagesItems(bed, chat.id).isEmpty)
            #expect(Self.storedFiles(bed, chat.id).isEmpty)

            // Ten images are accepted.
            #expect(try await Self.post(bed, chat.id, Array(repeating: png, count: 10)).count == 10)
        }
    }

    @Test("show_image copies the images into the chat and adds one images item; the copies outlive the source files")
    func copiesIntoTheChat() async throws {
        try await withChatEngine { bed in
            let chat = try await bed.createChat(message: "Render the icon")
            #expect(await bed.waitForState(chat.id, .idle))
            let preview = try Self.render(bed, "preview.png", Self.png)
            // The signature decides the format, whatever the extension.
            let photo = try Self.render(bed, "photo.png", Self.jpeg)
            try FileManager.default.createDirectory(at: bed.root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            try Self.gif.write(to: bed.root.appendingPathComponent("Assets/anim.gif"))
            let webp = try Self.render(bed, "sticker.webp", Self.webp)

            let stored = try await Self.post(bed, chat.id, [preview, photo, "Assets/anim.gif", webp, preview],
                                             caption: "  **Preview**\r\nof the icon  ")
            #expect(stored.map(\.name) == ["preview.png", "photo.png", "anim.gif", "sticker.webp", "preview.png"])
            #expect(stored.map(\.contentType) == ["image/png", "image/jpeg", "image/gif", "image/webp", "image/png"])
            #expect(stored.map(\.size) == [Self.png.count, Self.jpeg.count, Self.gif.count, Self.webp.count, Self.png.count])
            #expect(Set(stored.map(\.id)).count == 5)
            for attachment in stored {
                #expect(attachment.path == HephaestusCore.Attachment.chatPath(chatID: chat.id, id: attachment.id, name: attachment.name))
            }
            #expect(try Data(contentsOf: bed.folder.attachmentFile(path: stored[1].path)) == Self.jpeg)

            let item = try #require(try await Self.imagesItems(bed, chat.id).first)
            #expect(item.caption == "**Preview**\nof the icon")
            #expect(item.images == stored)
            #expect(UUID(uuidString: item.id)?.uuidString == item.id)
            let event = await bed.waitForItem(chat.id) { if case .images = $0 { return true } else { return false } }
            #expect(event == .images(item))
            #expect(await bed.state(chat.id) == .idle)

            // The source files are deleted; the transcript replayed from its file still shows the copies.
            for path in [preview, photo, webp] { try FileManager.default.removeItem(atPath: path) }
            try FileManager.default.removeItem(at: bed.root.appendingPathComponent("Assets"))
            #expect(try await Self.imagesItems(bed, chat.id) == [item])
            let read = try await bed.connection.call(AttachmentsRead.self, .init(projectID: "DEMO", path: stored[0].path))
            #expect(Data(base64Encoded: read.dataBase64) == Self.png)
            #expect(read.name == "preview.png" && read.contentType == "image/png")

            // An empty caption gives an item without caption; a stored chat file, named without its
            // UUID prefix, can be shown again.
            _ = try await Self.post(bed, chat.id, [".hephaestus/" + stored[2].path], caption: " \n ")
            let second = try #require(try await Self.imagesItems(bed, chat.id).last)
            #expect(second.caption == nil)
            #expect(second.images.map(\.name) == ["anim.gif"])
        }
    }

    @Test("show_image asks nothing: an implement chat with questionsBlocked and a chat with waiting questions accept it")
    func asksNothing() async throws {
        try await withChatEngine { bed in
            let png = try Self.render(bed, "icon.png", Self.png)
            try await bed.writeTicket(Ticket(id: "DEMO-1", title: "One", created: ISODate.now(), description: "Problem"))
            let implement = try await bed.connection.call(ChatsImplementTicket.self, .init(ticketID: "DEMO-1"))
            #expect(implement.questionsBlocked)
            #expect(await bed.waitForState(implement.id, .idle))
            #expect(try await Self.post(bed, implement.id, [png]).count == 1)

            let chat = try await bed.createChat(message: "Plan")
            #expect(await bed.waitForState(chat.id, .idle))
            let claude = Actor.claude(chatID: chat.id.uuidString)
            let question = Question(label: "A", question: "Which?", options: [QuestionOption(label: "x"), QuestionOption(label: "y")],
                                    recommended: "x")
            _ = try await bed.engine.call(ChatsPostQuestions.self, .init(chatID: chat.id, questions: [question]), actor: claude)
            #expect(try await Self.post(bed, chat.id, [png], caption: "While the questions wait").count == 1)
            #expect(try await Self.imagesItems(bed, chat.id).count == 1)
        }
    }
}
