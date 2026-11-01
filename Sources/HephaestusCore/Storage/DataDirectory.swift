import Foundation

/// The device data directory and its paths (docs/architecture.md › Device data directory,
/// docs/data-model.md › Device data directory).
public struct DataDirectory: Sendable, Hashable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// `~/Library/Application Support/HephaestusV2/`.
    public static func defaultURL(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/HephaestusV2", isDirectory: true)
    }

    // MARK: Device files

    public var deviceFile: URL { url.appendingPathComponent("device.yml") }
    public var registryFile: URL { url.appendingPathComponent("registry.yml") }
    public var settingsFile: URL { url.appendingPathComponent("settings.yml") }
    public var secretsFile: URL { url.appendingPathComponent("secrets.json") }
    public var remotesFile: URL { url.appendingPathComponent("remotes.yml") }

    /// `<file>.invalid`: a device file found invalid at launch, set aside.
    public func invalidCopy(of file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".invalid")
    }

    // MARK: Folders

    /// `Skills/`: the default skills library.
    public var skillsFolder: URL { url.appendingPathComponent("Skills", isDirectory: true) }
    /// `Runtime/`: generated files only.
    public var runtimeFolder: URL { url.appendingPathComponent("Runtime", isDirectory: true) }
    /// `Runtime/plugins/`
    public var pluginsFolder: URL { runtimeFolder.appendingPathComponent("plugins", isDirectory: true) }
    /// `Runtime/plugins/<projectID>/`: the generated skills plugin of a project.
    public func pluginFolder(projectID: ProjectID) -> URL {
        pluginsFolder.appendingPathComponent(projectID, isDirectory: true)
    }
    /// `Runtime/claude-cwd/`: the empty working directory of the models probe and the naming calls.
    public var claudeWorkingDirectory: URL { runtimeFolder.appendingPathComponent("claude-cwd", isDirectory: true) }
    /// `Runtime/mcp/`
    public var mcpConfigFolder: URL { runtimeFolder.appendingPathComponent("mcp", isDirectory: true) }
    /// `Runtime/mcp/<chatID>.json`: the MCP configuration of a chat process, mode 0600.
    public func mcpConfigFile(chatID: ChatID) -> URL {
        mcpConfigFolder.appendingPathComponent("\(chatID.uuidString).json")
    }
    /// `Runtime/screenshots/`: PNG files of `debug_screenshot`.
    public var screenshotsFolder: URL { runtimeFolder.appendingPathComponent("screenshots", isDirectory: true) }
    /// `Logs/`
    public var logsFolder: URL { url.appendingPathComponent("Logs", isDirectory: true) }
    /// `Logs/engine.log`
    public var engineLogFile: URL { logsFolder.appendingPathComponent("engine.log") }
    /// `Logs/claude-<chatID>.log`: standard error of the chat's Claude processes.
    public func claudeLogFile(chatID: ChatID) -> URL {
        logsFolder.appendingPathComponent("claude-\(chatID.uuidString).log")
    }
    /// `Logs/claude-<chatID>.stdout.jsonl`: raw standard output, only with `HEPHAESTUS_DEBUG_TOOLS=1`.
    public func claudeStdoutCaptureFile(chatID: ChatID) -> URL {
        logsFolder.appendingPathComponent("claude-\(chatID.uuidString).stdout.jsonl")
    }

    /// The subfolders the engine creates at launch.
    public var subfolders: [URL] {
        [skillsFolder, runtimeFolder, pluginsFolder, claudeWorkingDirectory, mcpConfigFolder, screenshotsFolder, logsFolder]
    }

    /// Creates the data directory (mode 0700) with its intermediate folders, then its missing
    /// subfolders.
    public func createIfNeeded() throws {
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: url.path) {
                try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            for folder in subfolders where !manager.fileExists(atPath: folder.path) {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            }
        } catch {
            throw StorageError.dataDirectoryUnavailable(path: url.path, reason: error.localizedDescription)
        }
    }
}
