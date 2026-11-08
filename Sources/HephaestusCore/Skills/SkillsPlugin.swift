import Darwin
import Foundation

/// Prepares the generated skills plugin of a project, `Runtime/plugins/<projectID>/`, passed to
/// its chat processes with `--plugin-dir` (docs/skills.md › Generated plugin). The chat launch
/// and the `skills.*` methods call it (docs/architecture.md › HephaestusCore folders).
public protocol SkillsPluginProvider: Sendable {
    /// Regenerates the plugin folder of a project from its enabled skills, the called internal
    /// skills and the library, and returns the folder to pass with `--plugin-dir`. The engine writes the
    /// missing internal skills before it calls this. Throws on a file system error; the launch
    /// then goes on without `--plugin-dir` (docs/skills.md › Generation).
    ///
    /// When neither an enabled skill nor a called internal skill is a skill of the library, the folder is deleted and the returned
    /// URL names no folder: the CLI then gets no `--plugin-dir` (docs/skills.md › Generation,
    /// steps 2 and 4), so a caller passes `--plugin-dir` only when a folder exists at the URL.
    func preparePlugin(projectID: ProjectID, skills: [String], library: URL, dataDirectory: DataDirectory) throws -> URL
}

/// The generator of the app (docs/skills.md › Layout and › Generation).
public struct SkillsPluginGenerator: SkillsPluginProvider {
    /// The plugin's name, also its folder in `Runtime/plugins/<projectID>/`.
    public static let pluginName = "hephaestus-skills"

    public init() {}

    public func preparePlugin(projectID: ProjectID, skills: [String], library: URL, dataDirectory: DataDirectory) throws -> URL {
        let folder = dataDirectory.pluginFolder(projectID: projectID)
        let manager = FileManager.default
        let libraryPath = library.standardizedFileURL.path

        // 1. E: the names of the project's list, other than the system prompt skills, and of the
        // called internal skills that are skills of the library, sorted by name
        // (docs/skills.md › Generation).
        let listed = skills.filter { PromptSkill(rawValue: $0) == nil }
        let enabled = Set(listed + InternalSkills.calledNames).filter { SkillsLibraryReader.isSkill(named: $0, in: library) }.sorted()

        // 2. No enabled skill: the folder is deleted.
        guard !enabled.isEmpty else {
            if SkillsLibraryReader.itemExists(folder) {
                try manager.removeItem(at: folder)
            }
            return folder
        }

        // 3.1 The folders of the layout.
        let plugin = folder.appendingPathComponent(Self.pluginName, isDirectory: true)
        let manifestFolder = plugin.appendingPathComponent(".claude-plugin", isDirectory: true)
        let skillsFolder = plugin.appendingPathComponent("skills", isDirectory: true)
        for directory in [manifestFolder, skillsFolder] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // 3.2 plugin.json, written atomically when missing or different.
        let manifest = manifestFolder.appendingPathComponent("plugin.json")
        let content = Self.manifest(projectID: projectID)
        if (try? Data(contentsOf: manifest)) != content {
            try AtomicFile.write(content, to: manifest)
        }

        // 3.3 Every entry of skills/ that is not a link named after a member of E and pointing
        // to `<skills library>/<name>` is removed.
        var linked = Set<String>()
        for name in try manager.contentsOfDirectory(atPath: skillsFolder.path) {
            let entry = skillsFolder.appendingPathComponent(name)
            if enabled.contains(name), Self.isLink(entry, to: "\(libraryPath)/\(name)") {
                linked.insert(name)
            } else {
                try manager.removeItem(at: entry)
            }
        }

        // 3.4 The missing links, with absolute targets.
        for name in enabled where !linked.contains(name) {
            try manager.createSymbolicLink(atPath: skillsFolder.appendingPathComponent(name).path,
                                           withDestinationPath: "\(libraryPath)/\(name)")
        }
        return folder
    }

    /// The content of `plugin.json` for a project.
    public static func manifest(projectID: ProjectID) -> Data {
        Data("""
        {
          "name": "\(pluginName)",
          "version": "1.0.0",
          "description": "Skills enabled for project \(projectID) in HephaestusV2."
        }

        """.utf8)
    }

    /// True when `url` is a symbolic link whose target is exactly `target`.
    private static func isLink(_ url: URL, to target: String) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return false }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == target
    }
}
