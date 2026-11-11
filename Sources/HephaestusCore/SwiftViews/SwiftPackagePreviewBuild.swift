import Foundation

/// The build of the previews of a Swift package (docs/views.md › Swift package): a build folder in
/// `Runtime/previews/` with a copy of the package's manifest, a link to each of its other entries,
/// and one preview host target per target previewed, whose folder copies the target's files with
/// the code of their preview blocks and the host's file. The package's own folder is only read.
enum SwiftPackagePreviewBuild {
    /// The folder of the host targets' copies, in the build folder.
    static let hostsFolder = "HephaestusPreviewHosts"
    /// The entries of the package that are not linked into the build folder.
    static let unlinkedEntries: Set<String> = ["Package.swift", "Package.resolved", ".build", ".swiftpm", ".git", ".hephaestus", hostsFolder]

    /// The name of the host target of a target.
    static func hostTargetName(_ target: String) -> String {
        "HephaestusPreviewHost" + target.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
    }

    /// The code added after the package's manifest: one executable target per target previewed,
    /// with its dependencies, sources, resources and settings, and its module's name, so that the
    /// code that names its own module compiles.
    static func manifestAddition(hostTargets: [PackageTarget]) -> String {
        guard !hostTargets.isEmpty else { return "" }
        let triples = hostTargets.map { target in
            "(" + [target.name, hostTargetName(target.name), target.moduleName].map(PreviewHostSource.swiftStringLiteral).joined(separator: ", ") + ")"
        }
        return """


        // Added by HephaestusV2 to build the previews of the Views section.
        for (__hephaestusName, __hephaestusHost, __hephaestusModule) in [\(triples.joined(separator: ", "))] {
            if let __hephaestusTarget = package.targets.first(where: { $0.name == __hephaestusName }) {
                package.targets.append(.executableTarget(
                    name: __hephaestusHost,
                    dependencies: __hephaestusTarget.dependencies,
                    path: "\(hostsFolder)/" + __hephaestusName,
                    exclude: __hephaestusTarget.exclude,
                    sources: __hephaestusTarget.sources.map { $0 + [\(PreviewHostSource.swiftStringLiteral(PreviewHostSource.hostFileName))] },
                    resources: __hephaestusTarget.resources,
                    swiftSettings: (__hephaestusTarget.swiftSettings ?? []) + [.unsafeFlags(["-module-name", __hephaestusModule])],
                    linkerSettings: __hephaestusTarget.linkerSettings,
                    plugins: __hephaestusTarget.plugins
                ))
            }
        }

        """
    }

    /// Writes the manifest, `Package.resolved` and the links of the build folder, and removes the
    /// links of entries the package no longer has.
    static func prepareFolder(package: URL, buildFolder: URL, hostTargets: [PackageTarget]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: buildFolder, withIntermediateDirectories: true)
        let manifest = try String(contentsOf: package.appendingPathComponent("Package.swift"), encoding: .utf8)
        try writeIfChanged(manifest + manifestAddition(hostTargets: hostTargets), to: buildFolder.appendingPathComponent("Package.swift"))
        let resolved = package.appendingPathComponent("Package.resolved")
        if let text = try? String(contentsOf: resolved, encoding: .utf8) {
            try writeIfChanged(text, to: buildFolder.appendingPathComponent("Package.resolved"))
        }
        let entries = try manager.contentsOfDirectory(atPath: package.path).filter { name in
            // A versioned manifest would replace the copy of Package.swift.
            !unlinkedEntries.contains(name) && !(name.hasPrefix("Package@swift") && name.hasSuffix(".swift")) && name != ".DS_Store"
        }
        for name in entries {
            let link = buildFolder.appendingPathComponent(name)
            let destination = package.appendingPathComponent(name).path
            if let current = try? manager.destinationOfSymbolicLink(atPath: link.path) {
                if current == destination { continue }
                try manager.removeItem(at: link)
            }
            try manager.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        }
        let kept = Set(entries)
        for name in try manager.contentsOfDirectory(atPath: buildFolder.path) where !kept.contains(name) {
            let link = buildFolder.appendingPathComponent(name)
            if (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try manager.removeItem(at: link)
            }
        }
    }

    /// The targets of the package, read from the build folder.
    static func describe(buildFolder: URL, environment: [String: String], output: PreviewBuildOutput,
                         track: (ChildProcess?) -> Void) async -> [PackageTarget]? {
        let (termination, data) = await PreviewBuildRun.run(["swift", "package", "describe", "--type", "json"], environment: environment,
                                                            directory: buildFolder.path, timeout: PreviewBuildRun.readTimeout,
                                                            output: output, track: track)
        guard termination?.isSuccess == true else { return nil }
        // Warnings may come before the JSON.
        guard let start = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return PackageTarget.decode(describe: data[start...])
    }

    /// Writes the copy of a target in the build folder: its files, each Swift source with its
    /// `@main` left out and the functions of its preview blocks after it, `main.swift` left out,
    /// and the host's file. Files that did not change keep their dates, so that the next build
    /// compiles what changed. Returns the map of each copied Swift source to its file.
    @discardableResult
    static func mirror(target: PackageTarget, package: URL, buildFolder: URL) throws -> [String: PreviewSourceMap] {
        let manager = FileManager.default
        let source = target.path.isEmpty ? package : package.appendingPathComponent(target.path)
        let destination = buildFolder.appendingPathComponent(hostsFolder).appendingPathComponent(target.name)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let sources = Set(target.sources)
        var written: Set<String> = [PreviewHostSource.hostFileName]
        var entries: [(key: String, function: String)] = []
        var maps: [String: PreviewSourceMap] = [:]
        var fileNumber = 0
        guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [:] }
        let sourcePath = source.standardizedFileURL.path
        var files: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(sourcePath + "/") else { continue }
            files.append((String(path.dropFirst(sourcePath.count + 1)), url.standardizedFileURL))
        }
        files.sort { $0.relative < $1.relative }
        for file in files {
            if file.relative == "main.swift" { continue }
            let target = destination.appendingPathComponent(file.relative)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if sources.contains(file.relative), file.relative.hasSuffix(".swift"),
               let text = try? String(contentsOf: file.url, encoding: .utf8) {
                let scan = SwiftSourceScanner.scan(text)
                var bytes = Array(text.utf8)
                for range in scan.mainAttributes {
                    PreviewHostSource.blank(&bytes, range: range)
                }
                var copy = String(decoding: bytes, as: UTF8.self)
                let lines = bytes.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
                var segments = [PreviewSourceMap.Segment(line: 1, original: 1, count: lines)]
                if !scan.previews.isEmpty {
                    let functions = PreviewHostSource.previewFunctions(file: fileNumber, scan: scan, text: text, path: file.url.path)
                    fileNumber += 1
                    copy += "\n" + functions.code
                    entries += functions.entries
                    // The functions start on the line after the file's last line.
                    segments += functions.segments.map { PreviewSourceMap.Segment(line: $0.line + lines, original: $0.original, count: $0.count) }
                }
                try writeIfChanged(copy, to: target)
                maps[target.standardizedFileURL.path] = PreviewSourceMap(path: file.url.path, segments: segments)
            } else {
                try copyIfChanged(file.url, to: target)
            }
            written.insert(file.relative)
        }
        try writeIfChanged(PreviewHostSource.hostFile(entries: entries), to: destination.appendingPathComponent(PreviewHostSource.hostFileName))
        // Files the target no longer has.
        if let existing = manager.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey]) {
            let destinationPath = destination.standardizedFileURL.path
            for case let url as URL in existing {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(destinationPath + "/") else { continue }
                if !written.contains(String(path.dropFirst(destinationPath.count + 1))) {
                    try? manager.removeItem(at: url)
                }
            }
        }
        return maps
    }

    /// `swift build --product <host target>` in the build folder; the host's executable.
    static func build(target: PackageTarget, buildFolder: URL, environment: [String: String], output: PreviewBuildOutput,
                      track: (ChildProcess?) -> Void) async -> URL? {
        let product = hostTargetName(target.name)
        let (termination, _) = await PreviewBuildRun.run(["swift", "build", "--package-path", buildFolder.path, "--product", product],
                                                         environment: environment, directory: buildFolder.path,
                                                         timeout: PreviewBuildRun.buildTimeout, output: output, track: track)
        guard termination?.isSuccess == true else { return nil }
        let executable = buildFolder.appendingPathComponent(".build/debug").appendingPathComponent(product)
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    // MARK: Files

    static func writeIfChanged(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }

    static func copyIfChanged(_ source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) == data { return }
        try data.write(to: destination, options: .atomic)
    }
}
