import Foundation

/// An image block of a `tool_result`, stored by the engine as `image-<n>.<extension>`.
struct ToolResultImage: Sendable, Hashable {
    var mediaType: String
    var base64: String
}

/// What one stdout line of a chat process asks the engine to do (docs/chats.md › Output mapping).
enum MapperOutput: Sendable, Hashable {
    /// A new item: appended to the transcript and emitted as `chat.item`.
    case item(ChatItem)
    /// A `toolResult` item whose images the engine stores first.
    case toolResult(ToolResultItem, images: [ToolResultImage])
    /// The first `system/init` of the process: `sessionStarted` is set and the state leaves
    /// starting. Its items come before, `cliTurnOpened` after.
    case sessionStarted
    /// A `system/init`: a CLI turn opens (docs/chats.md › Turn tracking).
    case cliTurnOpened
    /// A `command_lifecycle` line: the CLI's state of the user message `uuid`.
    case commandState(uuid: String, state: String)
    /// A `system/status` line with `permissionMode`: the CLI value.
    case permissionModeReported(String)
    /// Text appended to a streamed block.
    case delta(itemID: String, kind: ChatDeltaEvent.Payload.Kind, text: String)
    /// A `can_use_tool` request: its item, its input and `permission_suggestions`.
    case permissionRequest(PermissionRequestItem, suggestions: JSONValue?)
    /// A control request of another subtype: the engine answers with an error.
    case unsupportedControlRequest(requestID: String, subtype: String)
    /// An answer to a control request of the engine.
    case controlResponse(requestID: String, success: Bool, response: JSONValue?, error: String?)
    /// `control_cancel_request`.
    case cancelRequest(requestID: String)
    /// A `result` line: its item; the CLI turn closes. The items of the finalized blocks come
    /// before.
    case result(ResultItem)
    /// An ignored line to log in the chat's log file: `ignored <type>` or `ignored <type>/<subtype>`.
    case ignored(String)
    /// A line that is not a JSON object with a `type`: logged and skipped.
    case invalid(String)
}

/// The output mapping of docs/chats.md › Output mapping for one chat process: the open blocks of
/// the streamed messages, the assistant blocks, tool results, control messages and results.
struct StreamMapper {
    /// What the session start item needs: the chat's settings and the cached models.
    var settings: ChatSettings
    var models: [CachedModel]
    /// The creation time of new items (UTC with seconds).
    var now: () -> Date = { ISODate.now() }
    /// The id of new user, system and result items.
    var newID: () -> String = { RandomIDs.uuidString() }

    private(set) var sawInit = false

    /// A block of a message: opened by `content_block_start`, or recorded when an `assistant`
    /// line carries a block that was not streamed.
    private struct Block {
        var index: Int
        var type: String
        var text: String
        var parentToolUseID: String?
        /// True once the block's final item was emitted, or the block was matched by an
        /// `assistant` line without producing an item.
        var final: Bool
        /// True for a block opened by `content_block_start`.
        var open: Bool
    }

    /// Blocks per message id, and the message ids in the order they appeared.
    private var blocks: [String: [Block]] = [:]
    private var messageOrder: [String] = []
    /// The message id of the latest `message_start` per `parent_tool_use_id` (`""` for null).
    private var latestMessageID: [String: String] = [:]

    init(settings: ChatSettings, models: [CachedModel]) {
        self.settings = settings
        self.models = models
    }

    /// docs/chats.md › Size limits: 100,000 characters per string.
    static let maximumStringLength = 100_000

    // MARK: Lines

    mutating func map(_ data: Data) -> [MapperOutput] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let line = value.objectValue else {
            return [.invalid("not a JSON object")]
        }
        guard let type = line["type"]?.stringValue else {
            return [.invalid("no type")]
        }
        switch type {
        case "system": return mapSystem(line)
        case "stream_event": return mapStreamEvent(line)
        case "assistant": return mapAssistant(line)
        case "user": return mapUser(line)
        case "control_request": return mapControlRequest(line)
        case "control_response": return mapControlResponse(line)
        case "control_cancel_request":
            guard let id = line["request_id"]?.stringValue else { return [.invalid("control_cancel_request without request_id")] }
            return [.cancelRequest(requestID: id)]
        case "result": return mapResult(line)
        case "command_lifecycle":
            guard let uuid = line["command_uuid"]?.stringValue, let state = line["state"]?.stringValue else {
                return [.invalid("command_lifecycle without command_uuid or state")]
            }
            return [.commandState(uuid: uuid, state: state)]
        default: return [.ignored("ignored \(type)")]
        }
    }

    // MARK: system

    private mutating func mapSystem(_ line: [String: JSONValue]) -> [MapperOutput] {
        let subtype = line["subtype"]?.stringValue
        if subtype == "init" {
            guard !sawInit else { return [.cliTurnOpened] }
            sawInit = true
            var outputs: [MapperOutput] = [.item(.system(SystemItem(id: newID(), created: now(), text: sessionStartText(line), level: .info)))]
            if let warning = mcpWarning(line) {
                outputs.append(.item(.system(SystemItem(id: newID(), created: now(), text: warning, level: .warning))))
            }
            outputs.append(.sessionStarted)
            outputs.append(.cliTurnOpened)
            return outputs
        }
        if subtype == "status", let mode = line["permissionMode"]?.stringValue {
            return [.permissionModeReported(mode)]
        }
        return [.ignored(subtype.map { "ignored system/\($0)" } ?? "ignored system")]
    }

    /// docs/chats.md › Session start item.
    func sessionStartText(_ line: [String: JSONValue]) -> String {
        // DOC-GAP: docs/chats.md › Session start item does not cover a `system/init` without
        // `model` or `permissionMode`; the chat's settings name them then.
        let model = line["model"]?.stringValue ?? settings.model
        let mode = line["permissionMode"]?.stringValue ?? ControlLines.cliMode(settings.permissionMode)
        var text = "Session started · \(modelName(model)) · effort \(settings.effort.rawValue) · \(ControlLines.systemLineLabel(mode))"
        if settings.ultracode { text += " · Ultracode" }
        return text
    }

    /// The `displayName` of the first cached model whose value is not `default` and whose
    /// `resolvedModel` equals `model`; else of the model whose `value` equals it; else `model`.
    func modelName(_ model: String) -> String {
        if let match = models.first(where: { $0.model.value != "default" && $0.resolvedModel == model }) {
            return match.model.displayName
        }
        if let match = models.first(where: { $0.model.value == model }) {
            return match.model.displayName
        }
        return model
    }

    /// The MCP check of docs/chats.md › Session start item.
    func mcpWarning(_ line: [String: JSONValue]) -> String? {
        let servers = line["mcp_servers"]?.arrayValue ?? []
        let entry = servers.compactMap(\.objectValue).first { $0["name"]?.stringValue == "hephaestus" }
        let status: String
        if let entry {
            let value = entry["status"]?.stringValue ?? ""
            guard ["failed", "needs-auth", "disabled"].contains(value) else { return nil }
            status = value
        } else {
            status = "missing"
        }
        return "MCP server hephaestus is \(status): the HephaestusV2 tools are not available in this session."
    }

    // MARK: stream_event

    private mutating func mapStreamEvent(_ line: [String: JSONValue]) -> [MapperOutput] {
        guard let event = line["event"]?.objectValue, let eventType = event["type"]?.stringValue else { return [] }
        let parent = line["parent_tool_use_id"]?.stringValue
        let parentKey = parent ?? ""
        if eventType == "message_start" {
            if let id = event["message"]?.objectValue?["id"]?.stringValue {
                latestMessageID[parentKey] = id
            }
            return []
        }
        guard let messageID = line["api_message_id"]?.stringValue ?? latestMessageID[parentKey],
              let index = event["index"]?.claudeInt
        else { return [] }
        switch eventType {
        case "content_block_start":
            guard let blockType = event["content_block"]?.objectValue?["type"]?.stringValue else { return [] }
            openBlock(messageID: messageID, index: index, type: blockType, parent: parent)
            return []
        case "content_block_delta":
            guard let delta = event["delta"]?.objectValue, let deltaType = delta["type"]?.stringValue else { return [] }
            let kind: ChatDeltaEvent.Payload.Kind
            let text: String?
            switch deltaType {
            case "text_delta": kind = .text; text = delta["text"]?.stringValue
            case "thinking_delta": kind = .thinking; text = delta["thinking"]?.stringValue
            case "input_json_delta": kind = .toolInput; text = delta["partial_json"]?.stringValue
            default: return []
            }
            guard let text, !text.isEmpty,
                  let position = blocks[messageID]?.firstIndex(where: { $0.index == index && $0.open }),
                  blocks[messageID]?[position].final == false
            else { return [] }
            blocks[messageID]?[position].text += text
            return [.delta(itemID: StreamMapper.itemID(messageID, index), kind: kind, text: text)]
        default:
            return []
        }
    }

    private mutating func openBlock(messageID: String, index: Int, type: String, parent: String?) {
        if blocks[messageID] == nil {
            blocks[messageID] = []
            messageOrder.append(messageID)
        }
        let block = Block(index: index, type: type, text: "", parentToolUseID: parent, final: false, open: true)
        if let position = blocks[messageID]?.firstIndex(where: { $0.index == index }) {
            blocks[messageID]?[position] = block
        } else {
            blocks[messageID]?.append(block)
        }
    }

    static func itemID(_ messageID: String, _ index: Int) -> String {
        "\(messageID)#\(index)"
    }

    // MARK: assistant

    /// docs/chats.md › Assistant blocks.
    private mutating func mapAssistant(_ line: [String: JSONValue]) -> [MapperOutput] {
        guard let message = line["message"]?.objectValue, let messageID = message["id"]?.stringValue else { return [] }
        let parent = line["parent_tool_use_id"]?.stringValue
        var outputs: [MapperOutput] = []
        for content in message["content"]?.arrayValue ?? [] {
            guard let block = content.objectValue else { continue }
            let type = block["type"]?.stringValue ?? ""
            let index = claimBlock(messageID: messageID, type: type)
            let id = StreamMapper.itemID(messageID, index)
            switch type {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                outputs.append(.item(.assistant(AssistantItem(id: id, created: now(), text: text, messageID: messageID,
                                                              parentToolUseID: parent))))
            case "thinking":
                let text = block["thinking"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                outputs.append(.item(.thinking(ThinkingItem(id: id, created: now(), text: text, parentToolUseID: parent))))
            case "tool_use":
                let (name, server) = StreamMapper.splitToolName(block["name"]?.stringValue ?? "")
                outputs.append(.item(.toolUse(ToolUseItem(
                    id: id, created: now(), toolUseID: block["id"]?.stringValue ?? "", name: name, server: server,
                    input: StreamMapper.truncated(block["input"] ?? .object([:])), parentToolUseID: parent))))
            default:
                continue
            }
        }
        return outputs
    }

    /// The index of an `assistant` block: the first open block of the message with the same type
    /// and no final item yet, else the number of blocks already known (the block is then recorded).
    private mutating func claimBlock(messageID: String, type: String) -> Int {
        if blocks[messageID] == nil {
            blocks[messageID] = []
            messageOrder.append(messageID)
        }
        if let position = blocks[messageID]?.firstIndex(where: { $0.open && $0.type == type && !$0.final }) {
            blocks[messageID]?[position].final = true
            return blocks[messageID]![position].index
        }
        let index = blocks[messageID]!.count
        blocks[messageID]?.append(Block(index: index, type: type, text: "", parentToolUseID: nil, final: true, open: false))
        return index
    }

    /// docs/chats.md › Assistant blocks, name rule: `mcp__<server>__<tool>` gives the server and
    /// the tool's own name; any other name has no server.
    static func splitToolName(_ name: String) -> (name: String, server: String?) {
        let prefix = "mcp__"
        guard name.hasPrefix(prefix) else { return (name, nil) }
        let rest = name.dropFirst(prefix.count)
        guard let separator = rest.range(of: "__") else { return (name, nil) }
        return (String(rest[separator.upperBound...]), String(rest[..<separator.lowerBound]))
    }

    // MARK: Finalization

    /// docs/chats.md › Streaming, finalization: every open `text` or `thinking` block without a
    /// final item and with text becomes an item; open `tool_use` blocks are dropped; then the
    /// blocks are cleared.
    mutating func finalize() -> [ChatItem] {
        var items: [ChatItem] = []
        for messageID in messageOrder {
            for block in blocks[messageID] ?? [] where block.open && !block.final && !block.text.isEmpty {
                let id = StreamMapper.itemID(messageID, block.index)
                switch block.type {
                case "text":
                    items.append(.assistant(AssistantItem(id: id, created: now(), text: block.text, messageID: messageID,
                                                          parentToolUseID: block.parentToolUseID)))
                case "thinking":
                    items.append(.thinking(ThinkingItem(id: id, created: now(), text: block.text, parentToolUseID: block.parentToolUseID)))
                default:
                    break
                }
            }
        }
        blocks = [:]
        messageOrder = []
        latestMessageID = [:]
        return items
    }

    // MARK: user

    /// docs/chats.md › Tool results.
    private func mapUser(_ line: [String: JSONValue]) -> [MapperOutput] {
        guard let content = line["message"]?.objectValue?["content"]?.arrayValue else { return [.ignored("ignored user")] }
        let results = content.compactMap(\.objectValue).filter { $0["type"]?.stringValue == "tool_result" }
        guard !results.isEmpty else { return [.ignored("ignored user")] }
        return results.map { block in
            let toolUseID = block["tool_use_id"]?.stringValue ?? ""
            var images: [ToolResultImage] = []
            let text: String
            switch block["content"] {
            case .string(let value):
                text = value
            case .array(let parts):
                var texts: [String] = []
                var others: [String] = []
                for part in parts {
                    let object = part.objectValue
                    switch object?["type"]?.stringValue {
                    case "text":
                        texts.append(object?["text"]?.stringValue ?? "")
                    case "image":
                        // DOC-GAP: docs/chats.md › Tool results stores the base64 images; an image
                        // block with another source kind holds no data and is left out.
                        if let source = object?["source"]?.objectValue, source["type"]?.stringValue == "base64",
                           let data = source["data"]?.stringValue {
                            images.append(ToolResultImage(mediaType: source["media_type"]?.stringValue ?? "image/png", base64: data))
                        }
                    default:
                        others.append(ControlLines.json(part))
                    }
                }
                text = (texts + others).joined(separator: "\n")
            default:
                text = ""
            }
            let item = ToolResultItem(id: "\(toolUseID)#result", created: now(), toolUseID: toolUseID,
                                      text: StreamMapper.truncated(text), isError: block["is_error"]?.claudeBool ?? false)
            return .toolResult(item, images: images)
        }
    }

    // MARK: Control messages

    private func mapControlRequest(_ line: [String: JSONValue]) -> [MapperOutput] {
        guard let requestID = line["request_id"]?.stringValue, let request = line["request"]?.objectValue else {
            return [.invalid("control_request without request_id or request")]
        }
        let subtype = request["subtype"]?.stringValue ?? ""
        guard subtype == "can_use_tool" else {
            return [.unsupportedControlRequest(requestID: requestID, subtype: subtype)]
        }
        let item = PermissionRequestItem(
            id: "perm-\(requestID)", created: now(), requestID: requestID, toolName: request["tool_name"]?.stringValue ?? "",
            input: request["input"] ?? .object([:]), reason: request["decision_reason"]?.stringValue.map(StreamMapper.removingANSI))
        return [.permissionRequest(item, suggestions: request["permission_suggestions"])]
    }

    private func mapControlResponse(_ line: [String: JSONValue]) -> [MapperOutput] {
        guard let response = line["response"]?.objectValue, let requestID = response["request_id"]?.stringValue else {
            return [.invalid("control_response without request_id")]
        }
        let success = response["subtype"]?.stringValue == "success"
        return [.controlResponse(requestID: requestID, success: success, response: response["response"],
                                 error: response["error"]?.stringValue)]
    }

    // MARK: result

    /// docs/chats.md › Turn result.
    private mutating func mapResult(_ line: [String: JSONValue]) -> [MapperOutput] {
        var outputs = finalize().map(MapperOutput.item)
        let isError = line["is_error"]?.claudeBool ?? false
        var summary: String?
        if isError {
            let subtype = line["subtype"]?.stringValue
            if subtype == "success" {
                summary = line["result"]?.stringValue
            } else if let errors = line["errors"]?.arrayValue?.compactMap(\.stringValue), !errors.isEmpty {
                summary = errors.joined(separator: "\n")
            } else {
                summary = subtype
            }
        }
        let item = ResultItem(id: newID(), created: now(), durationMs: line["duration_ms"]?.claudeInt ?? 0,
                              costUSD: line["total_cost_usd"]?.claudeDouble, isError: isError, summary: summary)
        outputs.append(.result(item))
        return outputs
    }

    // MARK: Helpers

    /// docs/chats.md › Size limits: a string longer than 100,000 characters is cut to 100,000
    /// characters followed by `… [truncated <n> characters]`.
    static func truncated(_ text: String) -> String {
        let count = text.count
        guard count > maximumStringLength else { return text }
        return String(text.prefix(maximumStringLength)) + "… [truncated \(count - maximumStringLength) characters]"
    }

    /// The size limit applied to every string of a JSON value, at any depth.
    static func truncated(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(truncated(text))
        case .array(let values): return .array(values.map(truncated))
        case .object(let members): return .object(members.mapValues(truncated))
        default: return value
        }
    }

    /// The text without ANSI escape sequences (CSI, OSC and two-character sequences).
    static func removingANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let pattern = "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

extension JSONValue {
    /// The integer of an `int`, or of a `double` without fraction.
    var claudeInt: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value == value.rounded() && abs(value) < 9e15: return Int(value)
        default: return nil
        }
    }

    /// The number of an `int` or a `double`.
    var claudeDouble: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var claudeBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
