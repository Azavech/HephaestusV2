import CryptoKit
import Foundation

/// The Swift package or the Xcode project that builds a file (docs/views.md › Package or Xcode
/// project of a view).
public struct PreviewBuildUnit: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case package
        /// The `.xcodeproj` folder.
        case xcodeProject(URL)
    }

    /// The folder of `Package.swift` or of the `.xcodeproj`.
    public var folder: URL
    public var kind: Kind

    /// The nearest folder, from the file's folder up to `root`, that holds a `Package.swift` or an
    /// `.xcodeproj` folder; a folder with both is the package. Nil when no folder does.
    public static func of(file: URL, root: URL) -> PreviewBuildUnit? {
        let rootPath = root.standardizedFileURL.path
        var folder = file.standardizedFileURL.deletingLastPathComponent()
        let manager = FileManager.default
        while true {
            if manager.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) {
                return PreviewBuildUnit(folder: folder, kind: .package)
            }
            if let entries = try? manager.contentsOfDirectory(atPath: folder.path),
               let project = entries.filter({ $0.hasSuffix(".xcodeproj") }).sorted().first {
                return PreviewBuildUnit(folder: folder, kind: .xcodeProject(folder.appendingPathComponent(project)))
            }
            let path = folder.path
            if path == rootPath || path == "/" || !path.hasPrefix(rootPath) { return nil }
            folder = folder.deletingLastPathComponent()
        }
    }

    /// The name of its build folder in `Runtime/previews/`: the folder's name and a hash of its
    /// path.
    public var buildFolderName: String {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = folder.lastPathComponent.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        return "\(name)-\(hash)"
    }

    /// The name the failures give: the folder's name for a package, the project's name for an
    /// Xcode project.
    public var displayName: String {
        switch kind {
        case .package: return folder.lastPathComponent
        case .xcodeProject(let project): return project.deletingPathExtension().lastPathComponent
        }
    }
}

/// A target of a Swift package as `swift package describe --type json` gives it.
public struct PackageTarget: Sendable, Hashable {
    public var name: String
    /// Its module's name.
    public var moduleName: String
    /// The target's folder, relative to the package.
    public var path: String
    /// Its sources, relative to its folder.
    public var sources: [String]
    /// `library`, `executable`, `test`, `macro`, `plugin`…
    public var type: String
    public var moduleType: String

    /// The targets of `swift package describe --type json`.
    public static func decode(describe data: Data) -> [PackageTarget]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = object["targets"] as? [[String: Any]] else { return nil }
        return targets.compactMap { target in
            guard let name = target["name"] as? String, let path = target["path"] as? String else { return nil }
            return PackageTarget(name: name, moduleName: target["c99name"] as? String ?? name, path: path,
                                 sources: target["sources"] as? [String] ?? [],
                                 type: target["type"] as? String ?? "", moduleType: target["module_type"] as? String ?? "")
        }
    }

    /// The Swift target whose sources hold a file, given relative to the package; a test target
    /// only when no other target holds it.
    public static func target(of path: String, in targets: [PackageTarget]) -> PackageTarget? {
        let matches = targets.filter { target in
            target.moduleType == "SwiftTarget" && target.sources.contains { source in
                let full = target.path.isEmpty ? source : target.path + "/" + source
                return full == path || path.hasPrefix(full + "/")
            }
        }
        return matches.first { $0.type != "test" } ?? matches.first
    }
}
