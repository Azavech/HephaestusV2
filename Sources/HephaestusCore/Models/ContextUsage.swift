import Foundation

/// How much of the context window the conversation of a chat used when the engine last asked the
/// Claude CLI with `get_context_usage` (docs/data-model.md › Context usage, docs/chats.md ›
/// Context usage). Stored under `contextUsage` in the chat metadata file.
public struct ContextUsage: Codable, Sendable, Hashable {
    /// The tokens of the conversation, the CLI's `totalTokens`.
    public var usedTokens: Int
    /// The context window, the CLI's `maxTokens`.
    public var windowTokens: Int
    /// The autocompact buffer that Claude Code keeps free.
    public var bufferTokens: Int
    /// When the engine read the CLI's answer.
    public var received: Date

    public init(usedTokens: Int, windowTokens: Int, bufferTokens: Int, received: Date) {
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
        self.bufferTokens = bufferTokens
        self.received = received
    }

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        usedTokens = try c.required("usedTokens")
        windowTokens = try c.required("windowTokens")
        bufferTokens = try c.required("bufferTokens")
        received = try c.requiredDate("received")
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(usedTokens, "usedTokens")
        try c.encode(windowTokens, "windowTokens")
        try c.encode(bufferTokens, "bufferTokens")
        try c.encodeDate(received, "received")
    }

    /// The rules of the field table: `usedTokens` 0 or more, `windowTokens` above 0,
    /// `bufferTokens` from 0 to below `windowTokens`.
    public var isValid: Bool {
        usedTokens >= 0 && windowTokens > 0 && bufferTokens >= 0 && bufferTokens < windowTokens
    }

    /// The value of a success `response` of `get_context_usage` (docs/chats.md › Context usage):
    /// `totalTokens`, `maxTokens` and the `tokens` of the `autocompact_buffer` category, 0 without
    /// one. nil when the numbers break the rules.
    public static func parse(_ response: JSONValue?, received: Date) -> ContextUsage? {
        guard let object = response?.objectValue,
              let used = wholeNumber(object["totalTokens"]),
              let window = wholeNumber(object["maxTokens"])
        else { return nil }
        var buffer = 0
        if let category = object["categories"]?.arrayValue?.first(where: { $0.objectValue?["id"]?.stringValue == "autocompact_buffer" }) {
            guard let tokens = wholeNumber(category.objectValue?["tokens"]) else { return nil }
            buffer = tokens
        }
        let usage = ContextUsage(usedTokens: used, windowTokens: window, bufferTokens: buffer, received: received)
        return usage.isValid ? usage : nil
    }

    private static func wholeNumber(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let number):
            return number
        case .double(let number):
            guard number.isFinite, number.rounded() == number, abs(number) < 1e15 else { return nil }
            return Int(number)
        default:
            return nil
        }
    }

    // MARK: Context indicator (docs/chats.md › Context indicator)

    /// The tokens Claude Code compacts at: `windowTokens` − `bufferTokens`.
    public var compactionTokens: Int {
        windowTokens - bufferTokens
    }

    /// `left` = `window` − `buffer` − `used`, at least 0.
    public var leftTokens: Int {
        max(compactionTokens - usedTokens, 0)
    }

    /// `<n>`: `left` / (`window` − `buffer`) × 100, rounded to the nearest whole number; nil when
    /// `bufferTokens` is not below `windowTokens`.
    public var percentLeft: Int? {
        guard compactionTokens > 0 else { return nil }
        return Int((Double(leftTokens) / Double(compactionTokens) * 100).rounded())
    }

    /// The used part of `window` − `buffer`, 0 to 1, to which the ring is filled; nil when
    /// `bufferTokens` is not below `windowTokens`.
    public var usedFraction: Double? {
        guard compactionTokens > 0 else { return nil }
        return 1 - Double(leftTokens) / Double(compactionTokens)
    }

    /// The tooltip: `<used> of <window> tokens used · <left> left before compaction`.
    public var tooltip: String {
        "\(Self.tokens(usedTokens)) of \(Self.tokens(windowTokens)) tokens used · \(Self.tokens(leftTokens)) left before compaction"
    }

    /// A token amount: below 1,000 a whole number; from 1,000 in `K` and from 1,000,000 in `M`,
    /// rounded to the nearest with at most one decimal and no trailing `.0`. `850`, `17.7K`,
    /// `120K`, `1M`, `1.5M`.
    public static func tokens(_ amount: Int) -> String {
        let magnitude = amount.magnitude
        let sign = amount < 0 ? "-" : ""
        guard magnitude >= 1000 else { return "\(sign)\(magnitude)" }
        let (unit, suffix): (UInt, String) = magnitude >= 1_000_000 ? (1_000_000, "M") : (1000, "K")
        // Tenths of the unit, rounded half up.
        let tenths = (magnitude * 10 + unit / 2) / unit
        let decimal = tenths % 10
        return "\(sign)\(tenths / 10)\(decimal == 0 ? "" : ".\(decimal)")\(suffix)"
    }
}
