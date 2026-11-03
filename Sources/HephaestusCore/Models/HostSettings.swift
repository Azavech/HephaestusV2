import Foundation

/// `<data dir>/settings.yml`: the host settings (docs/data-model.md › Settings file). The rules
/// that use the environment (paths, ports in effect) are in `Settings/HostSettingsRules.swift`
/// (docs/data-model.md › Swift types, docs/architecture.md › HephaestusCore folders).
public struct HostSettings: Codable, Sendable, Hashable {
    public var schema: Int
    public var claudePath: String?
    public var defaultChatSettings: ChatSettings
    public var feedbackProjectID: ProjectID?
    public var mcpPort: Int
    public var syncEnabled: Bool
    public var syncPort: Int
    public var skillsLibraryPath: String?
    public var autoUpdate: Bool
    public var updateCheckIntervalMinutes: Int
    public var formatGoOnSave: Bool
    public var formatSwiftOnSave: Bool
    /// This Mac posts a notification when a chat needs the user (docs/ui.md › Notifications).
    public var notifyNeedsYou: Bool
    /// This Mac posts a notification when Claude finishes replying.
    public var notifyFinished: Bool
    /// This Mac posts the notifications with Haiku's summary; false posts them at once with the
    /// fallback detail (docs/chats.md › Notifications).
    public var notifyAISummary: Bool
    public var unknownKeys: [String: JSONValue]

    public static let defaultMCPPort = 47820
    public static let defaultSyncPort = 47821

    public init(schema: Int = 1, claudePath: String? = nil, defaultChatSettings: ChatSettings = ChatSettings(),
                feedbackProjectID: ProjectID? = nil, mcpPort: Int = HostSettings.defaultMCPPort, syncEnabled: Bool = true,
                syncPort: Int = HostSettings.defaultSyncPort, skillsLibraryPath: String? = nil, autoUpdate: Bool = true,
                updateCheckIntervalMinutes: Int = 30, formatGoOnSave: Bool = true, formatSwiftOnSave: Bool = false,
                notifyNeedsYou: Bool = true, notifyFinished: Bool = true, notifyAISummary: Bool = true,
                unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.claudePath = claudePath
        self.defaultChatSettings = defaultChatSettings
        self.feedbackProjectID = feedbackProjectID
        self.mcpPort = mcpPort
        self.syncEnabled = syncEnabled
        self.syncPort = syncPort
        self.skillsLibraryPath = skillsLibraryPath
        self.autoUpdate = autoUpdate
        self.updateCheckIntervalMinutes = updateCheckIntervalMinutes
        self.formatGoOnSave = formatGoOnSave
        self.formatSwiftOnSave = formatSwiftOnSave
        self.notifyNeedsYou = notifyNeedsYou
        self.notifyFinished = notifyFinished
        self.notifyAISummary = notifyAISummary
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = [
        "schema", "claudePath", "defaultChatSettings", "feedbackProjectID", "mcpPort", "syncEnabled", "syncPort",
        "skillsLibraryPath", "autoUpdate", "updateCheckIntervalMinutes", "formatGoOnSave", "formatSwiftOnSave",
        "notifyNeedsYou", "notifyFinished", "notifyAISummary",
    ]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        claudePath = try c.optional("claudePath")
        defaultChatSettings = try c.value("defaultChatSettings", default: ChatSettings())
        feedbackProjectID = try c.optional("feedbackProjectID")
        if let feedbackProjectID {
            try c.check("feedbackProjectID", feedbackProjectID, Identifiers.isProjectID, "project identifier")
        }
        mcpPort = try c.value("mcpPort", default: HostSettings.defaultMCPPort)
        syncEnabled = try c.value("syncEnabled", default: true)
        syncPort = try c.value("syncPort", default: HostSettings.defaultSyncPort)
        skillsLibraryPath = try c.optional("skillsLibraryPath")
        autoUpdate = try c.value("autoUpdate", default: true)
        updateCheckIntervalMinutes = try c.value("updateCheckIntervalMinutes", default: 30)
        formatGoOnSave = try c.value("formatGoOnSave", default: true)
        formatSwiftOnSave = try c.value("formatSwiftOnSave", default: false)
        notifyNeedsYou = try c.value("notifyNeedsYou", default: true)
        notifyFinished = try c.value("notifyFinished", default: true)
        notifyAISummary = try c.value("notifyAISummary", default: true)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encodeOptional(claudePath, "claudePath")
        try c.encode(defaultChatSettings, "defaultChatSettings")
        try c.encodeOptional(feedbackProjectID, "feedbackProjectID")
        try c.encode(mcpPort, "mcpPort")
        try c.encode(syncEnabled, "syncEnabled")
        try c.encode(syncPort, "syncPort")
        try c.encodeOptional(skillsLibraryPath, "skillsLibraryPath")
        try c.encode(autoUpdate, "autoUpdate")
        try c.encode(updateCheckIntervalMinutes, "updateCheckIntervalMinutes")
        try c.encode(formatGoOnSave, "formatGoOnSave")
        try c.encode(formatSwiftOnSave, "formatSwiftOnSave")
        try c.encode(notifyNeedsYou, "notifyNeedsYou")
        try c.encode(notifyFinished, "notifyFinished")
        try c.encode(notifyAISummary, "notifyAISummary")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}
