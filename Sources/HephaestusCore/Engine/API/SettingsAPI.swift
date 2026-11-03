import Foundation

// docs/engine-api.md › Settings.

/// `settings.get`: the values of settings.yml with the defaults for missing keys; port overrides
/// from the environment are not reflected. Actors: user.
public enum SettingsGet: EngineMethod {
    public static let name = "settings.get"
    public typealias Params = Empty
    public typealias Result = HostSettings
}

/// `settings.update`: every param is optional; an absent param keeps its value. Actors: user.
public enum SettingsUpdate: EngineMethod {
    public static let name = "settings.update"
    public struct Params: Codable, Sendable, Hashable {
        /// Clearable: null returns to detection of the CLI.
        public var claudePath: Patch<String> = .keep
        /// Complete defaults for new chats.
        public var defaultChatSettings: ChatSettings?
        /// Clearable: null returns to automatic resolution.
        public var feedbackProjectID: Patch<ProjectID> = .keep
        public var mcpPort: Int?
        public var syncEnabled: Bool?
        public var syncPort: Int?
        /// Clearable: null returns to `<data dir>/Skills`.
        public var skillsLibraryPath: Patch<String> = .keep
        public var autoUpdate: Bool?
        public var updateCheckIntervalMinutes: Int?
        public var formatGoOnSave: Bool?
        public var formatSwiftOnSave: Bool?
        /// The notifications This Mac posts (docs/ui.md › Notifications).
        public var notifyNeedsYou: Bool?
        public var notifyFinished: Bool?
        public var notifyAISummary: Bool?

        public init(claudePath: Patch<String> = .keep, defaultChatSettings: ChatSettings? = nil,
                    feedbackProjectID: Patch<ProjectID> = .keep, mcpPort: Int? = nil, syncEnabled: Bool? = nil,
                    syncPort: Int? = nil, skillsLibraryPath: Patch<String> = .keep, autoUpdate: Bool? = nil,
                    updateCheckIntervalMinutes: Int? = nil, formatGoOnSave: Bool? = nil, formatSwiftOnSave: Bool? = nil,
                    notifyNeedsYou: Bool? = nil, notifyFinished: Bool? = nil, notifyAISummary: Bool? = nil) {
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
        }

        /// `settings` with every present param applied.
        public func applied(to settings: HostSettings) -> HostSettings {
            var result = settings
            result.claudePath = claudePath.applied(to: settings.claudePath)
            if let defaultChatSettings { result.defaultChatSettings = defaultChatSettings }
            result.feedbackProjectID = feedbackProjectID.applied(to: settings.feedbackProjectID)
            if let mcpPort { result.mcpPort = mcpPort }
            if let syncEnabled { result.syncEnabled = syncEnabled }
            if let syncPort { result.syncPort = syncPort }
            result.skillsLibraryPath = skillsLibraryPath.applied(to: settings.skillsLibraryPath)
            if let autoUpdate { result.autoUpdate = autoUpdate }
            if let updateCheckIntervalMinutes { result.updateCheckIntervalMinutes = updateCheckIntervalMinutes }
            if let formatGoOnSave { result.formatGoOnSave = formatGoOnSave }
            if let formatSwiftOnSave { result.formatSwiftOnSave = formatSwiftOnSave }
            if let notifyNeedsYou { result.notifyNeedsYou = notifyNeedsYou }
            if let notifyFinished { result.notifyFinished = notifyFinished }
            if let notifyAISummary { result.notifyAISummary = notifyAISummary }
            return result
        }
    }
    public typealias Result = HostSettings
}
