import Foundation

/// Everything the engine needs from its process; it reads no environment variable and no
/// `Info.plist` value itself (docs/architecture.md › Engine configuration).
public struct EngineConfiguration: Sendable {
    /// Interfaces the sync server listens on.
    public enum SyncInterface: String, Sendable, Hashable {
        case all
        case loopback
    }

    public var dataDirectory: URL
    /// `HEPHAESTUS_MCP_PORT`; nil uses the `mcpPort` setting; 0 lets the system pick a free
    /// port (accepted only here).
    public var mcpPort: Int?
    /// `HEPHAESTUS_SYNC_PORT`; nil uses the `syncPort` setting; 0 lets the system pick a free port.
    public var syncPort: Int?
    public var syncInterface: SyncInterface
    public var advertisesBonjour: Bool
    public var debugTools: Bool
    /// `HEPHAESTUS_CLAUDE_PATH`, used when the `claudePath` setting is not set.
    public var claudePath: String?
    public var claudeLauncher: any ClaudeProcessLauncher
    /// `CFBundleShortVersionString`, as in `DeviceInfo`.
    public var appVersion: String
    /// `CFBundleVersion`, as in `DeviceInfo`; 0 for a development build.
    public var build: Int
    /// The HephaestusV2 project (docs/projects.md › HephaestusV2 project); nil turns it off: no
    /// launch check, no clone, `HEPH` is an ordinary identifier and nothing is hidden.
    public var hephaestusProject: HephaestusProjectConfiguration?
    /// Gives the memory folder of a project root (docs/memories.md › Resolution).
    public var memoryFolders: any MemoryFolderResolving
    /// Looks the GitHub CLI up and runs it for the `builds.*` methods (docs/builds.md › gh calls).
    public var githubCLI: any GitHubCLIRunning
    /// The Downloads folder where `builds.downloadAsset` saves release assets
    /// (docs/builds.md › Downloads).
    public var downloadsFolder: URL

    public init(dataDirectory: URL, mcpPort: Int?, syncPort: Int?, syncInterface: SyncInterface, advertisesBonjour: Bool,
                debugTools: Bool, claudePath: String?, claudeLauncher: any ClaudeProcessLauncher, appVersion: String, build: Int,
                hephaestusProject: HephaestusProjectConfiguration? = nil,
                memoryFolders: any MemoryFolderResolving = ClaudeMemoryFolderResolver(homeDirectory: NSHomeDirectory()),
                githubCLI: any GitHubCLIRunning = MissingGitHubCLI(),
                downloadsFolder: URL = EngineConfiguration.userDownloadsFolder(homeDirectory: NSHomeDirectory())) {
        self.dataDirectory = dataDirectory
        self.mcpPort = mcpPort
        self.syncPort = syncPort
        self.syncInterface = syncInterface
        self.advertisesBonjour = advertisesBonjour
        self.debugTools = debugTools
        self.claudePath = claudePath
        self.claudeLauncher = claudeLauncher
        self.appVersion = appVersion
        self.build = build
        self.hephaestusProject = hephaestusProject
        self.memoryFolders = memoryFolders
        self.githubCLI = githubCLI
        self.downloadsFolder = downloadsFolder
    }

    /// The Downloads folder of the user, `<home>/Downloads` when the system names none.
    public static func userDownloadsFolder(homeDirectory: String) -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: homeDirectory, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The app's configuration: the values of the launch environment, all interfaces, Bonjour
    /// advertising, the real Claude CLI, the bundle's version and the HephaestusV2 project cloned
    /// from its repository.
    public static func app(environment: LaunchEnvironment, appVersion: String, build: Int,
                           claudeLauncher: any ClaudeProcessLauncher = SystemClaudeProcessLauncher(),
                           homeDirectory: String = NSHomeDirectory()) -> EngineConfiguration {
        EngineConfiguration(
            dataDirectory: environment.dataDirectory ?? DataDirectory.defaultURL(homeDirectory: homeDirectory),
            mcpPort: environment.mcpPort,
            syncPort: environment.syncPort,
            syncInterface: .all,
            advertisesBonjour: true,
            debugTools: environment.debugTools,
            claudePath: environment.claudePath,
            claudeLauncher: claudeLauncher,
            appVersion: appVersion,
            build: build,
            hephaestusProject: HephaestusProjectConfiguration(cloneURL: HephaestusRepository.url),
            memoryFolders: ClaudeMemoryFolderResolver(homeDirectory: homeDirectory),
            githubCLI: SystemGitHubCLI(),
            downloadsFolder: userDownloadsFolder(homeDirectory: homeDirectory)
        )
    }

    /// A test configuration: the given temporary data directory, ports 0, the sync server on
    /// the loopback interface, no Bonjour advertising, no Claude path, version `0.0.0`, build 0,
    /// no HephaestusV2 project unless the test gives one, and memory folders under the folders
    /// `Claude` (config folder) and `Home` next to the data directory, without managed settings,
    /// unless the test gives a resolver: no test reads or writes `~/.claude`. Without a GitHub CLI
    /// of the test, gh is never found, and assets are saved in the folder `Downloads` next to the
    /// data directory: no test runs the user's gh or writes into the user's Downloads folder.
    public static func test(dataDirectory: URL, debugTools: Bool = false, claudeLauncher: any ClaudeProcessLauncher,
                            hephaestusProject: HephaestusProjectConfiguration? = nil,
                            memoryFolders: (any MemoryFolderResolving)? = nil,
                            githubCLI: (any GitHubCLIRunning)? = nil) -> EngineConfiguration {
        let testFolder = dataDirectory.deletingLastPathComponent()
        return EngineConfiguration(
            dataDirectory: dataDirectory,
            mcpPort: 0,
            syncPort: 0,
            syncInterface: .loopback,
            advertisesBonjour: false,
            debugTools: debugTools,
            claudePath: nil,
            claudeLauncher: claudeLauncher,
            appVersion: "0.0.0",
            build: 0,
            hephaestusProject: hephaestusProject,
            memoryFolders: memoryFolders ?? ClaudeMemoryFolderResolver(
                homeDirectory: testFolder.appendingPathComponent("Home", isDirectory: true).path,
                configDirectory: testFolder.appendingPathComponent("Claude", isDirectory: true).path,
                managedSettingsPath: nil),
            githubCLI: githubCLI ?? MissingGitHubCLI(),
            downloadsFolder: testFolder.appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    /// The MCP port in use: the override, else the stored setting.
    public func mcpPort(settings: HostSettings) -> Int {
        mcpPort ?? settings.mcpPort
    }

    /// The sync port in use: the override, else the stored setting.
    public func syncPort(settings: HostSettings) -> Int {
        syncPort ?? settings.syncPort
    }
}

/// The HephaestusV2 project of an engine (docs/architecture.md › Engine configuration).
public struct HephaestusProjectConfiguration: Sendable, Hashable {
    /// The URL `git clone` reads: the repository URL in the app, a local repository in tests. The
    /// clone's `origin` is then set to the repository URL.
    public var cloneURL: String

    public init(cloneURL: String) {
        self.cloneURL = cloneURL
    }
}
