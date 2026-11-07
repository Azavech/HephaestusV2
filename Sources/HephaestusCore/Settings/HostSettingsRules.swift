import Foundation

/// The rules of `HostSettings` that depend on the device: write rules, `~/` expansion and the
/// skills library folder (docs/data-model.md › Settings file, docs/engine-api.md › settings.update).
extension HostSettings {
    /// The write rules of the field table.
    public func validate(homeDirectory: String = NSHomeDirectory()) throws {
        if let claudePath, !ModelRules.isAbsoluteOrHomePath(claudePath) {
            throw ValidationError.invalid("claudePath", "use an absolute path or a path starting with ~/")
        }
        try defaultChatSettings.validate()
        _ = try ModelRules.serverPort(mcpPort, field: "mcpPort")
        _ = try ModelRules.serverPort(syncPort, field: "syncPort")
        guard mcpPort != syncPort else {
            throw ValidationError.invalid("syncPort", "use a port different from mcpPort")
        }
        if let skillsLibraryPath {
            guard ModelRules.isAbsoluteOrHomePath(skillsLibraryPath) else {
                throw ValidationError.invalid("skillsLibraryPath", "use an absolute path or a path starting with ~/")
            }
            let expanded = HostSettings.expand(skillsLibraryPath, homeDirectory: homeDirectory)
            let claudeFolder = (homeDirectory as NSString).appendingPathComponent(".claude")
            if expanded == claudeFolder || expanded.hasPrefix(claudeFolder + "/") {
                throw ValidationError.invalid("skillsLibraryPath", "use a folder that is not inside ~/.claude")
            }
        }
        _ = try ModelRules.updateCheckInterval(updateCheckIntervalMinutes)
    }

    /// `claudePath` with a leading `~/` expanded to the home folder; nil when not set.
    public func resolvedClaudePath(homeDirectory: String = NSHomeDirectory()) -> String? {
        claudePath.map { HostSettings.expand($0, homeDirectory: homeDirectory) }
    }

    /// The skills library folder: `skillsLibraryPath` with `~/` expanded, else
    /// `<data dir>/Skills`.
    public func skillsLibraryURL(dataDirectory: DataDirectory, homeDirectory: String = NSHomeDirectory()) -> URL {
        guard let skillsLibraryPath else { return dataDirectory.skillsFolder }
        return URL(fileURLWithPath: HostSettings.expand(skillsLibraryPath, homeDirectory: homeDirectory), isDirectory: true)
    }

    /// Expands a leading `~/` and standardizes the path.
    static func expand(_ path: String, homeDirectory: String) -> String {
        let expanded = path.hasPrefix("~/") ? homeDirectory + "/" + path.dropFirst(2) : path
        return (expanded as NSString).standardizingPath
    }
}
