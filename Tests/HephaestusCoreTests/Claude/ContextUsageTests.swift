import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Context usage, › Context indicator and docs/data-model.md › Context usage: the
/// `get_context_usage` answer, the numbers of the indicator, the token amounts, the stored value
/// and the requests the engine writes.
@Suite("Context usage")
struct ContextUsageTests {
    static let received = ISODate.date(from: "2026-10-31T13:02:10Z")!

    /// The success `response` of `context-usage-response.json`.
    static func fixtureResponse() throws -> JSONValue? {
        let line = try JSONDecoder().decode(JSONValue.self, from: FakeClaudeLauncher.fixture("context-usage-response.json"))
        return line.objectValue?["response"]?.objectValue?["response"]
    }

    /// The answer of `context-usage-response.json` to the request `requestLine`, with
    /// `totalTokens` replaced when `used` is given.
    static func answer(for requestLine: String, used: Int? = nil) throws -> String {
        let id = try #require(FakeClaudeLauncher.requestID(of: requestLine))
        guard case .object(var line) = try JSONDecoder().decode(JSONValue.self, from: FakeClaudeLauncher.fixture("context-usage-response.json")),
              case .object(var response)? = line["response"], case .object(var body)? = response["response"]
        else { throw FakeClaudeLauncher.SpawnError(description: "unexpected fixture") }
        if let used { body["totalTokens"] = .int(used) }
        response["response"] = .object(body)
        response["request_id"] = .string(id)
        line["response"] = .object(response)
        return ControlLines.json(.object(line))
    }

    static func usage(used: Int, window: Int = 1_000_000, buffer: Int = 33000) -> ContextUsage {
        ContextUsage(usedTokens: used, windowTokens: window, bufferTokens: buffer, received: received)
    }

    // MARK: Answer

    @Test("The captured answer of Claude Code 2.1.309 gives used 18554, window 1000000 and buffer 33000")
    func capturedAnswer() throws {
        let usage = try #require(ContextUsage.parse(try Self.fixtureResponse(), received: Self.received))
        #expect(usage == Self.usage(used: 18554))
        #expect(usage.leftTokens == 948_446)
        #expect(usage.percentLeft == 98)
        #expect(usage.tooltip == "18.6K of 1M tokens used · 948.4K left before compaction")
    }

    @Test("Without an autocompact_buffer category the buffer is 0")
    func noBuffer() {
        let response: JSONValue = .object(["totalTokens": .int(1200), "maxTokens": .int(200_000),
                                           "categories": .array([.object(["id": .string("free_space"), "tokens": .int(198_800)])])])
        #expect(ContextUsage.parse(response, received: Self.received) == Self.usage(used: 1200, window: 200_000, buffer: 0))
        #expect(ContextUsage.parse(.object(["totalTokens": .int(5), "maxTokens": .double(100)]), received: Self.received)
            == Self.usage(used: 5, window: 100, buffer: 0))
    }

    @Test("An answer whose numbers break the rules gives no value", arguments: [
        #"{}"#,
        #"{"totalTokens":10}"#,
        #"{"totalTokens":-1,"maxTokens":1000}"#,
        #"{"totalTokens":10,"maxTokens":0}"#,
        #"{"totalTokens":10.5,"maxTokens":1000}"#,
        #"{"totalTokens":"10","maxTokens":1000}"#,
        #"{"totalTokens":10,"maxTokens":1000,"categories":[{"id":"autocompact_buffer","tokens":1000}]}"#,
        #"{"totalTokens":10,"maxTokens":1000,"categories":[{"id":"autocompact_buffer","tokens":-5}]}"#,
        #"{"totalTokens":10,"maxTokens":1000,"categories":[{"id":"autocompact_buffer"}]}"#,
    ])
    func invalidAnswers(_ text: String) throws {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(ContextUsage.parse(response, received: Self.received) == nil)
        #expect(ContextUsage.parse(nil, received: Self.received) == nil)
    }

    // MARK: Numbers of the indicator

    @Test("left is window − buffer − used, at least 0, and <n> is its rounded percentage of window − buffer")
    func leftAndPercentage() {
        // window − buffer = 967000.
        #expect(Self.usage(used: 821_950).leftTokens == 145_050)
        #expect(Self.usage(used: 821_950).percentLeft == 15)
        #expect(Self.usage(used: 918_650).percentLeft == 5)
        #expect(Self.usage(used: 0).percentLeft == 100)
        #expect(Self.usage(used: 0).usedFraction == 0)
        // 19.6% left rounds to 20, 9.4% to 9.
        #expect(Self.usage(used: 967_000 - 189_532).percentLeft == 20)
        #expect(Self.usage(used: 967_000 - 90_898).percentLeft == 9)
        // Past the compaction point.
        let over = Self.usage(used: 990_000)
        #expect(over.leftTokens == 0)
        #expect(over.percentLeft == 0)
        #expect(over.usedFraction == 1)
        #expect(over.tooltip == "990K of 1M tokens used · 0 left before compaction")
        // A buffer that is not below the window gives no indicator.
        #expect(Self.usage(used: 10, window: 1000, buffer: 1000).percentLeft == nil)
        #expect(Self.usage(used: 10, window: 1000, buffer: 1000).usedFraction == nil)
    }

    @Test("Token amounts: whole below 1,000, K from 1,000, M from 1,000,000, one decimal at most, no trailing .0")
    func tokenAmounts() {
        let examples: [(Int, String)] = [
            (0, "0"), (850, "850"), (999, "999"), (1000, "1K"), (1049, "1K"), (1050, "1.1K"), (17_700, "17.7K"), (18554, "18.6K"),
            (120_000, "120K"), (948_446, "948.4K"), (1_000_000, "1M"), (1_500_000, "1.5M"), (1_049_999, "1M"), (2_250_000, "2.3M"),
        ]
        for (amount, text) in examples {
            #expect(ContextUsage.tokens(amount) == text, "\(amount)")
        }
    }

    // MARK: Chat metadata file

    @Test("contextUsage round-trips through the metadata file and is left out while nil")
    func metadataRoundTrip() throws {
        let created = ISODate.date(from: "2026-10-31T13:00:00Z")!
        var meta = ChatMeta(id: UUID(), title: "Plan the sprint", kind: .project, created: created)
        #expect(!(try YAMLCoding.encode(meta)).contains("contextUsage"))
        #expect(try YAMLCoding.decode(ChatMeta.self, from: try YAMLCoding.encode(meta)).contextUsage == nil)
        meta.contextUsage = Self.usage(used: 18554)
        let yaml = try YAMLCoding.encode(meta)
        #expect(yaml.hasSuffix("""
            closed: false
            contextUsage:
              usedTokens: 18554
              windowTokens: 1000000
              bufferTokens: 33000
              received: 2026-10-31T13:02:10Z

            """))
        #expect(try YAMLCoding.decode(ChatMeta.self, from: yaml) == meta)
        // The engine API carries it too.
        let json = try JSONEncoder().encode(meta)
        #expect(try JSONDecoder().decode(ChatMeta.self, from: json).contextUsage == meta.contextUsage)
    }

    // MARK: Requests

    /// The `get_context_usage` lines written to the process.
    static func requests(_ process: FakeClaudeProcess) -> [String] {
        process.writtenLines.filter { $0.contains(#""subtype":"get_context_usage""#) }
    }

    static func assistantLine(messageID: String, block: String = #"{"type":"text","text":"Hi"}"#, parent: String? = nil) -> String {
        let parentMember = parent.map { #""\#($0)""# } ?? "null"
        return #"{"type":"assistant","message":{"id":"\#(messageID)","model":"claude-haiku-5-5","content":[\#(block)]},"parent_tool_use_id":\#(parentMember)}"#
    }

    /// The `n`-th `get_context_usage` line, once written.
    static func request(_ process: FakeClaudeProcess, _ n: Int) async -> String? {
        let counter = Counter()
        return await process.line { line in
            line.contains(#""subtype":"get_context_usage""#) && counter.next() == n
        }
    }

    /// The chat's metadata as `chats.list` returns it.
    static func meta(_ bed: ChatTestBed, _ chatID: ChatID) async throws -> ChatMeta? {
        try await bed.connection.call(ChatsList.self, .init(projectID: "DEMO")).first { $0.id == chatID }
    }

    @Test("The first assistant line of each main message and each result ask; the answer is stored, written and reported")
    func requestsAndAnswer() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "hello")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            #expect((try await Self.meta(bed, chat.id))?.contextUsage == nil)
            process.emit(Self.assistantLine(messageID: "msg_1", block: #"{"type":"tool_use","id":"toolu_1","name":"Agent","input":{}}"#))
            let first = try #require(await Self.request(process, 1))
            #expect(first == #"{"type":"control_request","request_id":"\#(FakeClaudeLauncher.requestID(of: first)!)","request":{"subtype":"get_context_usage","detail":"summary"}}"#)
            process.emit(try Self.answer(for: first))
            let updated = await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == chat.id && $0.chatMeta?.contextUsage != nil }
            let usage = try #require(updated?.chatMeta?.contextUsage)
            #expect(usage.usedTokens == 18554)
            #expect(usage.windowTokens == 1_000_000)
            #expect(usage.bufferTokens == 33000)
            #expect(abs(usage.received.timeIntervalSinceNow) < 60)
            // Written to the metadata file.
            let stored = try YAMLCoding.decode(ChatMeta.self, from: String(contentsOf: bed.folder.chatMetaFile(chat.id), encoding: .utf8))
            #expect(stored.contextUsage == usage)

            // Another block of msg_1 and the lines of a sub-agent ask nothing; the result asks.
            process.emit(Self.assistantLine(messageID: "msg_1"))
            process.emit(Self.assistantLine(messageID: "msg_sub", parent: "toolu_1"))
            process.emit(FakeClaudeLauncher.resultLine())
            let second = try #require(await Self.request(process, 2))
            #expect(Self.requests(process).count == 2)
            process.emit(try Self.answer(for: second, used: 30000))
            #expect(await eventually(timeout: waitLimit) { (try? await Self.meta(bed, chat.id))?.contextUsage?.usedTokens == 30000 })
        }
    }

    @Test("At most one request is in flight; lines that ask meanwhile give one more request; a refused answer changes nothing")
    func oneInFlight() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "hello")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(Self.assistantLine(messageID: "msg_1"))
            let first = try #require(await Self.request(process, 1))
            process.emit(Self.assistantLine(messageID: "msg_2"))
            process.emit(Self.assistantLine(messageID: "msg_3", block: #"{"type":"text","text":"Three"}"#))
            _ = await bed.waitForItem(chat.id) { item in
                if case .assistant(let assistant) = item { return assistant.text == "Three" }
                return false
            }
            #expect(Self.requests(process).count == 1)
            process.emit(try Self.answer(for: first))
            let second = try #require(await Self.request(process, 2))
            #expect(await eventually(timeout: waitLimit) { (try? await Self.meta(bed, chat.id))?.contextUsage?.usedTokens == 18554 })

            // An error answer and an answer without numbers leave the value unchanged.
            let secondID = try #require(FakeClaudeLauncher.requestID(of: second))
            process.emit(#"{"type":"control_response","response":{"subtype":"error","request_id":"\#(secondID)","error":"not now"}}"#)
            process.emit(FakeClaudeLauncher.resultLine())
            let third = try #require(await Self.request(process, 3))
            process.emit(FakeClaudeLauncher.controlSuccess(try #require(FakeClaudeLauncher.requestID(of: third))))
            process.emit(Self.assistantLine(messageID: "msg_4"))
            let fourth = try #require(await Self.request(process, 4))
            #expect(Self.requests(process).count == 4)
            #expect((try await Self.meta(bed, chat.id))?.contextUsage?.usedTokens == 18554)
            process.emit(try Self.answer(for: fourth, used: 40000))
            #expect(await eventually(timeout: waitLimit) { (try? await Self.meta(bed, chat.id))?.contextUsage?.usedTokens == 40000 })
        }
    }
}
