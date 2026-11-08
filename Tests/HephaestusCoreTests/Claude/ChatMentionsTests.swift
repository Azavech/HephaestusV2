import Foundation
import Testing
@testable import HephaestusCore

/// docs/data-model.md › Mentioned ids and docs/tickets.md › Mentioned In tab: the ticket and bundle
/// ids that a chat's transcript mentions.
@Suite("Chat mentions")
struct ChatMentionsTests {
    static let date = ISODate.now()

    static func user(_ text: String, id: String = UUID().uuidString, linkedItems: [ChatLinkedItem] = []) -> ChatItem {
        .user(UserItem(id: id, created: date, text: text, sender: "MacBook", linkedItems: linkedItems))
    }

    static func assistant(_ text: String, id: String = UUID().uuidString, parent: String? = nil) -> ChatItem {
        .assistant(AssistantItem(id: id, created: date, text: text, messageID: "msg_1", parentToolUseID: parent))
    }

    @Test("User text, Claude's replies and linked tickets and bundles count; code blocks, links, tool calls, sub-agents and thinking do not")
    func items() {
        let items: [ChatItem] = [
            Self.user("Plan DEMO-1 and `DEMO-2`.\n\n```\nDEMO-90\n```"),
            Self.assistant("Created DEMO-3, see [DEMO-91](https://example.com/DEMO-91)."),
            Self.user("Look at this", linkedItems: [ChatLinkedItem(kind: .bundle, name: "DEMO-B4", text: "bundle DEMO-B4 “Polish”"),
                                                    ChatLinkedItem(kind: .ticket, name: "DEMO-5", text: "ticket DEMO-5 “Fix”"),
                                                    ChatLinkedItem(kind: .chat, name: "DEMO-92", text: "chat “DEMO-92”")]),
            Self.assistant("Sub-agent work on DEMO-93", parent: "toolu_1"),
            .thinking(ThinkingItem(id: UUID().uuidString, created: Self.date, text: "DEMO-94")),
            .toolUse(ToolUseItem(id: UUID().uuidString, created: Self.date, toolUseID: "toolu_2", name: "Bash",
                                 input: .object(["command": .string("echo DEMO-95")]))),
            .system(SystemItem(id: UUID().uuidString, created: Self.date, text: "DEMO-96", level: .info)),
        ]
        #expect(ChatMentions(items: items).ids == ["DEMO-1", "DEMO-2", "DEMO-3", "DEMO-5", "DEMO-B4"])
    }

    @Test("An item that replaces an item with the same id replaces its ids; the ids are sorted and listed once")
    func replacement() {
        var mentions = ChatMentions(items: [Self.user("DEMO-2 and DEMO-1", id: "a"), Self.assistant("DEMO-1 again", id: "b")])
        #expect(mentions.ids == ["DEMO-1", "DEMO-2"])
        let replaced = mentions.record(Self.user("Nothing", id: "a"))
        #expect(replaced)
        #expect(mentions.ids == ["DEMO-1"])
        let unchanged = mentions.record(Self.assistant("DEMO-1 still", id: "c"))
        #expect(!unchanged)
        var newer = ChatMentions()
        newer.record(Self.user("DEMO-7", id: "d"))
        let overlaid = mentions.overlay(newer)
        #expect(overlaid)
        #expect(mentions.ids == ["DEMO-1", "DEMO-7"])
    }

    @Test("The launch scan reads the mentions of existing transcripts and chats.list returns them")
    func launchScan() async throws {
        let chatID = UUID()
        let quiet = UUID()
        try await withChatEngine(prepare: { folder, _ in
            let writer = JSONLinesWriter()
            try ProjectFileStore.write(ChatMeta(id: chatID, kind: .project, created: ISODate.now(), closed: true), to: folder)
            for item in [Self.user("Plan DEMO-12"), Self.assistant("Created DEMO-B3 for it.")] {
                try writer.append(TranscriptLine(op: .add, item: item), to: folder.transcriptFile(chatID))
            }
            try ProjectFileStore.write(ChatMeta(id: quiet, kind: .project, created: ISODate.now()), to: folder)
            try writer.append(TranscriptLine(op: .add, item: Self.user("```\nDEMO-12\n```")), to: folder.transcriptFile(quiet))
        }) { bed in
            let deadline = ContinuousClock.now + waitLimit
            var chats = try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO"))
            while chats.first(where: { $0.id == chatID })?.mentionedIDs.isEmpty != false, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                chats = try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO"))
            }
            #expect(chats.first { $0.id == chatID }?.mentionedIDs == ["DEMO-12", "DEMO-B3"])
            #expect(chats.first { $0.id == quiet }?.mentionedIDs == [])
            #expect(try await bed.connection.call(ChatsGet.self, .init(chatID: chatID)).meta.mentionedIDs == ["DEMO-12", "DEMO-B3"])
        }
    }

    @Test("A new message and Claude's reply that mention ids emit chat.updated with the new mentionedIDs")
    func liveUpdate() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.replyingChat(reply: "I created DEMO-8.")
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(kind: .project, message: "Plan DEMO-7 please")
            let afterMessage = await bed.events.wait(for: "chat.updated") {
                (try? $0.payload(ChatUpdatedEvent.self)).map { $0.id == chat.id && $0.mentionedIDs == ["DEMO-7"] } == true
            }
            #expect(afterMessage != nil)
            let afterReply = await bed.events.wait(for: "chat.updated") {
                (try? $0.payload(ChatUpdatedEvent.self)).map { $0.id == chat.id && $0.mentionedIDs == ["DEMO-7", "DEMO-8"] } == true
            }
            #expect(afterReply != nil)
            #expect(await bed.waitForState(chat.id, .idle))
            let listed = try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO"))
            #expect(listed.first { $0.id == chat.id }?.mentionedIDs == ["DEMO-7", "DEMO-8"])
        }
    }

    @Test("mentionedIDs is a runtime key: never written to the chat file, always encoded in the API")
    func runtimeKey() throws {
        var meta = ChatMeta(id: UUID(), kind: .project, created: ISODate.now())
        meta.mentionedIDs = ["DEMO-1"]
        let yaml = try YAMLCoding.encode(meta)
        #expect(!yaml.contains("mentionedIDs"))
        let json = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ChatMeta.self, from: json)
        #expect(decoded.mentionedIDs == ["DEMO-1"])
        let fromYAML = try YAMLCoding.decode(ChatMeta.self, from: yaml + "mentionedIDs: [DEMO-2]\n")
        #expect(fromYAML.mentionedIDs == [])
    }
}
