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

    public init(dataDirectory: URL, mcpPort: Int?, syncPort: Int?, syncInterface: SyncInterface, advertisesBonjour: Bool,
                debugTools: Bool, claudePath: String?, claudeLauncher: any ClaudeProcessLauncher, appVersion: String, build: Int) {
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
    }

    /// The app's configuration: the values of the launch environment, all interfaces, Bonjour
    /// advertising, the real Claude CLI and the bundle's version.
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
            build: build
        )
    }

    /// A test configuration: the given temporary data directory, ports 0, the sync server on
    /// the loopback interface, no Bonjour advertising, no Claude path, version `0.0.0` and build 0.
    public static func test(dataDirectory: URL, debugTools: Bool = false,
                            claudeLauncher: any ClaudeProcessLauncher) -> EngineConfiguration {
        EngineConfiguration(
            dataDirectory: dataDirectory,
            mcpPort: 0,
            syncPort: 0,
            syncInterface: .loopback,
            advertisesBonjour: false,
            debugTools: debugTools,
            claudePath: nil,
            claudeLauncher: claudeLauncher,
            appVersion: "0.0.0",
            build: 0
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
