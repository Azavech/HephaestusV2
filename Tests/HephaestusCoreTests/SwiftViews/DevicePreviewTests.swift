import AppKit
import Foundation
import Testing
@testable import HephaestusCore

/// docs/views.md › Device previews: the platforms of a target, the checks of the devices of the
/// settings, and, with `PREVIEW_BUILD_TESTS=1` and an iOS Simulator runtime, a package's previews
/// on an iPhone and an iPad window with their sizes and size classes in both orientations, a tap,
/// typed keys and a scroll, and an Xcode project's iOS application. Serialized: two simulator
/// devices booting beside two builds overload the Mac.
@Suite("Device previews", .serialized)
struct DevicePreviewTests {
    static let iPhone = PreviewDeviceCatalog.builtIn.first { $0.name == "iPhone 18 Pro" }!
    static let iPadWindow = PreviewDeviceCatalog.builtIn.first { $0.name == "iPad Pro 11-inch (M5) · 1/3 window" }!

    @Test("A package's platforms: those its manifest lists, both when it lists neither")
    func packagePlatforms() {
        func platforms(_ json: String) -> Set<PreviewPlatform> {
            PackageTarget.platforms(describe: Data(json.utf8))
        }
        #expect(platforms(#"{"targets": []}"#) == [.macOS, .iOS])
        #expect(platforms(#"{"platforms": [{"name": "macos", "version": "14.0"}]}"#) == [.macOS])
        #expect(platforms(#"{"platforms": [{"name": "ios", "version": "17.0"}]}"#) == [.iOS])
        #expect(platforms(#"{"platforms": [{"name": "ios", "version": "17.0"}, {"name": "macos", "version": "14.0"}]}"#) == [.macOS, .iOS])
        #expect(platforms(#"{"platforms": [{"name": "tvos", "version": "17.0"}]}"#) == [.macOS, .iOS])
    }

    @Test("An Xcode target's platforms: SUPPORTED_PLATFORMS, else SDKROOT, the target's before the project's, else macOS")
    func xcodePlatforms() {
        #expect(XcodeProject.platforms([:], projectSettings: [:]) == [.macOS])
        #expect(XcodeProject.platforms(["SDKROOT": "iphoneos"], projectSettings: ["SDKROOT": "macosx"]) == [.iOS])
        #expect(XcodeProject.platforms([:], projectSettings: ["SDKROOT": "iphoneos"]) == [.iOS])
        #expect(XcodeProject.platforms(["SDKROOT": "auto", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx"],
                                       projectSettings: [:]) == [.macOS, .iOS])
        #expect(XcodeProject.platforms(["SUPPORTED_PLATFORMS": "macosx"], projectSettings: ["SDKROOT": "iphoneos"]) == [.macOS])
    }

    @Test("A device of the settings is checked: its rules, and names listed once")
    func settingsDevices() throws {
        try Engine.checkPreviewSettings(PreviewSettings(devices: [Self.iPhone, Self.iPadWindow]))
        var wide = Self.iPhone
        wide.width = 2001
        #expect(throws: EngineError.self) { try Engine.checkPreviewSettings(PreviewSettings(devices: [wide])) }
        #expect(throws: EngineError.self) { try Engine.checkPreviewSettings(PreviewSettings(devices: [Self.iPhone, Self.iPhone])) }
        do {
            try Engine.checkPreviewSettings(PreviewSettings(devices: [wide]))
        } catch let error as EngineError {
            #expect(error.message == "settings.devices: iPhone 18 Pro: width: use 50 to 2000 points.")
        }
    }

    @Test("Settings without orientation and devices, from a window of an earlier version, read as portrait without device")
    func earlierSettings() throws {
        let json = #"{"width": 400, "height": 300, "appearance": "light", "dynamicTypeSize": "large"}"#
        let settings = try JSONDecoder().decode(PreviewSettings.self, from: Data(json.utf8))
        #expect(settings.orientation == .portrait)
        #expect(settings.devices.isEmpty)
    }

    @Test("A device window command has the device's size and size classes in the orientation, its idiom and its scale")
    func deviceCommand() {
        let portrait = PreviewHost.Command.open(window: "w", preview: "p", settings: PreviewSettings(), device: Self.iPhone)
        #expect(portrait.width == 402 && portrait.height == 874)
        #expect(portrait.horizontalSizeClass == "compact" && portrait.verticalSizeClass == "regular")
        #expect(portrait.idiom == "phone" && portrait.scale == 3)
        let landscape = PreviewHost.Command.update(window: "w", settings: PreviewSettings(orientation: .landscape), device: Self.iPadWindow)
        #expect(landscape.width == 834 && landscape.height == 375)
        #expect(landscape.horizontalSizeClass == "compact" && landscape.verticalSizeClass == "regular")
        #expect(landscape.idiom == "pad" && landscape.scale == 2)
    }

    // MARK: Builds

    static let manifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Phone",
        platforms: [.iOS(.v17), .macOS(.v14)],
        targets: [.target(name: "Phone")]
    )
    """

    /// A view that paints its size classes: its left half red for a compact width and green for a
    /// regular one, its right half blue for a compact height and yellow for a regular one.
    static let view = """
    import SwiftUI

    struct SizeClasses: View {
        #if os(iOS)
        @Environment(\\.horizontalSizeClass) private var horizontal
        @Environment(\\.verticalSizeClass) private var vertical
        #endif

        var body: some View {
            HStack(spacing: 0) {
                #if os(iOS)
                (horizontal == .compact ? Color.red : Color.green)
                (vertical == .compact ? Color.blue : Color.yellow)
                #else
                Color.gray
                #endif
            }
        }
    }

    #Preview("Classes") {
        SizeClasses()
    }
    """

    /// A view that turns its top band blue once `ok` is typed in it, its button green once tapped,
    /// and shows purple under its scroll view's orange top once scrolled.
    static let interactive = """
    import SwiftUI

    struct Interactive: View {
        @State private var tapped = false
        @State private var text = ""

        var body: some View {
            VStack(spacing: 0) {
                TextField("Type", text: $text)
                    .frame(height: 60)
                    .background(text == "ok" ? Color.blue : Color.white)
                Button {
                    tapped = true
                } label: {
                    (tapped ? Color.green : Color.red).frame(height: 200)
                }
                .buttonStyle(.plain)
                ScrollView {
                    VStack(spacing: 0) {
                        Color.orange.frame(height: 300)
                        Color.purple.frame(height: 2000)
                    }
                }
            }
        }
    }

    #Preview("Interactive") {
        Interactive()
    }
    """

    /// A button that presents a cyan sheet.
    static let presenting = """
    import SwiftUI

    struct Presenting: View {
        @State private var shows = false

        var body: some View {
            Button {
                shows = true
            } label: {
                Color.red
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $shows) {
                Color.cyan
            }
        }
    }

    #Preview("Presenting") {
        Presenting()
    }
    """

    /// The colour of a pixel of a PNG, as red, green and blue from 0 to 255.
    static func color(_ base64: String, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let data = Data(base64Encoded: base64), let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    /// The last image of each preview, by index and device.
    struct Images {
        var png: [String: String] = [:]
        var size: [String: (Int, Int)] = [:]

        static func key(_ frame: PreviewFrame) -> String {
            "\(frame.index)/\(frame.device ?? "Mac")"
        }
    }

    static func poll(_ connection: LocalEngineConnection, _ session: UUID, after: inout Int, images: inout Images,
                     limit: Duration = .seconds(600), sourceLocation: SourceLocation = #_sourceLocation,
                     until condition: (PreviewStatus, Images) -> Bool) async throws -> PreviewStatus {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let status = try await connection.call(PreviewsPoll.self, .init(sessionID: session, after: after))
            after = status.sequence
            for frame in status.previews {
                if let png = frame.pngBase64 {
                    images.png[Images.key(frame)] = png
                    images.size[Images.key(frame)] = (frame.width, frame.height)
                }
            }
            if condition(status, images) { return status }
            if status.state == .buildFailed || status.state == .stopped {
                Issue.record("The previews failed: \(status.messages)", sourceLocation: sourceLocation)
                return status
            }
        }
        Issue.record("The previews did not reach the expected state in time.", sourceLocation: sourceLocation)
        return try await connection.call(PreviewsPoll.self, .init(sessionID: session, after: 0))
    }

    @Test("A package's previews show on the Mac and on the checked devices, with each device's size and size classes, in both orientations",
          .enabled(if: PreviewMethodsTests.runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(20)))
    func devicePreviews() async throws {
        try await withTestEngine { engine, connection, folder in
            await engine.useLoginEnvironment(ProcessInfo.processInfo.environment)
            let root = folder.appendingPathComponent("Phone")
            for (path, text) in ["Package.swift": Self.manifest, "Sources/Phone/SizeClasses.swift": Self.view,
                                 "Sources/Phone/Interactive.swift": Self.interactive, "Sources/Phone/Presenting.swift": Self.presenting] {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try await connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "Phone", identifier: "PHONE",
                                                                     type: .swiftApplication, createDirectory: false))
            var settings = PreviewSettings(width: 100, height: 60, devices: [Self.iPhone, Self.iPadWindow])
            let session = try await connection.call(PreviewsStart.self, .init(projectID: "PHONE", path: "Sources/Phone/SizeClasses.swift",
                                                                               name: "SizeClasses", settings: settings))
            var after = 0
            var images = Images()
            let running = try await Self.poll(connection, session.sessionID, after: &after, images: &images) { status, images in
                status.state == .running && images.png.count == 3
            }
            #expect(running.previews.map { $0.device ?? "Mac" } == ["Mac", Self.iPhone.name, Self.iPadWindow.name])
            #expect(images.size["0/Mac"]! == (200, 120))
            #expect(images.size["0/\(Self.iPhone.name)"]! == (804, 1748))
            #expect(images.size["0/\(Self.iPadWindow.name)"]! == (750, 1668))
            // Portrait iPhone and iPad window: compact width (red), regular height (yellow).
            for name in [Self.iPhone.name, Self.iPadWindow.name] {
                let png = images.png["0/\(name)"]!
                let (width, height) = images.size["0/\(name)"]!
                let left = Self.color(png, x: width / 4, y: height / 2), right = Self.color(png, x: width * 3 / 4, y: height / 2)
                #expect(left.map { $0.0 > 200 && $0.1 < 100 } == true, "\(name): \(String(describing: left))")
                #expect(right.map { $0.0 > 200 && $0.1 > 150 && $0.2 < 100 } == true, "\(name): \(String(describing: right))")
            }

            // Landscape: the iPhone has a compact height (blue), the window keeps its classes; the
            // sizes swap.
            settings.orientation = .landscape
            images = Images()
            _ = try await connection.call(PreviewsUpdate.self, .init(sessionID: session.sessionID, settings: settings))
            _ = try await Self.poll(connection, session.sessionID, after: &after, images: &images, limit: .seconds(60)) { _, images in
                images.size["0/\(Self.iPhone.name)"].map { $0 == (1748, 804) } == true
                    && images.size["0/\(Self.iPadWindow.name)"].map { $0 == (1668, 750) } == true
            }
            let phone = images.png["0/\(Self.iPhone.name)"]!
            let right = Self.color(phone, x: 1748 * 3 / 4, y: 402)
            #expect(right.map { $0.2 > 200 && $0.0 < 100 } == true, "\(String(describing: right))")

            // Unchecking the iPad window removes its preview.
            settings.devices = [Self.iPhone]
            _ = try await connection.call(PreviewsUpdate.self, .init(sessionID: session.sessionID, settings: settings))
            let status = try await connection.call(PreviewsPoll.self, .init(sessionID: session.sessionID, after: 0))
            #expect(status.previews.map { $0.device ?? "Mac" } == ["Mac", Self.iPhone.name])
            #expect(await engineError {
                try await connection.call(PreviewsInput.self, .init(sessionID: session.sessionID, preview: 0, device: Self.iPadWindow.name,
                                                                     event: PreviewInputEvent(kind: .mouseDown, x: 1, y: 1)))
            }?.code == .invalid)
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: session.sessionID))

            // A tap, typed keys and a scroll reach the view on the device.
            let input = try await connection.call(PreviewsStart.self, .init(projectID: "PHONE", path: "Sources/Phone/Interactive.swift",
                                                                             name: "Interactive", settings: PreviewSettings(devices: [Self.iPhone])))
            var inputAfter = 0
            var inputImages = Images()
            let key = "0/\(Self.iPhone.name)"
            func pixel(_ images: Images, _ x: Int, _ y: Int) -> (Int, Int, Int)? {
                images.png[key].flatMap { Self.color($0, x: x * 2, y: y * 2) }
            }
            _ = try await Self.poll(connection, input.sessionID, after: &inputAfter, images: &inputImages, limit: .seconds(120)) { status, images in
                status.state == .running && pixel(images, 200, 160).map { $0.0 > 200 && $0.1 < 100 } == true
            }
            func send(_ event: PreviewInputEvent) async throws {
                _ = try await connection.call(PreviewsInput.self, .init(sessionID: input.sessionID, preview: 0, device: Self.iPhone.name, event: event))
            }
            try await send(PreviewInputEvent(kind: .mouseDown, x: 200, y: 160, clickCount: 1))
            try await send(PreviewInputEvent(kind: .mouseUp, x: 200, y: 160, clickCount: 1))
            _ = try await Self.poll(connection, input.sessionID, after: &inputAfter, images: &inputImages, limit: .seconds(30)) { _, images in
                pixel(images, 200, 160).map { $0.1 > 150 && $0.0 < 150 } == true
            }
            try await send(PreviewInputEvent(kind: .mouseDown, x: 200, y: 30, clickCount: 1))
            try await send(PreviewInputEvent(kind: .mouseUp, x: 200, y: 30, clickCount: 1))
            try await Task.sleep(for: .milliseconds(500))
            for character in ["o", "k"] {
                try await send(PreviewInputEvent(kind: .keyDown, characters: character, charactersIgnoringModifiers: character,
                                                 keyCode: character == "o" ? 31 : 40))
                try await send(PreviewInputEvent(kind: .keyUp, characters: character, charactersIgnoringModifiers: character,
                                                 keyCode: character == "o" ? 31 : 40))
            }
            _ = try await Self.poll(connection, input.sessionID, after: &inputAfter, images: &inputImages, limit: .seconds(30)) { _, images in
                pixel(images, 300, 30).map { $0.2 > 200 && $0.0 < 100 } == true
            }
            #expect(pixel(inputImages, 200, 400).map { $0.0 > 200 && $0.1 > 100 } == true, "orange before the scroll")
            try await send(PreviewInputEvent(kind: .scroll, x: 200, y: 400, deltaX: 0, deltaY: -400))
            _ = try await Self.poll(connection, input.sessionID, after: &inputAfter, images: &inputImages, limit: .seconds(30)) { _, images in
                pixel(images, 200, 400).map { $0.0 > 120 && $0.1 < 120 && $0.2 > 180 } == true
            }
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: input.sessionID))

            // A sheet that the view presents shows in its preview.
            let sheet = try await connection.call(PreviewsStart.self, .init(projectID: "PHONE", path: "Sources/Phone/Presenting.swift",
                                                                             name: "Presenting", settings: PreviewSettings(devices: [Self.iPhone])))
            var sheetAfter = 0
            var sheetImages = Images()
            _ = try await Self.poll(connection, sheet.sessionID, after: &sheetAfter, images: &sheetImages, limit: .seconds(120)) { status, images in
                status.state == .running && pixel(images, 200, 600).map { $0.0 > 200 && $0.1 < 120 } == true
            }
            _ = try await connection.call(PreviewsInput.self, .init(sessionID: sheet.sessionID, preview: 0, device: Self.iPhone.name,
                                                                     event: PreviewInputEvent(kind: .mouseDown, x: 200, y: 600, clickCount: 1)))
            _ = try await connection.call(PreviewsInput.self, .init(sessionID: sheet.sessionID, preview: 0, device: Self.iPhone.name,
                                                                     event: PreviewInputEvent(kind: .mouseUp, x: 200, y: 600, clickCount: 1)))
            _ = try await Self.poll(connection, sheet.sessionID, after: &sheetAfter, images: &sheetImages, limit: .seconds(30)) { _, images in
                pixel(images, 200, 600).map { $0.0 < 150 && $0.1 > 150 && $0.2 > 200 } == true
            }
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: sheet.sessionID))
        }
    }

    /// The Xcode project of the HEPH-162 tests made an iOS application: its SDK is `iphoneos`.
    static var iOSXcodeProject: String {
        PreviewMethodsTests.xcodeProject
            .replacingOccurrences(of: "MACOSX_DEPLOYMENT_TARGET = 14.0;", with: "IPHONEOS_DEPLOYMENT_TARGET = 17.0;\n\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";")
            .replacingOccurrences(of: "SDKROOT = macosx;", with: "SDKROOT = iphoneos;")
    }

    @Test("An iOS application of an Xcode project shows its previews on the devices only, its private declarations reached",
          .enabled(if: PreviewMethodsTests.runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(20)))
    func xcodeDevicePreviews() async throws {
        try await withTestEngine { engine, connection, folder in
            await engine.useLoginEnvironment(ProcessInfo.processInfo.environment)
            let root = folder.appendingPathComponent("XApp")
            let files = [
                "XApp.xcodeproj/project.pbxproj": Self.iOSXcodeProject,
                "XApp/XAppApp.swift": "import SwiftUI\n\n@main\nstruct XAppApp: App {\n    var body: some Scene { WindowGroup { ContentView() } }\n}\n",
                "XApp/ContentView.swift": """
                import SwiftUI
                import UIKit

                struct ContentView: View {
                    var body: some View { Color(uiColor: secret) }
                }

                private let secret = UIColor.systemGreen

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
            let session = try await connection.call(PreviewsStart.self, .init(projectID: "XAPP", path: "XApp/ContentView.swift",
                                                                               name: "ContentView",
                                                                               settings: PreviewSettings(devices: [Self.iPhone])))
            var after = 0
            var images = Images()
            let status = try await Self.poll(connection, session.sessionID, after: &after, images: &images) { status, images in
                status.state == .running && images.png.count == 1
            }
            #expect(status.previews.map { $0.device ?? "Mac" } == [Self.iPhone.name])
            let png = try #require(images.png["0/\(Self.iPhone.name)"])
            #expect(images.size["0/\(Self.iPhone.name)"]! == (804, 1748))
            let center = Self.color(png, x: 402, y: 874)
            #expect(center.map { $0.1 > 150 && $0.0 < 150 } == true, "\(String(describing: center))")
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: session.sessionID))
        }
    }

    @Test("A package for both platforms whose code is the Mac's runs its Mac previews; the iOS errors come after the line iOS:",
          .enabled(if: PreviewMethodsTests.runsBuilds, "Set PREVIEW_BUILD_TESTS=1 to build previews"), .timeLimit(.minutes(10)))
    func failedPlatform() async throws {
        try await withTestEngine { engine, connection, folder in
            await engine.useLoginEnvironment(ProcessInfo.processInfo.environment)
            let root = folder.appendingPathComponent("MacOnly")
            let files = [
                "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription

                let package = Package(name: "MacOnly", platforms: [.macOS(.v14), .iOS(.v17)], targets: [.target(name: "MacOnly")])
                """,
                "Sources/MacOnly/Panel.swift": """
                import AppKit
                import SwiftUI

                struct Panel: View {
                    var body: some View { Color(nsColor: .systemGreen) }
                }

                #Preview { Panel() }
                """,
            ]
            for (path, text) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try await connection.call(ProjectsCreate.self, .init(rootPath: root.path, name: "MacOnly", identifier: "MACONLY",
                                                                     type: .swiftApplication, createDirectory: false))
            let session = try await connection.call(PreviewsStart.self, .init(projectID: "MACONLY", path: "Sources/MacOnly/Panel.swift",
                                                                               name: "Panel", settings: PreviewSettings(width: 100, height: 60,
                                                                                                                          devices: [Self.iPhone])))
            var after = 0
            var images = Images()
            let status = try await Self.poll(connection, session.sessionID, after: &after, images: &images, limit: .seconds(300)) { status, images in
                status.state == .running && images.png["0/Mac"] != nil && !status.messages.isEmpty
            }
            #expect(status.previews.map { $0.device ?? "Mac" } == ["Mac"])
            #expect(status.messages.first == "iOS:")
            #expect(status.messages.contains { $0.contains(": error: ") }, "\(status.messages)")
            _ = try await connection.call(PreviewsStop.self, .init(sessionID: session.sessionID))
        }
    }
}
