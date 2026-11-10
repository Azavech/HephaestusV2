import Foundation

/// The rules of `HostSettings` that depend on the device: write rules, `~/` expansion and the
/// skills library folder (docs/data-model.md › Settings file, docs/engine-api.md › settings.update).
extension HostSettings {
    /// The write rules of the field table, except the ranges of the default values of virtual
    /// machines, which `checkVMDefaults(changedFrom:limits:)` checks.
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
        _ = try ModelRules.claudeVMIdleMinutes(claudeVMIdleMinutes)
    }

    /// The ranges of the default values of virtual machines on a Mac, this one by default, for the
    /// values that differ from `old`: a value read at launch from a larger Mac's file stays until
    /// it is changed (docs/data-model.md › Settings file).
    public func checkVMDefaults(changedFrom old: HostSettings, limits: VMImageLimits = .host) throws {
        for (key, value, oldValue, range) in [("defaultVMCores", defaultVMCores, old.defaultVMCores, limits.cores),
                                              ("defaultVMMemoryGB", defaultVMMemoryGB, old.defaultVMMemoryGB, limits.memoryGB),
                                              ("defaultVMDiskGB", defaultVMDiskGB, old.defaultVMDiskGB, limits.diskGB)]
            where value != oldValue && !range.contains(value) {
            throw ValidationError.invalid(key, "use a number from \(range.lowerBound) to \(range.upperBound)")
        }
    }

    /// The default values of new virtual machines, each brought to the nearest end of its range on
    /// this Mac (docs/virtual-machines.md › Default values): a value read at launch may come from a
    /// larger Mac.
    public func vmDefaults(_ limits: VMImageLimits = .host) -> (cores: Int, memoryGB: Int, diskGB: Int) {
        (VMImageLimits.clamped(defaultVMCores, limits.cores), VMImageLimits.clamped(defaultVMMemoryGB, limits.memoryGB),
         VMImageLimits.clamped(defaultVMDiskGB, limits.diskGB))
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
