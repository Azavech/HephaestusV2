import Foundation

/// The targets of an Xcode project and the files they build, read from its `project.pbxproj`
/// (docs/views.md › Xcode project): the files of their Sources build phases and the files of the
/// folders they synchronize, without the exceptions of those folders.
public struct XcodeProject: Sendable {
    public struct Target: Sendable, Hashable {
        public var name: String
        /// For example `com.apple.product-type.application`.
        public var productType: String
        /// The absolute paths of the files of its Sources build phase.
        public var sourceFiles: Set<String>
        /// The absolute paths of the folders it synchronizes, with the paths each one excludes,
        /// relative to the folder.
        public var synchronizedFolders: [(folder: String, exceptions: Set<String>)]
        /// The platforms it builds for (docs/views.md › Platforms of a target).
        public var platforms: Set<PreviewPlatform> = [.macOS]

        public static func == (a: Target, b: Target) -> Bool {
            a.name == b.name && a.productType == b.productType && a.sourceFiles == b.sourceFiles && a.platforms == b.platforms
                && a.synchronizedFolders.map(\.folder) == b.synchronizedFolders.map(\.folder)
                && a.synchronizedFolders.map(\.exceptions) == b.synchronizedFolders.map(\.exceptions)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }

        /// Whether it builds the file at this absolute path.
        public func builds(_ path: String) -> Bool {
            if sourceFiles.contains(path) { return true }
            for (folder, exceptions) in synchronizedFolders where path.hasPrefix(folder + "/") {
                let relative = String(path.dropFirst(folder.count + 1))
                let excluded = exceptions.contains { relative == $0 || relative.hasPrefix($0 + "/") }
                if !excluded { return true }
            }
            return false
        }
    }

    public var targets: [Target]

    /// Reads `<project>.xcodeproj/project.pbxproj`; nil when it cannot be read.
    public static func read(_ projectURL: URL) -> XcodeProject? {
        let file = projectURL.appendingPathComponent("project.pbxproj")
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String, let root = objects[rootID] else { return nil }
        var projectDir = projectURL.deletingLastPathComponent().standardizedFileURL.path
        if let dirPath = root["projectDirPath"] as? String, !dirPath.isEmpty {
            projectDir = dirPath.hasPrefix("/") ? dirPath : URL(fileURLWithPath: projectDir).appendingPathComponent(dirPath).standardizedFileURL.path
        }
        // The absolute path of each file reference and folder, from the main group down.
        var paths: [String: String] = [:]
        func walk(_ id: String, parent: String) {
            guard let object = objects[id] else { return }
            let tree = object["sourceTree"] as? String ?? "<group>"
            let own = object["path"] as? String
            var path: String?
            switch tree {
            case "<group>": path = own.map { URL(fileURLWithPath: parent).appendingPathComponent($0).standardizedFileURL.path } ?? parent
            case "SOURCE_ROOT": path = own.map { URL(fileURLWithPath: projectDir).appendingPathComponent($0).standardizedFileURL.path } ?? projectDir
            case "<absolute>": path = own
            default: path = nil
            }
            guard let path else { return }
            paths[id] = path
            for child in object["children"] as? [String] ?? [] {
                walk(child, parent: path)
            }
        }
        if let main = root["mainGroup"] as? String {
            walk(main, parent: projectDir)
        }
        var targets: [Target] = []
        for targetID in root["targets"] as? [String] ?? [] {
            guard let target = objects[targetID], target["isa"] as? String == "PBXNativeTarget",
                  let name = target["name"] as? String else { continue }
            var sources: Set<String> = []
            for phaseID in target["buildPhases"] as? [String] ?? [] {
                guard let phase = objects[phaseID], phase["isa"] as? String == "PBXSourcesBuildPhase" else { continue }
                for buildFileID in phase["files"] as? [String] ?? [] {
                    if let reference = objects[buildFileID]?["fileRef"] as? String, let path = paths[reference] {
                        sources.insert(path)
                    }
                }
            }
            var folders: [(folder: String, exceptions: Set<String>)] = []
            for groupID in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                guard let folder = paths[groupID], let group = objects[groupID] else { continue }
                var exceptions: Set<String> = []
                for exceptionID in group["exceptions"] as? [String] ?? [] {
                    guard let exception = objects[exceptionID], exception["target"] as? String == targetID else { continue }
                    exceptions.formUnion(exception["membershipExceptions"] as? [String] ?? [])
                }
                folders.append((folder, exceptions))
            }
            targets.append(Target(name: name, productType: target["productType"] as? String ?? "", sourceFiles: sources,
                                  synchronizedFolders: folders,
                                  platforms: platforms(debugSettings(target, objects), projectSettings: debugSettings(root, objects))))
        }
        return XcodeProject(targets: targets)
    }

    /// The build settings of the Debug configuration of a target or of the project, else of its
    /// first configuration.
    static func debugSettings(_ object: [String: Any], _ objects: [String: [String: Any]]) -> [String: Any] {
        guard let listID = object["buildConfigurationList"] as? String,
              let configurations = objects[listID]?["buildConfigurations"] as? [String] else { return [:] }
        let all = configurations.compactMap { objects[$0] }
        let chosen = all.first { $0["name"] as? String == "Debug" } ?? all.first
        return chosen?["buildSettings"] as? [String: Any] ?? [:]
    }

    /// The platforms of a target (docs/views.md › Platforms of a target): its or the project's
    /// `SUPPORTED_PLATFORMS`, else its or the project's `SDKROOT`, else macOS.
    static func platforms(_ settings: [String: Any], projectSettings: [String: Any]) -> Set<PreviewPlatform> {
        func value(_ key: String) -> String? {
            for source in [settings, projectSettings] {
                if let text = source[key] as? String { return text }
                if let list = source[key] as? [String] { return list.joined(separator: " ") }
            }
            return nil
        }
        if let supported = value("SUPPORTED_PLATFORMS") {
            let names = Set(supported.split(whereSeparator: { $0 == " " || $0 == "\"" }).map(String.init))
            var platforms: Set<PreviewPlatform> = []
            if names.contains("macosx") { platforms.insert(.macOS) }
            if names.contains("iphoneos") || names.contains("iphonesimulator") { platforms.insert(.iOS) }
            if !platforms.isEmpty { return platforms }
        }
        switch value("SDKROOT") {
        case "iphoneos", "iphonesimulator": return [.iOS]
        default: return [.macOS]
        }
    }

    /// The target that builds a file: an application or a framework first, then any other.
    public func target(of path: String) -> Target? {
        let matches = targets.filter { $0.builds(path) }
        return matches.first { Self.previewableProductTypes.contains($0.productType) } ?? matches.first
    }

    /// The product types whose targets are previewed.
    public static let previewableProductTypes: Set<String> = [
        "com.apple.product-type.application", "com.apple.product-type.framework",
    ]
}
