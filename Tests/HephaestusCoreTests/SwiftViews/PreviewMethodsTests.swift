import Foundation
import Testing
@testable import HephaestusCore

extension Engine {
    /// The login-shell environment of the child processes, which the inert CLI lookup of the test
    /// engines never captures.
    func useLoginEnvironment(_ environment: [String: String]) {
        claudeCLI.loginEnvironment = environment
    }
}

/// docs/engine-api.md › Views and previews: `views.list` on a project and its sub project, the
/// checks of `previews.start`, and a Swift package whose previews build, run, follow the settings
/// and show the compiler's errors.
@Suite("Views and previews methods")
struct PreviewMethodsTests {
    /// The tests that build previews run with `PREVIEW_BUILD_TESTS=1` only (docs/development.md ›
    /// Test rules, rule 12).
    static let runsBuilds = ProcessInfo.processInfo.environment["PREVIEW_BUILD_TESTS"] == "1"

    static let manifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Demo",
        platforms: [.macOS(.v14)],
        targets: [.target(name: "Demo")]
    )
    """

    static func view(_ greeting: String) -> String {
        """
        import SwiftUI

        struct Greeting: View {
            var text: String
            var body: some View {
                Text(text).padding()
            }
        }

        private let sample = "\(greeting)"

        #Preview("Hello") {
            Greeting(text: sample)
        }

        #Preview {
            @Previewable @State var count = 2
            Greeting(text: "\\(count)")
        }
        """
    }

    static let canvas = """
    import AppKit

    final class Canvas: NSView {}
    """

    /// A Swift package registered as the Swift application `DEMO`, with the sub project `KIT`.
    static func makeProject(_ connection: LocalEngineConnection, in folder: URL) async throws -> URL {
        let root = folder.appendingPathComponent("Demo")
        let files = [
            "Package.swift": manifest,
            "Sources/Demo/Greeting.swift": view("Hi"),
            "Sources/Demo/Canvas.swift": canvas,
            "Kit/Sources/Kit/KitView.swift": "import SwiftUI\nstruct KitView: View { var body: some View { EmptyView() } }\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        _ = try await connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "Demo", identifier: "DEMO",
                                                                 type: .swiftApplication, createDirectory: false))
        _ = try await connection.call(ProjectsCreate.self, .init(rootPath: root.appendingPathComponent("Kit").path, name: "Kit",
                                                                 identifier: "KIT", parentID: "DEMO", createDirectory: false))
        return root
    }

    @Test("views.list gives the views of the project with its sub project's, and of the sub project alone")
    func list() async throws {
        try await withTestEngine { _, connection, folder in
            _ = try await Self.makeProject(connection, in: folder)
            let views = try await connection.call(ViewsList.self, .init(projectID: "DEMO"))
            #expect(views.map { "\($0.path):\($0.name)" } == ["Kit/Sources/Kit/KitView.swift:KitView", "Sources/Demo/Canvas.swift:Canvas",
                                                               "Sources/Demo/Greeting.swift:Greeting"])
            #expect(views.last?.previews == [ViewPreview(name: "Hello", line: 12), ViewPreview(line: 16)])
            let kit = try await connection.call(ViewsList.self, .init(projectID: "KIT"))
            #expect(kit.map(\.path) == ["Sources/Kit/KitView.swift"])
            #expect(await engineError { try await connection.call(ViewsList.self, .init(projectID: "NOPE")) }
                == EngineError(.notFound, "Project NOPE not found."))
        }
    }

    @Test("previews.start checks the file, the view, its previews and the settings; the other methods check the session")
    func checks() async throws {
        try await withTestEngine { _, connection, folder in
            _ = try await Self.makeProject(connection, in: folder)
            func start(_ path: String, _ name: String, width: Int = 400) async -> EngineError? {
                await engineError {
                    try await connection.call(PreviewsStart.self, .init(projectID: "DEMO", path: path, name: name,
                                                                         settings: PreviewSettings(width: width)))
                }
            }
            #expect(await start("Sources/Demo/None.swift", "Greeting") == EngineError(.notFound, "File Sources/Demo/None.swift not found."))
            #expect(await start("Sources/Demo/Greeting.swift", "Other") == EngineError(.notFound, "View Other not found in Sources/Demo/Greeting.swift."))
            #expect(await start("Sources/Demo/Canvas.swift", "Canvas") == EngineError(.invalid, "Canvas has no #Preview."))
            #expect(await start("Sources/Demo/Greeting.swift", "Greeting", width: 10) == EngineError(.invalid, "settings.width: use 50 to 2000 points."))
            let unknown = UUID()
            #expect(await engineError { try await connection.call(PreviewsPoll.self, .init(sessionID: unknown, after: 0)) }
                == EngineError(.notFound, "Preview session \(unknown.uuidString) not found."))
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: unknown))
        }
    }

    /// Polls until `condition` holds, at most `limit`.
    static func poll(_ connection: LocalEngineConnection, _ session: UUID, after: inout Int, limit: Duration = .seconds(240),
                     until condition: (PreviewStatus, [Int: (width: Int, height: Int)]) -> Bool) async throws -> PreviewStatus {
        let deadline = ContinuousClock.now + limit
        var sizes: [Int: (width: Int, height: Int)] = [:]
        while ContinuousClock.now < deadline {
            let status = try await connection.call(PreviewsPoll.self, .init(sessionID: session, after: after))
            after = status.sequence
            for frame in status.previews where frame.pngBase64 != nil {
                sizes[frame.index] = (frame.width, frame.height)
            }
            if condition(status, sizes) { return status }
        }
        Issue.record("The previews did not reach the expected state in time.")
        return try await connection.call(PreviewsPoll.self, .init(sessionID: session, after: 0))
    }

    @Test("A Swift package's previews build in the background, run, follow the settings and show the compiler's errors",
          .enabled(if: runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(10)))
    func swiftPackage() async throws {
        try await withTestEngine { engine, connection, folder in
            await engine.useLoginEnvironment(ProcessInfo.processInfo.environment)
            let root = try await Self.makeProject(connection, in: folder)
            let session = try await connection.call(PreviewsStart.self, .init(projectID: "DEMO", path: "Sources/Demo/Greeting.swift",
                                                                               name: "Greeting", settings: PreviewSettings(width: 200, height: 100)))
            var after = 0
            let running = try await Self.poll(connection, session.sessionID, after: &after) { status, sizes in
                status.state == .running && sizes.count == 2
            }
            #expect(running.previews.map(\.title) == ["Hello", "Preview 2"])
            #expect(running.previews.allSatisfy { $0.width == 400 && $0.height == 200 })
            #expect(running.builtAt != nil)

            _ = try await connection.call(PreviewsUpdate.self, .init(sessionID: session.sessionID,
                                                                      settings: PreviewSettings(width: 300, height: 120, appearance: .dark)))
            _ = try await Self.poll(connection, session.sessionID, after: &after) { _, sizes in
                sizes.values.allSatisfy { $0.width == 600 && $0.height == 240 } && sizes.count == 2
            }

            // A save with a syntax error: the build fails with the compiler's error, by project path.
            try (Self.view("Hi") + "\n}}}\n").write(to: root.appendingPathComponent("Sources/Demo/Greeting.swift"), atomically: true, encoding: .utf8)
            await engine.previewFilesChanged(rootPath: root.standardizedFileURL.path, paths: ["Sources/Demo/Greeting.swift"])
            let failed = try await Self.poll(connection, session.sessionID, after: &after) { status, _ in status.state == .buildFailed }
            #expect(failed.messages.contains { $0.hasPrefix("Sources/Demo/Greeting.swift:") && $0.contains(": error: ") }, "\(failed.messages)")

            // Fixed again: the previews run again.
            try Self.view("Hello again").write(to: root.appendingPathComponent("Sources/Demo/Greeting.swift"), atomically: true, encoding: .utf8)
            await engine.previewFilesChanged(rootPath: root.standardizedFileURL.path, paths: ["Sources/Demo/Greeting.swift"])
            _ = try await Self.poll(connection, session.sessionID, after: &after) { status, _ in status.state == .running }

            _ = try await connection.call(PreviewsStop.self, .init(sessionID: session.sessionID))
            #expect(await engineError { try await connection.call(PreviewsPoll.self, .init(sessionID: session.sessionID, after: 0)) }?.code == .notFound)
        }
    }
}

extension PreviewMethodsTests {
    /// A macOS SwiftUI application of a hand-written Xcode project whose target synchronizes the
    /// folder `XApp`.
    static let xcodeProject = #"""
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

		AA0000000000000000000006 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = XApp.app; sourceTree = BUILT_PRODUCTS_DIR; };

		AA0000000000000000000005 = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = XApp;
			sourceTree = "<group>";
		};

		AA0000000000000000000013 = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};

		AA0000000000000000000003 = {
			isa = PBXGroup;
			children = (
				AA0000000000000000000005,
				AA0000000000000000000004,
			);
			sourceTree = "<group>";
		};
		AA0000000000000000000004 = {
			isa = PBXGroup;
			children = (
				AA0000000000000000000006,
			);
			name = Products;
			sourceTree = "<group>";
		};

		AA0000000000000000000010 = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA0000000000000000000011;
			buildPhases = (
				AA0000000000000000000012,
				AA0000000000000000000013,
				AA0000000000000000000014,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				AA0000000000000000000005,
			);
			name = XApp;
			packageProductDependencies = (
			);
			productName = XApp;
			productReference = AA0000000000000000000006;
			productType = "com.apple.product-type.application";
		};

		AA0000000000000000000001 = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
			};
			buildConfigurationList = AA0000000000000000000002;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = AA0000000000000000000003;
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = AA0000000000000000000004;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				AA0000000000000000000010,
			);
		};

		AA0000000000000000000014 = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};

		AA0000000000000000000012 = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};

		AA0000000000000000000020 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ENABLE_TESTABILITY = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		AA0000000000000000000021 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
			};
			name = Release;
		};
		AA0000000000000000000022 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = "";
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.XApp;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		AA0000000000000000000023 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = "";
				CODE_SIGN_STYLE = Automatic;
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.XApp;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};

		AA0000000000000000000002 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000020,
				AA0000000000000000000021,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		AA0000000000000000000011 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000022,
				AA0000000000000000000023,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
	};
	rootObject = AA0000000000000000000001;
}

"""#

    @Test("An Xcode project's previews build with xcodebuild, reach the target's private declarations and run",
          .enabled(if: runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(10)))
    func xcodeProjectPreviews() async throws {
        try await withTestEngine { engine, connection, folder in
            await engine.useLoginEnvironment(ProcessInfo.processInfo.environment)
            let root = folder.appendingPathComponent("XApp")
            let files = [
                "XApp.xcodeproj/project.pbxproj": Self.xcodeProject,
                "XApp/XAppApp.swift": "import SwiftUI\n\n@main\nstruct XAppApp: App {\n    var body: some Scene { WindowGroup { ContentView() } }\n}\n",
                "XApp/ContentView.swift": """
                import SwiftUI

                struct ContentView: View {
                    var body: some View { Text(secret).padding() }
                }

                private let secret = "private value"

                #Preview("Main") {
                    ContentView()
                }
                """,
            ]
            for (path, text) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try await connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "XApp", identifier: "XAPP",
                                                                     type: .swiftApplication, createDirectory: false))
            let views = try await connection.call(ViewsList.self, .init(projectID: "XAPP"))
            #expect(views.map(\.name) == ["ContentView"])
            let session = try await connection.call(PreviewsStart.self, .init(projectID: "XAPP", path: "XApp/ContentView.swift",
                                                                               name: "ContentView", settings: PreviewSettings(width: 160, height: 80)))
            var after = 0
            let status = try await Self.poll(connection, session.sessionID, after: &after) { status, sizes in
                (status.state == .running && sizes.count == 1) || status.state == .buildFailed || status.state == .stopped
            }
            #expect(status.state == .running, "\(status.messages)")
            #expect(status.previews.map(\.title) == ["Main"])
            #expect(status.previews.first?.width == 320)
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: session.sessionID))
        }
    }
}
