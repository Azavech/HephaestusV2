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

    /// The arguments shared by the build and the read of its settings.
    static func arguments(project: URL, scheme: String, buildFolder: URL) -> [String] {
        ["-project", project.path, "-scheme", scheme, "-configuration", "Debug",
         "-destination", "platform=macOS,arch=\(PreviewBuildRun.nativeArchitecture)",
         "-derivedDataPath", buildFolder.appendingPathComponent("DerivedData").path,
         "-clonedSourcePackagesDirPath", buildFolder.appendingPathComponent("SourcePackages").path,
         "ENABLE_TESTABILITY=YES", "ENABLE_DEBUG_DYLIB=YES", "CODE_SIGNING_ALLOWED=NO",
         "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-private-imports"]
    }

    /// `xcodebuild build`.
    static func build(project: URL, scheme: String, folder: URL, buildFolder: URL, environment: [String: String],
                      output: PreviewBuildOutput, track: (ChildProcess?) -> Void) async -> Bool {
        let (termination, _) = await PreviewBuildRun.run(["xcodebuild", "build"] + arguments(project: project, scheme: scheme, buildFolder: buildFolder),
                                                         environment: environment, directory: folder.path,
                                                         timeout: PreviewBuildRun.buildTimeout, output: output, track: track)
        return termination?.isSuccess == true
    }

    /// The build settings of the target, from `xcodebuild -showBuildSettings -json`.
    static func settings(target: String, project: URL, scheme: String, folder: URL, buildFolder: URL,
                         environment: [String: String], output: PreviewBuildOutput,
                         track: (ChildProcess?) -> Void) async -> [String: String]? {
        let (termination, data) = await PreviewBuildRun.run(["xcodebuild", "-showBuildSettings", "-json"]
                                                                + arguments(project: project, scheme: scheme, buildFolder: buildFolder),
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

    /// Writes the files of the host in `<build folder>/Host/` and compiles them with `swiftc`
    /// against the target's module; the host's executable.
    static func compileHost(target: XcodeProject.Target, settings: [String: String], buildFolder: URL, environment: [String: String],
                            output: PreviewBuildOutput, track: (ChildProcess?) -> Void) async -> URL? {
        guard let module = settings["PRODUCT_MODULE_NAME"], let targetBuildDir = settings["TARGET_BUILD_DIR"],
              let objects = settings["OBJECT_FILE_DIR_normal"] else {
            output.receive(Data("The build settings of \(target.name) have no module.\n".utf8))
            return nil
        }
        let architecture = PreviewBuildRun.nativeArchitecture
        let hostFolder = buildFolder.appendingPathComponent("Host")
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
                var thunk = scan.importStatements.filter { !$0.hasSuffix(" " + module) }.joined(separator: "\n") + "\n"
                thunk += "import SwiftUI\nimport AppKit\n"
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
            let deployment = settings["MACOSX_DEPLOYMENT_TARGET"] ?? "14.0"
            let builtProducts = settings["BUILT_PRODUCTS_DIR"] ?? targetBuildDir
            var arguments = ["swiftc", "-parse-as-library", "-module-name", "HephaestusPreviewHost", "-swift-version", swiftVersion,
                             "-target", "\(architecture)-apple-macos\(deployment)", "-Onone",
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
                arguments += ["-Xlinker", "-rpath", "-Xlinker", "@executable_path", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]
                executable = executableFolder.appendingPathComponent("HephaestusPreviewHost")
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
}
