import Foundation

/// `<data dir>/secrets.json`, file mode 0600 (docs/data-model.md › Secrets file).
public struct Secrets: Codable, Sendable, Hashable {
    public var schema: Int
    /// This device's pairing code in display form.
    public var pairingCode: String
    /// Token of external Claude sessions: 64 lowercase hexadecimal characters.
    public var mcpExternalToken: String
    /// Pairing code of each paired remote device, keyed by its id as an uppercase UUID string.
    public var remoteSecrets: [String: String]
    /// The Claude token that each virtual machine gets when it starts; nil while the user has set
    /// none (docs/virtual-machines.md › Claude token).
    public var claudeVMToken: String?
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, pairingCode: String = RandomIDs.pairingCode(),
                mcpExternalToken: String = RandomIDs.externalToken(), remoteSecrets: [String: String] = [:],
                claudeVMToken: String? = nil, unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.pairingCode = pairingCode
        self.mcpExternalToken = mcpExternalToken
        self.remoteSecrets = remoteSecrets
        self.claudeVMToken = claudeVMToken
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "pairingCode", "mcpExternalToken", "remoteSecrets", "claudeVMToken"]

    /// A missing `pairingCode` or `mcpExternalToken` is generated; `generatedKeys` of the
    /// storage layer tells whether the file must be written again.
    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        // The messages never include the values: they may reach engine.log, which never holds
        // tokens or pairing codes (docs/architecture.md › engine.log).
        pairingCode = try c.optional("pairingCode") ?? RandomIDs.pairingCode()
        guard Identifiers.isPairingCode(pairingCode) else { throw c.invalid("pairingCode", "the pairing code is malformed") }
        mcpExternalToken = try c.optional("mcpExternalToken") ?? RandomIDs.externalToken()
        guard Identifiers.isExternalToken(mcpExternalToken) else {
            throw c.invalid("mcpExternalToken", "the external MCP token is malformed")
        }
        remoteSecrets = try c.value("remoteSecrets", default: [:])
        try c.checkAll("remoteSecrets", Array(remoteSecrets.keys), Identifiers.isUUID, "device id")
        guard remoteSecrets.values.allSatisfy(Identifiers.isPairingCode) else {
            throw c.invalid("remoteSecrets", "a pairing code of a paired device is malformed")
        }
        claudeVMToken = try c.optional("claudeVMToken")
        if let claudeVMToken, !Self.isClaudeVMToken(claudeVMToken) {
            throw c.invalid("claudeVMToken", "the Claude token is malformed")
        }
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(pairingCode, "pairingCode")
        try c.encode(mcpExternalToken, "mcpExternalToken")
        try c.encode(remoteSecrets, "remoteSecrets")
        // Absent while the user has set no token (docs/data-model.md › Secrets file).
        if let claudeVMToken {
            try c.encode(claudeVMToken, "claudeVMToken")
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The write rules of the field table.
    public func validate() throws {
        guard Identifiers.isPairingCode(pairingCode) else { throw ValidationError.invalid("pairingCode", "use the form XXXX-XXXX-XXXX-XXXX") }
        guard Identifiers.isExternalToken(mcpExternalToken) else {
            throw ValidationError.invalid("mcpExternalToken", "use 64 lowercase hexadecimal characters")
        }
        for (deviceID, code) in remoteSecrets {
            guard Identifiers.isUppercaseUUID(deviceID) else { throw ValidationError.invalid("remoteSecrets", "key devices by their uppercase UUID") }
            guard Identifiers.isPairingCode(code) else { throw ValidationError.invalid("remoteSecrets", "use pairing codes of the form XXXX-XXXX-XXXX-XXXX") }
        }
        if let claudeVMToken, !Self.isClaudeVMToken(claudeVMToken) {
            throw Self.claudeVMTokenError
        }
    }

    /// The rule of `claudeVMToken`: one line without white space, 1 to 4096 characters.
    public static func isClaudeVMToken(_ value: String) -> Bool {
        (1...4096).contains(value.count) && !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }

    static let claudeVMTokenError = ValidationError.invalid("claudeVMToken", "use one line without white space")

    /// The token of the `Claude token` field (docs/ui.md › Virtual Machines): trimmed of white
    /// space at both ends; nil for an empty field, which removes the token. Throws `invalid` for a
    /// token with white space inside or longer than 4096 characters.
    public static func checkedClaudeVMToken(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isClaudeVMToken(trimmed) else { throw claudeVMTokenError }
        return trimmed
    }
}
