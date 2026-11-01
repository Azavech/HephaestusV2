import Foundation

/// Prepares the generated skills plugin of a project, `Runtime/plugins/<projectID>/`, passed to
/// its chat processes with `--plugin-dir` (docs/skills.md › Generated plugin).
// DOC-GAP: the docs describe the generated plugin but name no Swift type for it;
// `SkillsPluginProvider` is the seam the chat launch and `skills.*` call.
public protocol SkillsPluginProvider: Sendable {
    /// Regenerates the plugin folder of a project from its enabled skills and the library, and
    /// returns the folder to pass with `--plugin-dir`. Throws on a file system error; the launch
    /// then goes on without `--plugin-dir` (docs/skills.md › Generation).
    func preparePlugin(projectID: ProjectID, skills: [String], library: URL, dataDirectory: DataDirectory) throws -> URL
}

/// The generator of the app (docs/skills.md › Generation).
// STUB: core-search-skills — the layout of docs/skills.md › Layout (plugin.json, symbolic links
// to the enabled skills).
public struct SkillsPluginGenerator: SkillsPluginProvider {
    public init() {}

    public func preparePlugin(projectID: ProjectID, skills: [String], library: URL, dataDirectory: DataDirectory) throws -> URL {
        throw EngineError.notImplemented("The skills plugin")
    }
}
