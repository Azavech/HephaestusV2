import Foundation

/// A Swift file read for the Views section: its project path, its absolute path and its scan.
public struct ScannedSwiftFile: Sendable {
    /// Project path.
    public var path: String
    public var url: URL
    public var scan: SwiftFileScan

    public init(path: String, url: URL, scan: SwiftFileScan) {
        self.path = path
        self.url = url
        self.scan = scan
    }
}

/// The views of a project (docs/views.md › List of views): the Swift files read under its root and
/// the rules of What a view is.
public enum ViewFinder {
    /// Folders skipped at any depth (docs/views.md › Swift files read).
    public static let skippedFolderNames: Set<String> = [".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm", ".hephaestus"]
    /// Larger files are not read.
    public static let maximumFileSize = 1_048_576

    /// The SwiftUI protocols whose conformance makes a view.
    static let swiftUIViewProtocols: Set<String> = [
        "View", "NSViewRepresentable", "UIViewRepresentable", "NSViewControllerRepresentable",
        "UIViewControllerRepresentable", "Shape", "InsettableShape",
    ]

    /// The AppKit and UIKit classes that descend from `NSView` or `UIView` without a name that
    /// ends with `View`.
    static let frameworkViewClasses: Set<String> = [
        "NSControl", "NSButton", "NSPopUpButton", "NSTextField", "NSSecureTextField", "NSSearchField", "NSTokenField",
        "NSComboBox", "NSSlider", "NSSegmentedControl", "NSStepper", "NSSwitch", "NSColorWell", "NSDatePicker",
        "NSLevelIndicator", "NSPathControl", "NSProgressIndicator", "NSMatrix", "NSBrowser", "NSBox", "NSRuleEditor",
        "NSPredicateEditor", "UIControl", "UIButton", "UILabel", "UITextField", "UISlider", "UISwitch", "UISegmentedControl",
        "UIStepper", "UIDatePicker", "UIPageControl", "UIRefreshControl", "UIColorWell", "UISearchBar", "UINavigationBar",
        "UIToolbar", "UITabBar", "UIWindow", "UITableViewCell", "UICollectionViewCell",
    ]

    // MARK: Files

    /// A file found by the walk, with what its stat said.
    public struct FoundFile: Sendable, Hashable {
        public var path: String
        public var url: URL
        public var size: Int
        public var modified: Date
    }

    /// Every Swift file under `root`, skipped folders, symbolic links and files above 1 MiB left
    /// out, sorted by path.
    public static func swiftFiles(under root: URL) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        let rootPath = root.standardizedFileURL.path
        var files: [FoundFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if skippedFolderNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "swift" else { continue }
            let size = values.fileSize ?? 0
            guard size <= maximumFileSize else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            files.append(FoundFile(path: String(path.dropFirst(rootPath.count + 1)), url: url.standardizedFileURL, size: size,
                                   modified: values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The scan of a file's text; nil for a file that cannot be read or is not UTF-8.
    public static func scanFile(at url: URL) -> SwiftFileScan? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return SwiftSourceScanner.scan(text)
    }

    // MARK: Views

    /// The views of the files, sorted by path, then line, with their previews.
    public static func views(in files: [ScannedSwiftFile]) -> [ProjectView] {
        // The protocols of the project that refine a SwiftUI view protocol, at any depth.
        var protocolInheritance: [String: [String]] = [:]
        for file in files {
            for declaration in file.scan.protocols {
                protocolInheritance[declaration.name, default: []] += declaration.inherited.map(baseName)
            }
        }
        var viewProtocols = swiftUIViewProtocols
        var changed = true
        while changed {
            changed = false
            for (name, inherited) in protocolInheritance where !viewProtocols.contains(name) {
                if inherited.contains(where: viewProtocols.contains) {
                    viewProtocols.insert(name)
                    changed = true
                }
            }
        }
        // The conformances added by extensions, by the last part of the extended name.
        var extensionConformances: [String: [String]] = [:]
        for file in files {
            for declaration in file.scan.extensions {
                extensionConformances[lastPart(declaration.extendedType), default: []] += declaration.inherited.map(baseName)
            }
        }
        // The superclasses of the classes of the project, by name.
        var superclasses: [String: String] = [:]
        for file in files {
            for declaration in file.scan.types where declaration.keyword == "class" {
                if let first = declaration.inherited.first {
                    superclasses[lastPart(declaration.qualifiedName)] = baseName(first)
                }
            }
        }

        var result: [ProjectView] = []
        for file in files {
            var seen: Set<String> = []
            var fileViews: [ProjectView] = []
            for declaration in file.scan.types where !seen.contains(declaration.qualifiedName) {
                let simple = lastPart(declaration.qualifiedName)
                let conformances = declaration.inherited.map(baseName) + (extensionConformances[simple] ?? [])
                var kind: ViewKind?
                if conformances.contains(where: viewProtocols.contains) {
                    kind = .swiftUI
                } else if declaration.keyword == "class", let first = declaration.inherited.first,
                          let root = frameworkViewRoot(of: baseName(first), superclasses: superclasses) {
                    if root.hasPrefix("NS") {
                        kind = .appKit
                    } else if root.hasPrefix("UI") {
                        kind = .uiKit
                    } else {
                        let modules = Set(file.scan.importedModules)
                        kind = modules.contains("UIKit") && !modules.contains("AppKit") ? .uiKit : .appKit
                    }
                }
                guard let kind else { continue }
                seen.insert(declaration.qualifiedName)
                fileViews.append(ProjectView(name: declaration.qualifiedName, path: file.path, line: declaration.line, kind: kind,
                                             previews: []))
            }
            // docs/views.md › Preview blocks: a block belongs to the views it names, or to every
            // view of its file when it names none.
            for block in file.scan.previews {
                let named = fileViews.indices.filter { block.identifiers.contains(lastPart(fileViews[$0].name)) }
                for index in (named.isEmpty ? Array(fileViews.indices) : named) {
                    fileViews[index].previews.append(ViewPreview(name: block.name, line: block.line))
                }
            }
            result += fileViews
        }
        return result.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    /// The preview blocks of a view, in the order of its file, with their rank among the blocks of
    /// the file.
    public static func previewOrdinals(of view: ProjectView, in scan: SwiftFileScan) -> [Int] {
        let lines = Set(view.previews.map(\.line))
        return scan.previews.indices.filter { lines.contains(scan.previews[$0].line) }
    }

    /// The framework class at the top of the chain of a superclass name, `NSView`, `UIView` or a
    /// framework class that descends from them; nil when the chain is not a view.
    static func frameworkViewRoot(of superclass: String, superclasses: [String: String]) -> String? {
        var name = superclass
        var visited: Set<String> = []
        while let next = superclasses[name], !visited.contains(name) {
            visited.insert(name)
            name = next
        }
        if superclasses[name] != nil { return nil }
        return isFrameworkViewClass(name) ? name : nil
    }

    /// `NSView`, `UIView`, two or three capital letters followed by a name that ends with `View`,
    /// or one of the controls of `frameworkViewClasses`.
    static func isFrameworkViewClass(_ name: String) -> Bool {
        if frameworkViewClasses.contains(name) { return true }
        guard name.hasSuffix("View") else { return false }
        let scalars = Array(name.unicodeScalars)
        let capitals = scalars.prefix { $0.properties.isUppercase && $0.isASCII }.count
        // `NSView`: the capitals then `View`; `NSTableView`: the prefix, then a capitalized name.
        for prefix in 2...3 where capitals >= prefix {
            let rest = String(String.UnicodeScalarView(scalars[prefix...]))
            if rest == "View" { return true }
            if rest.count > 4, let first = rest.unicodeScalars.first, first.properties.isUppercase,
               rest.unicodeScalars.dropFirst().first.map({ $0.properties.isLowercase }) == true {
                return true
            }
        }
        return false
    }

    /// `SwiftUI.View` → `View`, `Foo<Bar>` → `Foo`.
    static func baseName(_ name: String) -> String {
        lastPart(name.split(separator: "<").first.map(String.init) ?? name)
    }

    static func lastPart(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }
}
