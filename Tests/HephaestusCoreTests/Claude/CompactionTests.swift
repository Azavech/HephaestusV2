import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Compaction and › Fixture replays: the `status` lines that start and end a
/// compaction, the chat's `compactingSince`, the compaction line of `compact_boundary`, and the
/// context usage asked after it.
@Suite("Compaction")
struct CompactionTests {
    static let date = StreamMapperTests.date
    static let compacting = #"{"type":"system","subtype":"status","status":"compacting"}"#
    static let compacted = #"{"type":"system","subtype":"status","status":null,"compact_result":"success"}"#

    static func line(_ mapper: inout StreamMapper, _ text: String) -> [MapperOutput] {
        mapper.map(Data(text.utf8))
    }

    static func boundary(trigger: String, preTokens: String) -> String {
        #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"\#(trigger)","pre_tokens":\#(preTokens)}}"#
    }

    static func compactionItem(_ text: String) -> MapperOutput {
        .item(.system(SystemItem(id: "ID", created: date, text: text, level: .info)))
    }

    // MARK: Mapping

    @Test("stream-compact.jsonl gives the items and compaction lines of docs/chats.md › Fixture replays")
    func capture() throws {
        var mapper = try StreamMapperTests.mapper(settings: BackgroundWorkTests.captureSettings)
        let replay = try StreamMapperTests.replay("stream-compact.jsonl", mapper: &mapper)
        #expect(replay.count == 22)
        let all = replay.flatMap(\.outputs)
        let expected: [ChatItem] = BackgroundWorkTests.sessionItems() + [
            .assistant(AssistantItem(id: "msg_011Cgqx8zzerPWTHHG8wtjRx#0", created: Self.date, text: "ok",
                                     messageID: "msg_011Cgqx8zzerPWTHHG8wtjRx", parentToolUseID: nil, model: StreamMapperTests.haiku,
                                     effort: .low)),
            .result(ResultItem(id: "ID", created: Self.date, durationMs: 1180, costUSD: 0.0027761500000000002, isError: false, summary: nil)),
            .system(SystemItem(id: "ID", created: Self.date, text: "Conversation compacted (manual, 24.6K tokens before)", level: .info)),
            .result(ResultItem(id: "ID", created: Self.date, durationMs: 3479, costUSD: 0.004669585, isError: false, summary: nil)),
        ]
        #expect(StreamMapperTests.items(all) == expected)
        #expect(StreamMapperTests.deltas(all, itemID: "msg_011Cgqx8zzerPWTHHG8wtjRx#0").text == "ok")
        #expect(replay[5].outputs.last == .mainMessage(messageID: "msg_011Cgqx8zzerPWTHHG8wtjRx"))
        let usage = PlanUsage(utilization: 0.97, resetsAt: ISODate.date(from: "2026-11-08T20:00:00Z")!, status: "allowed_warning",
                              overageStatus: "allowed", overageDisabledReason: nil, isUsingOverage: false, received: Self.date)
        #expect(replay[9].outputs == [.planUsage(usage)])
        #expect(replay[14].outputs == [.compactionStarted])
        #expect(replay[15].outputs == [.compactionEnded])
        #expect(replay[16].outputs == [.cliTurnOpened])
        #expect(replay[17].outputs == [Self.compactionItem("Conversation compacted (manual, 24.6K tokens before)"), .compacted])
        // The compaction has ended: the result of the /compact turn ends none.
        #expect(replay[20].outputs.count == 1)
        #expect(BackgroundWorkTests.logged(all) == ["ignored system/status", "ignored user", "ignored user"])
    }

    @Test("An automatic compact_boundary gives the automatic line; other triggers are shown as sent")
    func automaticBoundary() throws {
        var mapper = try StreamMapperTests.mapper()
        #expect(Self.line(&mapper, Self.boundary(trigger: "auto", preTokens: "967000"))
            == [Self.compactionItem("Conversation compacted (automatic, 967K tokens before)"), .compacted])
        #expect(Self.line(&mapper, Self.boundary(trigger: "auto", preTokens: "1500000.0"))
            == [Self.compactionItem("Conversation compacted (automatic, 1.5M tokens before)"), .compacted])
        #expect(Self.line(&mapper, Self.boundary(trigger: "manual", preTokens: "850"))
            == [Self.compactionItem("Conversation compacted (manual, 850 tokens before)"), .compacted])
        #expect(Self.line(&mapper, Self.boundary(trigger: "memory", preTokens: "0"))
            == [Self.compactionItem("Conversation compacted (memory, 0 tokens before)"), .compacted])
    }

    @Test("A compact_boundary without a string trigger and a whole pre_tokens of 0 or more adds no line and is logged")
    func boundaryWithoutFields() throws {
        var mapper = try StreamMapperTests.mapper()
        let lines = [
            #"{"type":"system","subtype":"compact_boundary"}"#,
            #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"pre_tokens":1000}}"#,
            Self.boundary(trigger: "auto", preTokens: "-1"),
            Self.boundary(trigger: "auto", preTokens: "12.5"),
            Self.boundary(trigger: "auto", preTokens: #""12""#),
        ]
        for line in lines {
            #expect(Self.line(&mapper, line) == [.ignored("ignored system/compact_boundary")], "\(line)")
        }
    }

    @Test("status compacting starts a compaction once; the next status line, or a result, ends it")
    func statusLines() throws {
        var mapper = try StreamMapperTests.mapper()
        #expect(Self.line(&mapper, #"{"type":"system","subtype":"status","status":"requesting"}"#) == [.ignored("ignored system/status")])
        #expect(Self.line(&mapper, Self.compacting) == [.compactionStarted])
        #expect(mapper.compacting)
        // Rule 1: a second `compacting` changes nothing.
        #expect(Self.line(&mapper, Self.compacting) == [.ignored("ignored system/status")])
        // Rule 2: any other status, null, missing or another value.
        #expect(Self.line(&mapper, #"{"type":"system","subtype":"status","status":"requesting"}"#) == [.compactionEnded])
        #expect(Self.line(&mapper, Self.compacted) == [.ignored("ignored system/status")])
        #expect(Self.line(&mapper, Self.compacting) == [.compactionStarted])
        #expect(Self.line(&mapper, #"{"type":"system","subtype":"status"}"#) == [.compactionEnded])
        // A status line with permissionMode does both.
        #expect(Self.line(&mapper, Self.compacting) == [.compactionStarted])
        #expect(Self.line(&mapper, #"{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits"}"#)
            == [.permissionModeReported("acceptEdits"), .compactionEnded])
        #expect(Self.line(&mapper, #"{"type":"system","subtype":"status","permissionMode":"default"}"#) == [.permissionModeReported("default")])
        // Rule 3: a result ends a compaction that still runs, before its item.
        #expect(Self.line(&mapper, Self.compacting) == [.compactionStarted])
        let outputs = Self.line(&mapper, FakeClaudeLauncher.resultLine())
        #expect(outputs.first == .compactionEnded)
        #expect(StreamMapperTests.items(outputs).count == 1)
        #expect(!mapper.compacting)
        #expect(StreamMapperTests.items(Self.line(&mapper, FakeClaudeLauncher.resultLine())).count == 1)
    }

    @Test("A compaction line is a system item with level info that starts with Conversation compacted (")
    func compactionLines() {
        func system(_ text: String, _ level: SystemLevel = .info) -> ChatItem {
            .system(SystemItem(id: "ID", created: Self.date, text: text, level: level))
        }
        #expect(CompactionLine.isCompactionLine(system(CompactionLine.text(trigger: "auto", preTokens: 967_000))))
        #expect(CompactionLine.isCompactionLine(system("Conversation compacted (manual, 24.6K tokens before)")))
        #expect(!CompactionLine.isCompactionLine(system("Conversation compacted (manual, 24.6K tokens before)", .warning)))
        #expect(!CompactionLine.isCompactionLine(system("Session started · Haiku 5.5 · effort low · Allow all")))
        #expect(!CompactionLine.isCompactionLine(.assistant(AssistantItem(id: "A", created: Self.date, text: "Conversation compacted (",
                                                                          messageID: "m", parentToolUseID: nil))))
    }

    // MARK: Engine

    /// Whether each `chat.updated` of the chat had `compactingSince`, from its first running
    /// state, without consecutive repeats.
    static func reported(_ bed: ChatTestBed, _ chatID: ChatID) async -> [Bool] {
        let metas = await bed.events.named("chat.updated").compactMap(\.chatMeta).filter { $0.id == chatID }
        var flags: [Bool] = []
        for meta in metas.drop(while: { $0.state != .running }) where flags.last != (meta.compactingSince != nil) {
            flags.append(meta.compactingSince != nil)
        }
        return flags
    }

    @Test("compactingSince is set by status compacting and cleared by the next status line; chat.updated reports both")
    func runtimeKey() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "/compact")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            #expect(await bed.waitForState(chat.id, .running))
            #expect(try await ContextUsageTests.meta(bed, chat.id)?.compactingSince == nil)
            process.emit(Self.compacting)
            let started = await bed.events.wait(for: "chat.updated") { $0.chatMeta?.id == chat.id && $0.chatMeta?.compactingSince != nil }
            let since = try #require(started?.chatMeta?.compactingSince)
            #expect(abs(since.timeIntervalSinceNow) < 60)
            #expect(started?.chatMeta?.state == .running)
            #expect(try await ContextUsageTests.meta(bed, chat.id)?.compactingSince == since)
            // Not persisted.
            let stored = try String(contentsOf: bed.folder.chatMetaFile(chat.id), encoding: .utf8)
            #expect(!stored.contains("compactingSince"))
            process.emit(Self.compacted)
            #expect(await eventually { await Self.reported(bed, chat.id) == [false, true, false] })
            #expect(try await ContextUsageTests.meta(bed, chat.id)?.compactingSince == nil)
            // The compaction line asks for the context usage.
            #expect(ContextUsageTests.requests(process).isEmpty)
            process.emit(Self.boundary(trigger: "manual", preTokens: "24644"))
            #expect(await ContextUsageTests.request(process, 1) != nil)
            #expect(try await bed.systemTexts(chat.id).last == "Conversation compacted (manual, 24.6K tokens before)")
        }
    }

    @Test("A compaction ends with the exit of the process")
    func exitEndsCompaction() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let chat = try await bed.createChat(message: "/compact")
            let process = try #require(await launcher.chatProcess())
            process.emit(FakeClaudeLauncher.initLine())
            process.emit(Self.compacting)
            #expect(await eventually { await Self.reported(bed, chat.id) == [false, true] })
            process.exit(.exited(1))
            #expect(await eventually { await Self.reported(bed, chat.id) == [false, true, false] })
            #expect(try await ContextUsageTests.meta(bed, chat.id)?.compactingSince == nil)
        }
    }

    @Test("stream-compact.jsonl through the engine: compactingSince from line 15 to line 16, then the compaction line")
    func captureThroughEngine() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let lines = JSONLines.lines(of: try FakeClaudeLauncher.fixture("stream-compact.jsonl")).map { String(decoding: $0, as: UTF8.self) }
            let chat = try await bed.createChat(settings: BackgroundWorkTests.captureSettings, message: "Reply with the single word ok.")
            let process = try #require(await launcher.chatProcess())
            _ = try #require(await ChatTurnTests.userLine(process, "Reply with the single word ok."))
            for line in lines[0..<12] { process.emit(line) }
            #expect(try await ChatTurnTests.waitForResults(bed, chat.id, 1))
            #expect(await bed.waitForState(chat.id, .idle))
            try await bed.send(chat.id, "/compact")
            _ = try #require(await ChatTurnTests.userLine(process, "/compact"))
            for line in lines[12...] { process.emit(line) }
            #expect(try await ChatTurnTests.waitForResults(bed, chat.id, 2))
            #expect(await bed.waitForState(chat.id, .idle))
            let metas = await bed.events.named("chat.updated").compactMap(\.chatMeta).filter { $0.id == chat.id }
            let during = metas.filter { $0.compactingSince != nil }
            #expect(!during.isEmpty)
            #expect(during.allSatisfy { $0.state == .running })
            // Running for the first turn, then running with and without the compaction for /compact.
            #expect(Self.reported(metas) == [false, true, false])
            let items = try await bed.transcript(chat.id)
            #expect(items.filter(CompactionLine.isCompactionLine).count == 1)
            guard case .system(let line) = items[items.count - 2], case .result(let result) = items[items.count - 1] else {
                Issue.record("the transcript does not end with the compaction line and the result")
                return
            }
            #expect(line.text == "Conversation compacted (manual, 24.6K tokens before)")
            #expect(result.durationMs == 3479)
        }
    }

    /// `reported` for metadata already read.
    static func reported(_ metas: [ChatMeta]) -> [Bool] {
        var flags: [Bool] = []
        for meta in metas where meta.state == .running && flags.last != (meta.compactingSince != nil) {
            flags.append(meta.compactingSince != nil)
        }
        return flags
    }
}
