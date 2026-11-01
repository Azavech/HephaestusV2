import Foundation
import Testing
@testable import HephaestusCore

/// docs/chats.md › Output mapping and › Fixture replays: the captures replayed through the
/// mapping with the cached models of `initialize-response.json` and the settings of the capture.
@Suite("Stream mapping")
struct StreamMapperTests {
    static let date = Date(timeIntervalSince1970: 1_793_500_000)
    static let captureSettings = ChatSettings(model: "haiku", effort: .low, permissionMode: .manual, ultracode: false)

    static func cachedModels() throws -> [CachedModel] {
        let response = try JSONDecoder().decode(JSONValue.self, from: FakeClaudeLauncher.fixture("initialize-response.json"))
        return try #require(CachedModel.parse(response.objectValue?["response"]?.objectValue?["response"]?.objectValue?["models"]))
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
            case .result(let item, _): return .result(item)
            default: return nil
            }
        }
    }

    static func deltas(_ outputs: [MapperOutput], itemID: String) -> (kinds: Set<ChatDeltaEvent.Payload.Kind>, text: String) {
        var kinds = Set<ChatDeltaEvent.Payload.Kind>()
        var text = ""
        for case .delta(let id, let kind, let append) in outputs where id == itemID {
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
                                     messageID: "msg_011CgbN9DUEEzm4yYRLnxmCV", parentToolUseID: nil)),
            .result(ResultItem(id: "ID", created: Self.date, durationMs: 3523, costUSD: 0.008435510000000002, isError: false, summary: nil)),
        ]
        #expect(Self.items(all) == expected)
        // Line 1: the two system items, then the session start.
        #expect(replay[0].outputs.last == .sessionStarted)
        // Lines 5–11: tool input deltas.
        let toolInput = Self.deltas(all, itemID: "msg_011CgbN99ugMwKEYBQfCEoiP#0")
        #expect(toolInput.kinds == [.toolInput])
        #expect(toolInput.text == #"{"command": "echo probe-ok", "description": "Print probe-ok"}"#)
        // Line 22: the text delta.
        #expect(replay[21].outputs == [.delta(itemID: "msg_011CgbN9DUEEzm4yYRLnxmCV#0", kind: .text, text: "done")])
        // Line 28 ends the turn.
        #expect(replay[27].outputs.last.map { if case .result(_, let ends) = $0 { return ends } else { return false } } == true)
        // Ignored lines are logged, stream events are not.
        let logged = all.compactMap { output -> String? in
            if case .ignored(let text) = output { return text }
            return nil
        }
        #expect(logged == ["ignored system/status", "ignored rate_limit_event", "ignored system/task_summary", "ignored system/status",
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
            messageID: "msg_011CgbNBQVp7hM3Fkm45qGrN", parentToolUseID: nil)))
        #expect(items[6] == .result(ResultItem(id: "ID", created: Self.date, durationMs: 6775, costUSD: 0.00333187, isError: false, summary: nil)))
        // Lines 32–39: the thinking block streams empty text, so no delta; line 40 matches block 0.
        #expect(Self.deltas(all, itemID: "msg_011CgbNBQVp7hM3Fkm45qGrN#0").text.isEmpty)
        #expect(replay[39].outputs.isEmpty)
        let text = Self.deltas(all, itemID: "msg_011CgbNBQVp7hM3Fkm45qGrN#1")
        #expect(text.kinds == [.text])
        #expect(text.text.hasPrefix("Not done: the Write to"))
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

    @Test("A later system/init is ignored; system/status with permissionMode is reported")
    func systemLines() throws {
        var mapper = try Self.mapper()
        _ = mapper.map(Data(FakeClaudeLauncher.initLine().utf8))
        #expect(mapper.map(Data(FakeClaudeLauncher.initLine().utf8)) == [.ignored("ignored system/init")])
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
        let outputs = mapper.map(Data(FakeClaudeLauncher.resultLine(queued: 2).utf8))
        let items = Self.items(outputs)
        #expect(items.first == .assistant(AssistantItem(id: "msg_F#0", created: Self.date, text: "partial", messageID: "msg_F")))
        #expect(items.count == 2)
        guard case .result(_, let ends) = outputs.last else {
            Issue.record("no result")
            return
        }
        #expect(!ends)
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

    @Test("Results: summaries of errors and the queued turn count")
    func results() throws {
        var mapper = try Self.mapper()
        func result(_ json: String) -> (ResultItem, Bool)? {
            for case .result(let item, let ends) in mapper.map(Data(json.utf8)) { return (item, ends) }
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
        #expect(result(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":7,"queued_turn_count":1}"#)?.1 == false)
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
