import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Output mapping and › Fixture replays: the captures replayed through the
/// mapping with the cached models of `initialize-response.json` and the settings of the capture.
@Suite("Stream mapping")
struct StreamMapperTests {
    static let date = Date(timeIntervalSince1970: 1_793_500_000)
    static let captureSettings = ChatSettings(model: "haiku", effort: .low, permissionMode: .manual, ultracode: false)
    /// The model of every message of the captures.
    static let haiku = "claude-haiku-5-5"

    static func cachedModels() throws -> [ClaudeModel] {
        let response = try JSONDecoder().decode(JSONValue.self, from: FakeClaudeLauncher.fixture("initialize-response.json"))
        return try #require(ClaudeModel.parse(response.objectValue?["response"]?.objectValue?["response"]?.objectValue?["models"]))
    }

    static func mapper(settings: ChatSettings = captureSettings) throws -> StreamMapper {
        var mapper = StreamMapper(settings: settings, models: try cachedModels())
        mapper.now = { date }
        mapper.newID = { "ID" }
        return mapper
    }

    /// The outputs of every line of a fixture, by line number from 1.
    static func replay(_ name: String, mapper: inout StreamMapper) throws -> [(line: Int, outputs: [MapperOutput])] {
        let lines = JSONLines.lines(of: try FakeClaudeLauncher.fixture(name))
        return lines.enumerated().map { ($0.offset + 1, mapper.map($0.element)) }
    }

    static func items(_ outputs: [MapperOutput]) -> [ChatItem] {
        outputs.compactMap { output in
            switch output {
            case .item(let item): return item
            case .toolResult(let item, _): return .toolResult(item)
            case .permissionRequest(let item, _): return .permissionRequest(item)
            case .result(let item): return .result(item)
            default: return nil
            }
        }
    }

    static func deltas(_ outputs: [MapperOutput], itemID: String) -> (kinds: Set<ChatDeltaEvent.Payload.Kind>, text: String) {
        var kinds = Set<ChatDeltaEvent.Payload.Kind>()
        var text = ""
        for case .delta(let id, let kind, let append, _, _) in outputs where id == itemID {
            kinds.insert(kind)
            text += append
        }
        return (kinds, text)
    }

    @Test("stream-bash-allowed.jsonl gives the items of docs/chats.md › Fixture replays")
    func bashAllowed() throws {
        var mapper = try Self.mapper()
        let replay = try Self.replay("stream-bash-allowed.jsonl", mapper: &mapper)
        #expect(replay.count == 28)
        let all = replay.flatMap(\.outputs)
        let expected: [ChatItem] = [
            .system(SystemItem(id: "ID", created: Self.date, text: "Session started · Haiku 5.5 · effort low · Ask every time", level: .info)),
            .system(SystemItem(id: "ID", created: Self.date,
                               text: "MCP server hephaestus is missing: the HephaestusV2 tools are not available in this session.",
                               level: .warning)),
            .toolUse(ToolUseItem(id: "msg_011CgbN99ugMwKEYBQfCEoiP#0", created: Self.date, toolUseID: "toolu_01JGkKXVVCvtBiysD3rhiEXj",
                                 name: "Bash", server: nil, input: ["command": "echo probe-ok", "description": "Print probe-ok"],
                                 parentToolUseID: nil)),
            .toolResult(ToolResultItem(id: "toolu_01JGkKXVVCvtBiysD3rhiEXj#result", created: Self.date,
                                       toolUseID: "toolu_01JGkKXVVCvtBiysD3rhiEXj", text: "probe-ok", isError: false, images: [])),
            .assistant(AssistantItem(id: "msg_011CgbN9DUEEzm4yYRLnxmCV#0", created: Self.date, text: "done",
                                     messageID: "msg_011CgbN9DUEEzm4yYRLnxmCV", parentToolUseID: nil, model: Self.haiku, effort: .low)),
            .result(ResultItem(id: "ID", created: Self.date, durationMs: 3523, costUSD: 0.008435510000000002, isError: false, summary: nil)),
        ]
        #expect(Self.items(all) == expected)
        // Line 1: the two system items, the session start, then a CLI turn opens.
        #expect(Array(replay[0].outputs.suffix(2)) == [.sessionStarted, .cliTurnOpened])
        // Lines 5–11: tool input deltas.
        let toolInput = Self.deltas(all, itemID: "msg_011CgbN99ugMwKEYBQfCEoiP#0")
        #expect(toolInput.kinds == [.toolInput])
        #expect(toolInput.text == #"{"command": "echo probe-ok", "description": "Print probe-ok"}"#)
        // Line 22: the text delta.
        #expect(replay[21].outputs == [.delta(itemID: "msg_011CgbN9DUEEzm4yYRLnxmCV#0", kind: .text, text: "done", model: Self.haiku,
                                              effort: .low)])
        // Line 28 is the result that closes the CLI turn.
        #expect(replay[27].outputs.last.map { if case .result = $0 { return true } else { return false } } == true)
        // Line 16: the weekly window of the rate_limit_event is the plan usage.
        #expect(replay[15].outputs == [.planUsage(Self.fixturePlanUsage)])
        // Ignored lines are logged, stream events are not.
        let logged = all.compactMap { output -> String? in
            if case .ignored(let text) = output { return text }
            return nil
        }
        #expect(logged == ["ignored system/status", "ignored system/task_summary", "ignored system/status",
                           "ignored system/post_turn_summary"])
        for number in [3, 4, 13, 14, 15, 20, 21, 24, 25, 26] {
            #expect(replay[number - 1].outputs.isEmpty, "line \(number)")
        }
    }

    @Test("stream-write-denied.jsonl gives the items of docs/chats.md › Fixture replays")
    func writeDenied() throws {
        var mapper = try Self.mapper()
        let replay = try Self.replay("stream-write-denied.jsonl", mapper: &mapper)
        #expect(replay.count == 64)
        let all = replay.flatMap(\.outputs)
        let items = Self.items(all)
        #expect(items.count == 7)
        #expect(items[2] == .toolUse(ToolUseItem(id: "msg_011CgbNBFV5aXsWJCvNEg4AB#0", created: Self.date,
                                                 toolUseID: "toolu_01VpVbDDcFs6qjm4A1K1HkJW", name: "Write", server: nil,
                                                 input: ["file_path": "/tmp/example", "content": "hi"], parentToolUseID: nil)))
        let request = PermissionRequestItem(id: "perm-1967e0c0-4eab-4e9a-8c9e-67ec5e2cb4a0", created: Self.date,
                                            requestID: "1967e0c0-4eab-4e9a-8c9e-67ec5e2cb4a0", toolName: "Write",
                                            input: ["file_path": "/tmp/example", "content": "hi"],
                                            reason: "Path is outside allowed working directories", decision: nil, decidedBy: nil)
        #expect(items[3] == .permissionRequest(request))
        guard case .permissionRequest(_, let suggestions) = replay[25].outputs.first else {
            Issue.record("line 26 is not a permission request")
            return
        }
        #expect(suggestions?.arrayValue?.count == 2)
        #expect(items[4] == .toolResult(ToolResultItem(id: "toolu_01VpVbDDcFs6qjm4A1K1HkJW#result", created: Self.date,
                                                       toolUseID: "toolu_01VpVbDDcFs6qjm4A1K1HkJW", text: "User denied in probe",
                                                       isError: true, images: [])))
        #expect(items[5] == .assistant(AssistantItem(
            id: "msg_011CgbNBQVp7hM3Fkm45qGrN#1", created: Self.date,
            text: "Not done: the Write to `note.txt` was denied, so the file wasn't created. I tried the scratchpad directory. I can retry in the working directory if you want, or you can approve the scratchpad write.",
            messageID: "msg_011CgbNBQVp7hM3Fkm45qGrN", parentToolUseID: nil, model: Self.haiku, effort: .low)))
        #expect(items[6] == .result(ResultItem(id: "ID", created: Self.date, durationMs: 6775, costUSD: 0.00333187, isError: false, summary: nil)))
        // Lines 32–39: the thinking block streams empty text, so no delta; line 40 matches block 0.
        #expect(Self.deltas(all, itemID: "msg_011CgbNBQVp7hM3Fkm45qGrN#0").text.isEmpty)
        #expect(replay[39].outputs.isEmpty)
        let text = Self.deltas(all, itemID: "msg_011CgbNBQVp7hM3Fkm45qGrN#1")
        #expect(text.kinds == [.text])
        #expect(text.text.hasPrefix("Not done: the Write to"))
        // Line 29: the same plan usage as line 16 of stream-bash-allowed.jsonl.
        #expect(replay[28].outputs == [.planUsage(Self.fixturePlanUsage)])
    }

    /// The plan usage of the rate_limit_event lines of both captures.
    static let fixturePlanUsage = PlanUsage(utilization: 0.68, resetsAt: ISODate.date(from: "2026-11-01T20:00:00Z")!, status: "allowed",
                                            overageStatus: "rejected", overageDisabledReason: "out_of_credits", isUsingOverage: false,
                                            received: date)

    @Test("rate_limit_event: the seven_day window, the status and the overage fields; other windows are not read")
    func rateLimitEvent() throws {
        var mapper = try Self.mapper()
        func map(_ info: String) -> [MapperOutput] {
            mapper.map(Data(#"{"type":"rate_limit_event","rate_limit_info":\#(info),"uuid":"u","session_id":"s"}"#.utf8))
        }
        let full = #"{"status":"rejected","resetsAt":1793520000,"rateLimitType":"five_hour","utilization":1.2,"#
            + #""unifiedWindows":{"five_hour":{"utilization":1.2,"resetsAt":1793520000},"seven_day":{"utilization":1,"resetsAt":1793880000}},"#
            + #""overageStatus":"allowed_warning","overageDisabledReason":"org_level_disabled","isUsingOverage":true}"#
        #expect(map(full) == [.planUsage(PlanUsage(utilization: 1, resetsAt: Date(timeIntervalSince1970: 1_793_880_000), status: "rejected",
                                                   overageStatus: "allowed_warning", overageDisabledReason: "org_level_disabled",
                                                   isUsingOverage: true, received: Self.date))])
        // The overage fields are optional; a field of the wrong type or an empty string counts as absent.
        let bare = #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.25,"resetsAt":1793880000}},"#
            + #""overageStatus":"","isUsingOverage":"yes"}"#
        #expect(map(bare) == [.planUsage(PlanUsage(utilization: 0.25, resetsAt: Date(timeIntervalSince1970: 1_793_880_000),
                                                   status: "allowed", received: Self.date))])
        // Without the weekly window, its numbers or the status, the line is ignored and logged.
        for info in [#"{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":1793880000}}}"#,
                     #"{"status":"allowed","utilization":0.5,"resetsAt":1793880000}"#,
                     #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":"0.5","resetsAt":1793880000}}}"#,
                     #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":-0.1,"resetsAt":1793880000}}}"#,
                     #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.5}}}"#,
                     #"{"unifiedWindows":{"seven_day":{"utilization":0.5,"resetsAt":1793880000}}}"#] {
            #expect(map(info) == [.ignored("ignored rate_limit_event")], "\(info)")
        }
        #expect(mapper.map(Data(#"{"type":"rate_limit_event"}"#.utf8)) == [.ignored("ignored rate_limit_event")])
    }

    @Test("Session start item: model name rules, permission labels and Ultracode")
    func sessionStart() throws {
        let mapper = try Self.mapper(settings: ChatSettings(model: "opus", effort: .xhigh, permissionMode: .bypassPermissions, ultracode: true))
        // A resolved model gives the display name of the first entry other than `default`.
        #expect(mapper.modelName("claude-opus-5-5") == "Opus 5.5")
        // A value gives its display name; anything else is shown as is.
        #expect(mapper.modelName("fable") == "Fable 5.1")
        #expect(mapper.modelName("claude-unknown-9") == "claude-unknown-9")
        let line: [String: JSONValue] = ["model": "claude-opus-5-5", "permissionMode": "bypassPermissions"]
        #expect(mapper.sessionStartText(line) == "Session started · Opus 5.5 · effort xhigh · Allow all · Ultracode")
        for (mode, label) in [("default", "Ask every time"), ("acceptEdits", "Accept edits"), ("plan", "Plan only"), ("auto", "Auto"),
                              ("dontAsk", "Don't ask"), ("bypassPermissions", "Allow all")] {
            #expect(ControlLines.systemLineLabel(mode) == label)
        }
    }

    @Test("MCP check: missing, failed, needs-auth and disabled warn; connected does not")
    func mcpCheck() throws {
        let mapper = try Self.mapper()
        func warning(_ servers: JSONValue) -> String? { mapper.mcpWarning(["mcp_servers": servers]) }
        #expect(warning([]) == "MCP server hephaestus is missing: the HephaestusV2 tools are not available in this session.")
        #expect(warning([["name": "other", "status": "connected"]])?.contains("is missing") == true)
        for status in ["failed", "needs-auth", "disabled"] {
            #expect(warning([["name": "hephaestus", "status": .string(status)]])
                == "MCP server hephaestus is \(status): the HephaestusV2 tools are not available in this session.")
        }
        #expect(warning([["name": "hephaestus", "status": "connected"]]) == nil)
    }

    @Test("A later system/init only opens a CLI turn; system/status with permissionMode is reported")
    func systemLines() throws {
        var mapper = try Self.mapper()
        _ = mapper.map(Data(FakeClaudeLauncher.initLine().utf8))
        #expect(mapper.map(Data(FakeClaudeLauncher.initLine().utf8)) == [.cliTurnOpened])
        #expect(mapper.map(Data(#"{"type":"system","subtype":"status","permissionMode":"acceptEdits"}"#.utf8))
            == [.permissionModeReported("acceptEdits")])
        #expect(mapper.map(Data(#"{"type":"keep_alive"}"#.utf8)) == [.ignored("ignored keep_alive")])
        #expect(mapper.map(Data(#"{"type":"user","message":{"role":"user","content":"hi"}}"#.utf8)) == [.ignored("ignored user")])
        #expect(mapper.map(Data("not json".utf8)) == [.invalid("not a JSON object")])
    }

    @Test("MCP tool names split at the first __ after mcp__")
    func toolNames() {
        #expect(StreamMapper.splitToolName("mcp__hephaestus__create_ticket") == ("create_ticket", "hephaestus"))
        #expect(StreamMapper.splitToolName("mcp__a__b__c") == ("b__c", "a"))
        #expect(StreamMapper.splitToolName("Bash") == ("Bash", nil))
        #expect(StreamMapper.splitToolName("mcp__nothing") == ("mcp__nothing", nil))
    }

    @Test("Unstreamed blocks take the next index; sub-agent lines keep their parent")
    func assistantBlocks() throws {
        var mapper = try Self.mapper()
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"id":"msg_A","content":[{"type":"redacted_thinking"},{"type":"text","text":"one"},{"type":"tool_use","id":"toolu_x","name":"mcp__hephaestus__get_ticket","input":{"ticketID":"DEMO-1"}}]}}"#
        let items = Self.items(mapper.map(Data(line.utf8)))
        #expect(items == [
            .assistant(AssistantItem(id: "msg_A#1", created: Self.date, text: "one", messageID: "msg_A", parentToolUseID: "toolu_parent")),
            .toolUse(ToolUseItem(id: "msg_A#2", created: Self.date, toolUseID: "toolu_x", name: "get_ticket", server: "hephaestus",
                                 input: ["ticketID": "DEMO-1"], parentToolUseID: "toolu_parent")),
        ])
    }

    @Test("An assistant line gives its model and the chat's effort; a model without effort setting gives none")
    func assistantModelAndEffort() throws {
        var mapper = try Self.mapper(settings: ChatSettings(model: "opus", effort: .xhigh))
        func text(_ id: String, model: String?) -> String {
            let field = model.map { #""model":"\#($0)","# } ?? ""
            return #"{"type":"assistant","parent_tool_use_id":null,"message":{\#(field)"id":"\#(id)","content":[{"type":"text","text":"hi"}]}}"#
        }
        #expect(Self.items(mapper.map(Data(text("msg_O", model: "claude-opus-5-5").utf8))) == [
            .assistant(AssistantItem(id: "msg_O#0", created: Self.date, text: "hi", messageID: "msg_O", model: "claude-opus-5-5",
                                     effort: .xhigh)),
        ])
        // `supportedEffortLevels` is absent for this model in initialize-response.json.
        #expect(Self.items(mapper.map(Data(text("msg_H", model: "claude-haiku-4-5-20251001").utf8))) == [
            .assistant(AssistantItem(id: "msg_H#0", created: Self.date, text: "hi", messageID: "msg_H", model: "claude-haiku-4-5-20251001",
                                     effort: nil)),
        ])
        // A model without entry keeps the effort; a message without model has neither.
        #expect(Self.items(mapper.map(Data(text("msg_U", model: "claude-unknown-9").utf8))) == [
            .assistant(AssistantItem(id: "msg_U#0", created: Self.date, text: "hi", messageID: "msg_U", model: "claude-unknown-9",
                                     effort: .xhigh)),
        ])
        #expect(Self.items(mapper.map(Data(text("msg_N", model: nil).utf8))) == [
            .assistant(AssistantItem(id: "msg_N#0", created: Self.date, text: "hi", messageID: "msg_N")),
        ])
        #expect(mapper.modelName("claude-opus-5-5") == "Opus 5.5")
    }

    @Test("Text deltas carry the model of message_start and the current effort; finalization keeps them")
    func streamedModelAndEffort() throws {
        var mapper = try Self.mapper(settings: ChatSettings(model: "sonnet", effort: .high))
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_S","model":"claude-sonnet-5-5"}},"parent_tool_use_id":null}"#
        let block = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}"#
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Wor"}},"parent_tool_use_id":null}"#
        _ = mapper.map(Data(start.utf8))
        _ = mapper.map(Data(block.utf8))
        #expect(mapper.map(Data(delta.utf8)) == [.delta(itemID: "msg_S#0", kind: .text, text: "Wor", model: "claude-sonnet-5-5", effort: .high)])
        mapper.settings.effort = .max
        #expect(mapper.map(Data(delta.utf8)) == [.delta(itemID: "msg_S#0", kind: .text, text: "Wor", model: "claude-sonnet-5-5", effort: .max)])
        #expect(mapper.finalize() == [
            .assistant(AssistantItem(id: "msg_S#0", created: Self.date, text: "WorWor", messageID: "msg_S", model: "claude-sonnet-5-5",
                                     effort: .max)),
        ])
    }

    @Test("An add_comment call gives the model of its comment; else the model of the latest message")
    func commentModels() throws {
        var mapper = try Self.mapper()
        #expect(mapper.takeCommentModel(ticketID: "DEMO-1", text: "Done") == nil)
        let call = #"{"type":"assistant","parent_tool_use_id":"toolu_agent","message":{"model":"claude-haiku-5-5","id":"msg_C","content":[{"type":"tool_use","id":"toolu_c","name":"mcp__hephaestus__add_comment","input":{"ticketID":"demo-1","text":"Done"}}]}}"#
        let main = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_M","model":"claude-opus-5-5"}},"parent_tool_use_id":null}"#
        _ = mapper.map(Data(call.utf8))
        _ = mapper.map(Data(main.utf8))
        #expect(mapper.commentCalls == [StreamMapper.CommentCall(ticketID: "DEMO-1", text: "Done", model: "claude-haiku-5-5")])
        #expect(mapper.takeCommentModel(ticketID: "DEMO-1", text: "Other") == "claude-opus-5-5")
        #expect(mapper.takeCommentModel(ticketID: "demo-1", text: "Done") == "claude-haiku-5-5")
        #expect(mapper.commentCalls.isEmpty)
        #expect(mapper.takeCommentModel(ticketID: "DEMO-1", text: "Done") == "claude-opus-5-5")
        _ = mapper.map(Data(call.utf8))
        _ = mapper.map(Data(FakeClaudeLauncher.resultLine().utf8))
        #expect(mapper.commentCalls.isEmpty)
    }

    @Test("Finalization turns open text blocks into items and drops open tool calls")
    func finalization() throws {
        var mapper = try Self.mapper()
        let start = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_F"}},"parent_tool_use_id":null}"#
        _ = mapper.map(Data(start.utf8))
        // No api_message_id: the message id of the latest message_start is used.
        for line in [
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"Bash"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}},"parent_tool_use_id":null}"#,
        ] {
            _ = mapper.map(Data(line.utf8))
        }
        let outputs = mapper.map(Data(FakeClaudeLauncher.resultLine().utf8))
        let items = Self.items(outputs)
        #expect(items.first == .assistant(AssistantItem(id: "msg_F#0", created: Self.date, text: "partial", messageID: "msg_F")))
        #expect(items.count == 2)
        guard case .result = outputs.last else {
            Issue.record("no result")
            return
        }
        #expect(mapper.finalize().isEmpty)
    }

    @Test("Tool results: arrays, other blocks as JSON, images and errors")
    func toolResults() throws {
        let mapper = try Self.mapper()
        var copy = mapper
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":[{"type":"text","text":"a"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}},{"type":"text","text":"b"},{"type":"document","title":"x"}]},{"type":"tool_result","tool_use_id":"toolu_2"}]}}"#
        let outputs = copy.map(Data(line.utf8))
        #expect(outputs == [
            .toolResult(ToolResultItem(id: "toolu_1#result", created: Self.date, toolUseID: "toolu_1", text: "a\nb\n{\"title\":\"x\",\"type\":\"document\"}",
                                       isError: true), images: [ToolResultImage(mediaType: "image/png", base64: "iVBORw0KGgo=")]),
            .toolResult(ToolResultItem(id: "toolu_2#result", created: Self.date, toolUseID: "toolu_2", text: "", isError: false), images: []),
        ])
    }

    @Test("Results: summaries of errors; queued_turn_count is not used")
    func results() throws {
        var mapper = try Self.mapper()
        func result(_ json: String) -> (ResultItem, Bool)? {
            let outputs = mapper.map(Data(json.utf8))
            for case .result(let item) in outputs { return (item, outputs.count == 1) }
            return nil
        }
        #expect(result(#"{"type":"result","subtype":"success","is_error":true,"result":"API error","duration_ms":5}"#)?.0.summary == "API error")
        #expect(result(#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["e1","e2"],"duration_ms":5}"#)?.0.summary
            == "e1\ne2")
        #expect(result(#"{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":5}"#)?.0.summary == "error_max_turns")
        let plain = result(#"{"type":"result","subtype":"success","is_error":false,"result":"ok","duration_ms":7}"#)
        #expect(plain?.0.summary == nil)
        #expect(plain?.0.costUSD == nil)
        #expect(plain?.1 == true)
        #expect(result(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":7,"queued_turn_count":1}"#)?.0
            == ResultItem(id: "ID", created: Self.date, durationMs: 7, costUSD: nil, isError: false, summary: nil))
    }

    @Test("Turn tracking lines: every system/init opens a CLI turn, command_lifecycle reports a message")
    func turnLines() throws {
        var mapper = try Self.mapper()
        let first = mapper.map(Data(FakeClaudeLauncher.initLine().utf8))
        #expect(Array(first.suffix(2)) == [.sessionStarted, .cliTurnOpened])
        // A later system/init adds no item and is not logged as ignored.
        #expect(mapper.map(Data(FakeClaudeLauncher.initLine().utf8)) == [.cliTurnOpened])
        let lifecycle = #"{"type":"command_lifecycle","command_uuid":"7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B","state":"started","uuid":"1a63b051-eb56-4e4d-a9b2-7b8fff546781","session_id":"S"}"#
        #expect(mapper.map(Data(lifecycle.utf8)) == [.commandState(uuid: "7C3E1F0A-2B4D-4E6F-8A9B-0C1D2E3F4A5B", state: "started")])
        #expect(mapper.map(Data(#"{"type":"command_lifecycle","state":"started"}"#.utf8))
            == [.invalid("command_lifecycle without command_uuid or state")])
    }

    @Test("TurnTracker: the steps of docs/chats.md › Turn tracking")
    func turnTracker() {
        // The example of the docs: A, then B written during A's CLI turn.
        var turns = TurnTracker()
        func report(_ uuid: String, _ state: String) -> Bool { turns.commandState(uuid, state) }
        turns.written("A")
        #expect(turns.isWorking)
        #expect(!report("A", "queued"))
        #expect(!report("A", "started"))
        turns.cliTurnOpened()
        turns.written("B")
        #expect(!report("B", "queued"))
        turns.resultReceived()
        #expect(turns.isWorking)
        #expect(!turns.cliTurnOpen)
        #expect(!report("A", "completed"))
        #expect(!report("B", "started"))
        turns.cliTurnOpened()
        turns.resultReceived()
        #expect(!turns.isWorking)
        #expect(!report("B", "completed"))
        // Messages merged into one CLI turn are all finished by its result.
        turns.written("C")
        turns.written("D")
        _ = report("C", "started")
        _ = report("D", "started")
        turns.cliTurnOpened()
        turns.resultReceived()
        #expect(!turns.isWorking)
        // A message dropped by the CLI before it started finishes it.
        turns.written("E")
        _ = report("E", "queued")
        #expect(report("E", "cancelled"))
        #expect(!turns.isWorking)
        // Without command_lifecycle lines each result finishes the oldest message.
        turns.written("F")
        turns.written("G")
        turns.cliTurnOpened()
        turns.resultReceived()
        #expect(turns.outstanding.map(\.uuid) == ["G"])
        turns.cliTurnOpened()
        turns.resultReceived()
        #expect(!turns.isWorking)
        // A CLI turn the CLI starts on its own leaves a queued message outstanding.
        turns.written("H")
        _ = report("H", "queued")
        turns.cliTurnOpened()
        turns.resultReceived()
        #expect(turns.outstanding.map(\.uuid) == ["H"])
    }

    @Test("Control lines: unsupported requests, answers and cancellations; ANSI removed from reasons")
    func controlMessages() throws {
        var mapper = try Self.mapper()
        #expect(mapper.map(Data(#"{"type":"control_request","request_id":"r1","request":{"subtype":"hook_callback"}}"#.utf8))
            == [.unsupportedControlRequest(requestID: "r1", subtype: "hook_callback")])
        #expect(mapper.map(Data(#"{"type":"control_cancel_request","request_id":"r2"}"#.utf8)) == [.cancelRequest(requestID: "r2")])
        #expect(mapper.map(Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"hephaestus-3","error":"bad"}}"#.utf8))
            == [.controlResponse(requestID: "hephaestus-3", success: false, response: nil, error: "bad")])
        let request = #"{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"decision_reason":"\u001b[1mRule\u001b[0m says ask"}}"#
        guard case .permissionRequest(let item, _) = mapper.map(Data(request.utf8)).first else {
            Issue.record("no permission request")
            return
        }
        #expect(item.reason == "Rule says ask")
        #expect(item.id == "perm-r3")
    }

    @Test("Strings longer than 100,000 characters are cut, at any depth")
    func sizeLimits() {
        let long = String(repeating: "é", count: 100_005)
        #expect(StreamMapper.truncated(long) == String(repeating: "é", count: 100_000) + "… [truncated 5 characters]")
        let value: JSONValue = ["a": ["b": .string(long)], "c": [.string("short")]]
        guard case .object(let object) = StreamMapper.truncated(value),
              case .object(let inner)? = object["a"], case .string(let text)? = inner["b"]
        else {
            Issue.record("unexpected shape")
            return
        }
        #expect(text.hasSuffix("… [truncated 5 characters]"))
        #expect(object["c"] == [.string("short")])
        #expect(StreamMapper.truncated("short") == "short")
    }

    @Test("Lines are split at LF, CR removed, lines over the limit skipped")
    func lineSplitter() {
        var splitter = LineSplitter(maximumLength: 10)
        #expect(splitter.append(Data("ab\r\ncd".utf8)) == [.line(Data("ab".utf8))])
        #expect(splitter.append(Data("e\n0123456789ABC".utf8)) == [.line(Data("cde".utf8))])
        #expect(splitter.append(Data("DEF\nxy\n".utf8)) == [.tooLong(16), .line(Data("xy".utf8))])
        #expect(splitter.append(Data("tail".utf8)).isEmpty)
        #expect(splitter.finish() == .line(Data("tail".utf8)))
    }
}
