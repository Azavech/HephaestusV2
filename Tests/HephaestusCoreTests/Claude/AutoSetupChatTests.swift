import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Auto Setup chats and › Chats without a project: the chat that `Auto Setup` starts
/// for an image with `chats.createSetup`, in the window's project or in no project, with a stand-in
/// Claude CLI.
@Suite("Auto Setup chats")
struct AutoSetupChatTests {
    static let imageID = UUID(uuidString: "5B8E7F60-3C1D-4A2B-9E8F-7A6B5C4D3E2F")!

    /// Writes an image of macOS 27.2.1 in Needs setup into the data directory.
    static func writeImage(_ data: DataDirectory) throws {
        try FileManager.default.createDirectory(at: data.vmImageFolder(imageID), withIntermediateDirectories: true)
        try VMImageStore.write(VMImage(id: imageID, version: "27.2.1", build: "26B131", state: .needsSetup,
                                       created: ISODate.date(from: "2026-11-10T20:00:00Z")!), to: data)
    }

    static func userItems(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> [UserItem] {
        try await bed.transcript(chatID).compactMap { item in
            if case .user(let user) = item { return user }
            return nil
        }
    }

    @Test("In a project: a chat of kind setup with the image, whose first message calls auto-setup, with the setup prompt alone, in the project root")
    func inProject() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher, prepare: { _, data in try Self.writeImage(data) }) { bed in
            let chat = try await bed.connection.call(ChatsCreateSetup.self, .init(imageID: Self.imageID, projectID: "DEMO"))
            #expect(chat.kind == .setup && chat.imageID == Self.imageID && chat.projectID == "DEMO")
            let file = try String(contentsOf: bed.folder.chatMetaFile(chat.id), encoding: .utf8)
            #expect(file.contains("\nkind: setup\nticket: null\nbundle: null\nimage: \(Self.imageID.uuidString)\n"))
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).map(\.id) == [chat.id])

            let first = try await Self.userItems(bed, chat.id).first
            #expect(first?.text == "/hephaestus-skills:auto-setup \(Self.imageID.uuidString)")

            let process = try #require(await launcher.chatProcess(0))
            let prompt = try #require(ChatWorktreeTests.systemPrompt(process))
            #expect(prompt.hasPrefix("You are Claude, working inside HephaestusV2, a macOS app that coordinates the work on many projects and "
                + "runs macOS virtual machines. The user talks to you in an Auto Setup chat, which sets up the image \(Self.imageID.uuidString) "
                + "of macOS 27.2.1 on the device "))
            #expect(!prompt.contains("{{") && !prompt.contains("# Never invent") && prompt.contains("vm_setup_finish"))
            #expect(process.request.currentDirectory == bed.root.path)
            let arguments = process.request.arguments
            let plugin = try #require(arguments.firstIndex(of: "--plugin-dir").map { arguments[$0 + 1] })
            #expect(plugin.hasSuffix("/Runtime/plugins/DEMO"))
        }
    }

    @Test("Without a project: stored with the image, run in its folder with the plugin of no project, in no project's list, deleted with the image")
    func withoutProject() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher, prepare: { _, data in try Self.writeImage(data) }) { bed in
            let chat = try await bed.connection.call(ChatsCreateSetup.self, .init(imageID: Self.imageID))
            #expect(chat.kind == .setup && chat.imageID == Self.imageID && chat.projectID.isEmpty)
            let imageFolder = bed.dataDirectory.vmImageFolder(Self.imageID)
            let stored = ProjectFolder(root: imageFolder)
            #expect(FileManager.default.fileExists(atPath: stored.chatMetaFile(chat.id).path))
            #expect(!FileManager.default.fileExists(atPath: bed.folder.chatMetaFile(chat.id).path))
            #expect(try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).isEmpty)
            #expect(try await bed.connection.call(ChatsGet.self, .init(chatID: chat.id)).meta.id == chat.id)

            let process = try #require(await launcher.chatProcess(0))
            #expect(process.request.currentDirectory == imageFolder.path)
            let prompt = try #require(ChatWorktreeTests.systemPrompt(process))
            #expect(prompt.contains("sets up the image \(Self.imageID.uuidString) of macOS 27.2.1"))
            let arguments = process.request.arguments
            let plugin = try #require(arguments.firstIndex(of: "--plugin-dir").map { arguments[$0 + 1] })
            #expect(plugin.hasSuffix("/Runtime/plugins/none"))
            #expect(FileManager.default.fileExists(atPath: plugin + "/hephaestus-skills/skills/auto-setup"))

            // A message reaches it by its id.
            try await bed.send(chat.id, "Go on")
            #expect(try await Self.userItems(bed, chat.id).map(\.text).last == "Go on")

            // Deleting the image deletes the chat with its folder.
            _ = try await bed.connection.call(VMImagesDelete.self, .init(imageID: Self.imageID))
            _ = await bed.events.wait(for: ChatDeletedEvent.name) { (try? $0.payload(ChatDeletedEvent.self).chatID) == chat.id }
            #expect(await engineError { try await bed.connection.call(ChatsGet.self, .init(chatID: chat.id)) }
                == EngineError.notFound("Chat", chat.id.uuidString))
            #expect(!FileManager.default.fileExists(atPath: imageFolder.path))
        }
    }

    @Test("A chat without a project is read from its image's folder at launch")
    func loadedAtLaunch() async throws {
        let chatID = UUID()
        try await withChatEngine(prepare: { _, data in
            try Self.writeImage(data)
            let meta = ChatMeta(id: chatID, title: "Set up macOS 27.2.1", kind: .setup, imageID: Self.imageID,
                                created: ISODate.date(from: "2026-11-10T20:00:00Z")!)
            try FileManager.default.createDirectory(at: ProjectFolder(root: data.vmImageFolder(Self.imageID)).chatsFolder,
                                                    withIntermediateDirectories: true)
            try ProjectFileStore.write(meta, to: ProjectFolder(root: data.vmImageFolder(Self.imageID)))
        }) { bed in
            let transcript = try await bed.connection.call(ChatsGet.self, .init(chatID: chatID))
            #expect(transcript.meta.title == "Set up macOS 27.2.1" && transcript.meta.projectID.isEmpty && transcript.meta.kind == .setup)
        }
    }

    @Test("The image and the project are checked; chats.create refuses the kind setup; a setup chat needs its image")
    func errors() async throws {
        try await withChatEngine(prepare: { _, data in try Self.writeImage(data) }) { bed in
            let missing = UUID()
            #expect(await engineError { try await bed.connection.call(ChatsCreateSetup.self, .init(imageID: missing)) }
                == EngineError.notFound("Image", missing.uuidString))
            #expect(await engineError { try await bed.connection.call(ChatsCreateSetup.self, .init(imageID: Self.imageID, projectID: "NOPE")) }
                == EngineError.notFound("Project", "NOPE"))
            #expect(await engineError { try await bed.connection.call(ChatsCreate.self, .init(projectID: "DEMO", kind: .setup)) }
                == EngineError.invalid("kind", "Auto Setup chats are created by chats.createSetup"))
            #expect(ChatMeta.kindProblem(kind: .setup, ticketID: nil, bundleID: nil) == "an Auto Setup chat needs its image")
            #expect(ChatMeta.kindProblem(kind: .project, ticketID: nil, bundleID: nil, imageID: Self.imageID) == "only an Auto Setup chat has an image")
        }
    }

    @Test("Auto Setup on a setup that already runs takes that setup and starts another chat")
    func setupThatRuns() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        let provisioner = FakeVMImageProvisioner(list: try ipswFixture())
        let toolsFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusCoreTests-tools-\(UUID().uuidString)", isDirectory: true)
        let tools = try makeGuestTools(in: toolsFolder)
        defer { try? FileManager.default.removeItem(at: toolsFolder) }
        try await withChatEngine(launcher: launcher, imageProvisioner: provisioner, guestTools: tools) { bed in
            let image = try await addInstalledImage(bed.connection)
            // `Manual Setup`, then `Auto Setup` twice, as the app does.
            let manual = try await bed.engine.beginImageSetup(image.id)
            let auto = try await bed.engine.beginImageSetup(image.id)
            #expect(auto === manual)
            let first = try await bed.connection.call(ChatsCreateSetup.self, .init(imageID: image.id, projectID: "DEMO"))
            #expect(try await bed.engine.beginImageSetup(image.id) === manual)
            let second = try await bed.connection.call(ChatsCreateSetup.self, .init(imageID: image.id, projectID: "DEMO"))
            #expect(first.id != second.id && first.imageID == image.id && second.imageID == image.id)
            #expect(await MainActor.run { provisioner.machines.count } == 1)
            await manual.stopNow()
        }
    }
}
