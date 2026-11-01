import Foundation

/// `<data dir>/plan-usage.yml`: the newest weekly usage of the Claude account that the engine
/// knows, read from a `rate_limit_event` line (docs/data-model.md › Plan usage file,
/// docs/chats.md › Plan usage). The engine API sends the same object.
public struct PlanUsage: Codable, Sendable, Hashable {
    public var schema: Int
    /// The fraction of the week's limit used, usually 0 to 1; above 1 past the limit.
    public var utilization: Double
    /// When the weekly window resets.
    public var resetsAt: Date
    /// `allowed`, `allowed_warning` or `rejected`, as the CLI sends it.
    public var status: String
    public var overageStatus: String?
    public var overageDisabledReason: String?
    public var isUsingOverage: Bool?
    /// When the engine that read the line received it (docs/engine-api.md › Plan usage).
    public var received: Date
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, utilization: Double, resetsAt: Date, status: String, overageStatus: String? = nil,
                overageDisabledReason: String? = nil, isUsingOverage: Bool? = nil, received: Date,
                unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.status = status
        self.overageStatus = overageStatus
        self.overageDisabledReason = overageDisabledReason
        self.isUsingOverage = isUsingOverage
        self.received = received
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "utilization", "resetsAt", "status", "overageStatus", "overageDisabledReason",
                                         "isUsingOverage", "received"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        utilization = try c.required("utilization")
        resetsAt = try c.requiredDate("resetsAt")
        status = try c.required("status")
        overageStatus = try c.optional("overageStatus")
        overageDisabledReason = try c.optional("overageDisabledReason")
        isUsingOverage = try c.optional("isUsingOverage")
        received = try c.requiredDate("received")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(utilization, "utilization")
        try c.encodeDate(resetsAt, "resetsAt")
        try c.encode(status, "status")
        try c.encodeOptional(overageStatus, "overageStatus")
        try c.encodeOptional(overageDisabledReason, "overageDisabledReason")
        try c.encodeOptional(isUsingOverage, "isUsingOverage")
        try c.encodeDate(received, "received")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// True when the reset time has passed: the value is hidden (docs/engine-api.md › Plan usage).
    public func hasExpired(at now: Date) -> Bool {
        resetsAt <= now
    }

    /// The write rules of the field table.
    public func validate() throws {
        guard utilization.isFinite, utilization >= 0 else {
            throw ValidationError.invalid("utilization", "use a number of 0 or more")
        }
        for (field, value) in [("status", status), ("overageStatus", overageStatus), ("overageDisabledReason", overageDisabledReason)] {
            guard let value else { continue }
            guard !value.isEmpty, !ModelRules.containsLineBreak(value) else {
                throw ValidationError.invalid(field, "use one line that is not empty")
            }
        }
    }
}
