import Foundation

/// The build of the previews of an Xcode project (docs/views.md › Xcode project): `xcodebuild`
/// builds the scheme of the target for macOS into a folder of `Runtime/previews/`, with a debug
/// dylib for an application and private imports, then `swiftc` compiles the preview host with the
/// code of the target's preview blocks, which import the target's module with access to its
/// private declarations, and links it to the debug dylib or the framework.
enum XcodePreviewBuild {
    /// The scheme that builds a target: the scheme of the target's name, else the first one.
    static func scheme(for target: String, project: URL, folder: URL, environment: [String: String],
                       output: PreviewBuildOutput, track: (ChildProcess?) -> Void) async -> String? {
        let (termination, data) = await PreviewBuildRun.run(["xcodebuild", "-list", "-json", "-project", project.path],
                                                            environment: environment, directory: folder.path,
                                                            timeout: PreviewBuildRun.readTimeout, output: output, track: track)
        guard termination?.isSuccess == true, let start = data.firstIndex(of: UInt8(ascii: "{")),
              let object = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let schemes = (object["project"] as? [String: Any])?["schemes"] as? [String], !schemes.isEmpty else { return nil }
        return schemes.contains(target) ? target : schemes[0]
    }

    /// The folder of the marked copies and of the overlay, in the build folder.
    static let marksFolder = "Marks"
    /// The overlay's file; its version changes with the form of the marks, so that the flags
    /// change and the target compiles again.
    static let overlayName = "overlay-1.json"

    static func overlay(_ buildFolder: URL) -> URL {
        buildFolder.appendingPathComponent(marksFolder).appendingPathComponent(overlayName)
    }

    /// The arguments shared by the build and the read of its settings: for macOS on this Mac's
    /// architecture, or for the iOS Simulator on this Mac's architecture only.
    static func arguments(project: URL, scheme: String, buildFolder: URL, platform: PreviewPlatform = .macOS) -> [String] {
        let architecture = PreviewBuildRun.nativeArchitecture
        var arguments = ["-project", project.path, "-scheme", scheme, "-configuration", "Debug"]
        switch platform {
        case .macOS:
            arguments += ["-destination", "platform=macOS,arch=\(architecture)"]
        case .iOS:
            arguments += ["-destination", "generic/platform=iOS Simulator", "ARCHS=\(architecture)", "ONLY_ACTIVE_ARCH=NO"]
        }
        return arguments + ["-derivedDataPath", buildFolder.appendingPathComponent("DerivedData").path,
                            "-clonedSourcePackagesDirPath", buildFolder.appendingPathComponent("SourcePackages").path,
                            "ENABLE_TESTABILITY=YES", "ENABLE_DEBUG_DYLIB=YES", "CODE_SIGNING_ALLOWED=NO",
                            "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-private-imports -vfsoverlay \"\(overlay(buildFolder).path)\""]
    }

    /// Writes a copy of each Swift file of the target that has elements, with its elements marked,
    /// and the VFS overlay that gives the compiler the copies in place of the files
    /// (docs/views.md › Xcode project). Copies that are no longer used are removed.
    static func writeMarks(target: XcodeProject.Target, buildFolder: URL, context: ViewElementContext) throws {
        let folder = buildFolder.appendingPathComponent(marksFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var roots: [[String: String]] = []
        var written: Set<String> = [overlayName]
        for file in sourceFiles(of: target) {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let marked = ViewElementScanner.marked(text, path: file.standardizedFileURL.path, context: context) else { continue }
            let name = "\(roots.count)-\(file.lastPathComponent)"
            let copy = folder.appendingPathComponent(name)
            try SwiftPackagePreviewBuild.writeIfChanged(marked, to: copy)
            written.insert(name)
            roots.append(["type": "file", "name": file.path, "external-contents": copy.path])
        }
        let overlay: [String: Any] = ["version": 0, "case-sensitive": "false", "roots": roots]
        let data = try JSONSerialization.data(withJSONObject: overlay, options: [.prettyPrinted, .sortedKeys])
        try SwiftPackagePreviewBuild.writeIfChanged(String(decoding: data, as: UTF8.self), to: folder.appendingPathComponent(overlayName))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !written.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// `xcodebuild build`.
    static func build(project: URL, scheme: String, folder: URL, buildFolder: URL, platform: PreviewPlatform = .macOS,
                      environment: [String: String], output: PreviewBuildOutput, track: (ChildProcess?) -> Void) async -> Bool {
        let (termination, _) = await PreviewBuildRun.run(["xcodebuild", "build"]
                                                            + arguments(project: project, scheme: scheme, buildFolder: buildFolder, platform: platform),
                                                         environment: environment, directory: folder.path,
                                                         timeout: PreviewBuildRun.buildTimeout, output: output, track: track)
        return termination?.isSuccess == true
    }

    /// The build settings of the target, from `xcodebuild -showBuildSettings -json`.
    static func settings(target: String, project: URL, scheme: String, folder: URL, buildFolder: URL, platform: PreviewPlatform = .macOS,
                         environment: [String: String], output: PreviewBuildOutput,
                         track: (ChildProcess?) -> Void) async -> [String: String]? {
        let (termination, data) = await PreviewBuildRun.run(["xcodebuild", "-showBuildSettings", "-json"]
                                                                + arguments(project: project, scheme: scheme, buildFolder: buildFolder,
                                                                            platform: platform),
                                                            environment: environment, directory: folder.path,
                                                            timeout: PreviewBuildRun.readTimeout, output: output, track: track)
        guard termination?.isSuccess == true, let start = data.firstIndex(of: UInt8(ascii: "[")),
              let list = try? JSONSerialization.jsonObject(with: data[start...]) as? [[String: Any]] else { return nil }
        let entry = list.first { $0["target"] as? String == target } ?? list.first
        return entry?["buildSettings"] as? [String: String]
    }

    /// The Swift files the target builds.
    static func sourceFiles(of target: XcodeProject.Target) -> [URL] {
        var paths = target.sourceFiles.filter { $0.hasSuffix(".swift") }
        for (folder, _) in target.synchronizedFolders {
            for found in ViewFinder.swiftFiles(under: URL(fileURLWithPath: folder)) where target.builds(found.url.path) {
                paths.insert(found.url.path)
            }
        }
        return paths.sorted().map { URL(fileURLWithPath: $0) }
    }

    /// Writes the files of the host in `<build folder>/Host/`, or `HostiOS/` for the iOS
    /// Simulator, and compiles them with `swiftc` against the target's module; the host's
    /// executable.
    static func compileHost(target: XcodeProject.Target, settings: [String: String], buildFolder: URL, platform: PreviewPlatform = .macOS,
                            environment: [String: String], output: PreviewBuildOutput, track: (ChildProcess?) -> Void) async -> URL? {
        guard let module = settings["PRODUCT_MODULE_NAME"], let targetBuildDir = settings["TARGET_BUILD_DIR"],
              let objects = settings["OBJECT_FILE_DIR_normal"] else {
            output.receive(Data("The build settings of \(target.name) have no module.\n".utf8))
            return nil
        }
        let architecture = PreviewBuildRun.nativeArchitecture
        let hostFolder = buildFolder.appendingPathComponent(platform == .macOS ? "Host" : "HostiOS")
        do {
            try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
            var files: [URL] = []
            var entries: [(key: String, function: String)] = []
            var number = 0
            for file in sourceFiles(of: target) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let scan = SwiftSourceScanner.scan(text)
                guard !scan.previews.isEmpty else { continue }
                let functions = PreviewHostSource.previewFunctions(file: number, scan: scan, text: text, path: file.path)
                // An import of the other platform's framework, in an `#if` of the file, is left out.
                var thunk = scan.importStatements.filter { !$0.hasSuffix(" " + module) }.map { statement in
                    guard let imported = Self.importedModule(statement) else { return statement }
                    return "#if canImport(\(imported))\n\(statement)\n#endif"
                }.joined(separator: "\n") + "\n"
                thunk += "import SwiftUI\n#if os(iOS)\nimport UIKit\n#else\nimport AppKit\n#endif\n"
                thunk += "@_private(sourceFile: \(PreviewHostSource.swiftStringLiteral(file.lastPathComponent))) import \(module)\n"
                let header = thunk.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                thunk += functions.code
                let thunkFile = hostFolder.appendingPathComponent("Previews\(number).swift")
                try SwiftPackagePreviewBuild.writeIfChanged(thunk, to: thunkFile)
                output.sourceMaps[thunkFile.standardizedFileURL.path] = PreviewSourceMap(
                    path: file.path, segments: functions.segments.map { PreviewSourceMap.Segment(line: $0.line + header, original: $0.original, count: $0.count) })
                files.append(thunkFile)
                entries += functions.entries
                number += 1
            }
            let hostFile = hostFolder.appendingPathComponent(PreviewHostSource.hostFileName)
            try SwiftPackagePreviewBuild.writeIfChanged(PreviewHostSource.hostFile(entries: entries), to: hostFile)
            files.append(hostFile)

            let swiftVersion = (settings["SWIFT_VERSION"] ?? "5").hasPrefix("6") ? "6" : "5"
            let builtProducts = settings["BUILT_PRODUCTS_DIR"] ?? targetBuildDir
            let triple = platform == .macOS
                ? "\(architecture)-apple-macos\(settings["MACOSX_DEPLOYMENT_TARGET"] ?? "14.0")"
                : "\(architecture)-apple-ios\(settings["IPHONEOS_DEPLOYMENT_TARGET"] ?? "15.0")-simulator"
            var arguments = ["swiftc", "-parse-as-library", "-module-name", "HephaestusPreviewHost", "-swift-version", swiftVersion,
                             "-target", triple, "-Onone",
                             "-I", objects + "/" + architecture, "-I", builtProducts, "-F", builtProducts]
            if let sdk = settings["SDKROOT"], sdk.hasPrefix("/") {
                arguments += ["-sdk", sdk]
            }
            arguments += files.map(\.path)
            let executable: URL
            if target.productType == "com.apple.product-type.application", let folder = settings["EXECUTABLE_FOLDER_PATH"],
               let name = settings["EXECUTABLE_NAME"] {
                let executableFolder = URL(fileURLWithPath: targetBuildDir).appendingPathComponent(folder)
                arguments.append(executableFolder.appendingPathComponent("\(name).debug.dylib").path)
                arguments += ["-Xlinker", "-rpath", "-Xlinker", "@executable_path", "-Xlinker", "-rpath", "-Xlinker",
                              platform == .macOS ? "@executable_path/../Frameworks" : "@executable_path/Frameworks"]
                // On iOS the host goes into a copy of the application (PreviewIOSApp).
                executable = platform == .macOS ? executableFolder.appendingPathComponent("HephaestusPreviewHost")
                    : hostFolder.appendingPathComponent("HephaestusPreviewHost")
            } else {
                arguments += ["-framework", settings["PRODUCT_NAME"] ?? module, "-Xlinker", "-rpath", "-Xlinker", targetBuildDir]
                executable = hostFolder.appendingPathComponent("HephaestusPreviewHost")
            }
            arguments += ["-Xlinker", "-rpath", "-Xlinker", builtProducts, "-o", executable.path]
            let (termination, _) = await PreviewBuildRun.run(arguments, environment: environment, directory: hostFolder.path,
                                                             timeout: PreviewBuildRun.buildTimeout, output: output, track: track)
            return termination?.isSuccess == true ? executable : nil
        } catch {
            output.receive(Data("\(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    /// The module of an `import` statement: `import struct Kit.Thing` → `Kit`.
    static func importedModule(_ statement: String) -> String? {
        let kinds: Set<String> = ["import", "struct", "class", "enum", "protocol", "typealias", "func", "var", "let", "actor"]
        let words = statement.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("@") && !kinds.contains($0) }
        guard let path = words.first, let module = path.split(separator: ".").first else { return nil }
        return String(module)
    }

    /// The app of the iOS host of a target: a copy of the application it built, or an empty app
    /// for a framework, with the host as its executable.
    static func makeIOSApp(target: XcodeProject.Target, settings: [String: String], executable: URL,
                           buildFolder: URL) throws -> (app: URL, bundleID: String) {
        var base: URL?
        if target.productType == "com.apple.product-type.application", let directory = settings["TARGET_BUILD_DIR"],
           let wrapper = settings["WRAPPER_NAME"] {
            base = URL(fileURLWithPath: directory).appendingPathComponent(wrapper)
        }
        let app = PreviewIOSApp.appFolder(buildFolder: buildFolder, target: target.name)
        let bundleID = PreviewIOSApp.bundleID(buildFolder: buildFolder, target: target.name)
        try PreviewIOSApp.make(at: app, executable: executable, base: base, resources: [], bundleID: bundleID)
        return (app, bundleID)
    }
}
