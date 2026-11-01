import Foundation

/// The lines the engine writes to a Claude process's standard input: control requests, control
/// answers and user messages (docs/chats.md › Control protocol, › User messages, › Answer). Each
/// is one line of compact UTF-8 JSON ending with LF, with the keys in the order of the docs.
enum ControlLines {
    /// Request ids written by the engine: `hephaestus-<n>`, `<n>` counting from 1 per process.
    static func requestID(_ number: Int) -> String {
        "hephaestus-\(number)"
    }

    /// `{"type":"control_request","request_id":"<id>","request":{"subtype":"<subtype>"}}`.
    static func request(id: String, subtype: String) -> Data {
        line(#"{"type":"control_request","request_id":\#(string(id)),"request":{"subtype":\#(string(subtype))}}"#)
    }

    /// The `set_model` request.
    static func setModel(id: String, model: String) -> Data {
        line(#"{"type":"control_request","request_id":\#(string(id)),"request":{"subtype":"set_model","model":\#(string(model))}}"#)
    }

    /// The `set_permission_mode` request, with the CLI value of the mode.
    static func setPermissionMode(id: String, mode: String) -> Data {
        line(#"{"type":"control_request","request_id":\#(string(id)),"request":{"subtype":"set_permission_mode","mode":\#(string(mode))}}"#)
    }

    /// The `apply_flag_settings` request for the effort.
    static func applyEffort(id: String, effort: Effort) -> Data {
        line(#"{"type":"control_request","request_id":\#(string(id)),"request":{"subtype":"apply_flag_settings","settings":{"effortLevel":\#(string(effort.rawValue))}}}"#)
    }

    /// The `apply_flag_settings` request for Ultracode.
    static func applyUltracode(id: String, on: Bool) -> Data {
        line(#"{"type":"control_request","request_id":\#(string(id)),"request":{"subtype":"apply_flag_settings","settings":{"ultracode":\#(on)}}}"#)
    }

    /// The error answer to a control request of the CLI the engine does not support.
    static func unsupportedAnswer(requestID: String, subtype: String) -> Data {
        line(#"{"type":"control_response","response":{"subtype":"error","request_id":\#(string(requestID)),"error":\#(string("Unsupported control request: \(subtype)"))}}"#)
    }

    /// The answer to a `can_use_tool` request (docs/chats.md › Answer). `allowAlways` without
    /// suggestions writes the `allow` line.
    static func permissionAnswer(requestID: String, decision: PermissionDecision, input: JSONValue,
                                 suggestions: JSONValue?, message: String) -> Data {
        let response: String
        switch decision {
        case .allow:
            response = #"{"behavior":"allow","updatedInput":\#(json(input))}"#
        case .allowAlways:
            if let suggestions, let list = suggestions.arrayValue, !list.isEmpty {
                response = #"{"behavior":"allow","updatedInput":\#(json(input)),"updatedPermissions":\#(json(suggestions))}"#
            } else {
                response = #"{"behavior":"allow","updatedInput":\#(json(input))}"#
            }
        case .deny:
            response = #"{"behavior":"deny","message":\#(string(message))}"#
        }
        return line(#"{"type":"control_response","response":{"subtype":"success","request_id":\#(string(requestID)),"response":\#(response)}}"#)
    }

    /// An image block of a user message.
    struct Image: Sendable, Hashable {
        var mediaType: String
        var base64: String
    }

    /// A user message: the `text` block, left out when the text is empty, then the `image` blocks;
    /// `uuid` is the id under which the CLI reports the message (docs/chats.md › Turn tracking).
    static func userMessage(text: String, images: [Image], uuid: String) -> Data {
        var blocks: [String] = []
        if !text.isEmpty {
            blocks.append(#"{"type":"text","text":\#(string(text))}"#)
        }
        for image in images {
            blocks.append(#"{"type":"image","source":{"type":"base64","media_type":\#(string(image.mediaType)),"data":\#(string(image.base64))}}"#)
        }
        return line(#"{"type":"user","message":{"role":"user","content":[\#(blocks.joined(separator: ","))]},"uuid":\#(string(uuid))}"#)
    }

    // MARK: Encoding

    private static func line(_ text: String) -> Data {
        Data((text + "\n").utf8)
    }

    /// A JSON string literal.
    static func string(_ value: String) -> String {
        json(.string(value))
    }

    /// Compact JSON with sorted keys and unescaped slashes.
    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The CLI value of a permission mode for `set_permission_mode` and `init.permissionMode`:
    /// `default` for Ask Every Time (docs/chats.md › Permission mode).
    static func cliMode(_ mode: PermissionMode) -> String {
        mode == .manual ? "default" : mode.rawValue
    }

    /// The stored mode of a CLI value: `default` is `manual`; nil for an unknown value.
    static func storedMode(_ cliValue: String) -> PermissionMode? {
        cliValue == "default" ? .manual : PermissionMode(rawValue: cliValue)
    }

    /// The "System line" label of a CLI permission mode (docs/chats.md › Permission mode).
    static func systemLineLabel(_ cliValue: String) -> String {
        switch storedMode(cliValue) {
        case .manual: return "Ask every time"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan only"
        case .auto: return "Auto"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Allow all"
        // DOC-GAP: the table lists six modes; another value reported by the CLI is shown as is.
        case nil: return cliValue
        }
    }
}
