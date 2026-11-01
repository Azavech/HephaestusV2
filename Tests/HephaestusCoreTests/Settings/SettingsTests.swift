import Foundation
import Testing
@testable import HephaestusCore

@Suite("LaunchEnvironment")
struct LaunchEnvironmentTests {
    @Test("Without variables every value is unset")
    func empty() throws {
        let environment = try LaunchEnvironment.parse(["PATH": "/usr/bin", "HOME": "/Users/example"], homeDirectory: "/Users/example")
        #expect(environment == LaunchEnvironment())
        #expect(environment.restoresWindowState)
    }

    @Test("Every variable with an accepted value")
    func acceptedValues() throws {
        try withTemporaryDirectory { folder in
            let dataDirectory = folder.appendingPathComponent("B/data").path
            let environment = try LaunchEnvironment.parse([
                "HEPHAESTUS_DATA_DIR": dataDirectory,
                "HEPHAESTUS_MCP_PORT": "47830",
                "HEPHAESTUS_SYNC_PORT": "47831",
                "HEPHAESTUS_DISABLE_UPDATER": "1",
                "HEPHAESTUS_DEBUG_TOOLS": "1",
                "HEPHAESTUS_WINDOW_SCREEN": "offscreen",
                "HEPHAESTUS_CLAUDE_PATH": "~/bin/claude",
            ], homeDirectory: "/Users/example")
            #expect(environment.dataDirectory?.path == dataDirectory)
            #expect(environment.mcpPort == 47830)
            #expect(environment.syncPort == 47831)
            #expect(environment.disableUpdater)
            #expect(environment.debugTools)
            #expect(environment.windowScreen == .offscreen)
            #expect(environment.claudePath == "/Users/example/bin/claude")
            #expect(!environment.restoresWindowState)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dataDirectory, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
    }

    @Test("The empty string is unset and 0 has the effect of unset")
    func emptyAndZero() throws {
        let environment = try LaunchEnvironment.parse([
            "HEPHAESTUS_DATA_DIR": "", "HEPHAESTUS_MCP_PORT": "", "HEPHAESTUS_DISABLE_UPDATER": "0",
            "HEPHAESTUS_DEBUG_TOOLS": "0", "HEPHAESTUS_WINDOW_SCREEN": "", "HEPHAESTUS_UNKNOWN": "",
        ], homeDirectory: "/Users/example")
        #expect(environment == LaunchEnvironment())
    }

    @Test("Invalid values stop the launch with HephaestusV2: <NAME>: <reason>", arguments: [
        ("HEPHAESTUS_MCP_PORT", "80"),
        ("HEPHAESTUS_MCP_PORT", "65536"),
        ("HEPHAESTUS_SYNC_PORT", "abc"),
        ("HEPHAESTUS_SYNC_PORT", "+47821"),
        ("HEPHAESTUS_DISABLE_UPDATER", "yes"),
        ("HEPHAESTUS_DEBUG_TOOLS", "2"),
        ("HEPHAESTUS_WINDOW_SCREEN", "Main"),
        ("HEPHAESTUS_CLAUDE_PATH", "claude"),
        ("HEPHAESTUS_DATA_DIR", "relative/path"),
        ("HEPHAESTUS_DATA_DIRECTORY", "/tmp"),
    ])
    func invalid(_ name: String, _ value: String) {
        do {
            _ = try LaunchEnvironment.parse([name: value], homeDirectory: "/Users/example")
            Issue.record("\(name)=\(value) should be refused")
        } catch let error as LaunchEnvironmentError {
            #expect(error.name == name)
            #expect(error.message.hasPrefix("HephaestusV2: \(name): "))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(LaunchEnvironment.invalidExitStatus == 64)
    }

    @Test("A data directory that is not a writable directory is refused, and nothing is created before the checks")
    func unusableDataDirectory() throws {
        try withTemporaryDirectory { folder in
            let file = folder.appendingPathComponent("file")
            try Data().write(to: file)
            #expect(throws: LaunchEnvironmentError.self) {
                try LaunchEnvironment.parse(["HEPHAESTUS_DATA_DIR": file.path])
            }
            #expect(throws: LaunchEnvironmentError.self) {
                try LaunchEnvironment.parse(["HEPHAESTUS_DATA_DIR": file.appendingPathComponent("inside").path])
            }
            let notCreated = folder.appendingPathComponent("never")
            #expect(throws: LaunchEnvironmentError.self) {
                try LaunchEnvironment.parse(["HEPHAESTUS_DATA_DIR": notCreated.path, "HEPHAESTUS_MCP_PORT": "1"])
            }
            #expect(!FileManager.default.fileExists(atPath: notCreated.path))
        }
    }
}

@Suite("EngineConfiguration")
struct EngineConfigurationTests {
    struct FakeLauncher: ClaudeProcessLauncher {}

    @Test("The app configuration comes from the launch environment")
    func app() {
        let environment = LaunchEnvironment(mcpPort: 47830, debugTools: true, claudePath: "/opt/claude")
        let configuration = EngineConfiguration.app(environment: environment, appVersion: "0.4.0", build: 57,
                                                    homeDirectory: "/Users/example")
        #expect(configuration.dataDirectory.path == "/Users/example/Library/Application Support/HephaestusV2")
        #expect(configuration.mcpPort == 47830)
        #expect(configuration.syncPort == nil)
        #expect(configuration.syncInterface == .all)
        #expect(configuration.advertisesBonjour)
        #expect(configuration.debugTools)
        #expect(configuration.claudePath == "/opt/claude")
        #expect(configuration.appVersion == "0.4.0")
        #expect(configuration.build == 57)
        #expect(configuration.mcpPort(settings: HostSettings()) == 47830)
        #expect(configuration.syncPort(settings: HostSettings()) == 47821)
    }

    @Test("The test configuration")
    func test() {
        let configuration = EngineConfiguration.test(dataDirectory: URL(fileURLWithPath: "/tmp/x"), claudeLauncher: FakeLauncher())
        #expect(configuration.mcpPort == 0)
        #expect(configuration.syncPort == 0)
        #expect(configuration.syncInterface == .loopback)
        #expect(!configuration.advertisesBonjour)
        #expect(!configuration.debugTools)
        #expect(configuration.claudePath == nil)
        #expect(configuration.appVersion == "0.0.0")
        #expect(configuration.build == 0)
    }
}
