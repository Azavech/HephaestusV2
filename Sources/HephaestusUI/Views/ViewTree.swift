// OWNER: ui-views — the folder tree of the Views section's list (docs/views.md › Folder tree).
import Foundation
import HephaestusCore

/// A node of the list of views: a folder with its children, or a view.
struct ViewTreeNode: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A folder, by its project path.
        case folder(path: String, name: String)
        case view(ProjectView)
    }

    var kind: Kind
    var children: [ViewTreeNode] = []

    var id: String {
        switch kind {
        case .folder(let path, _): return "folder:" + path
        case .view(let view): return ViewSelection(view).id
        }
    }
}

/// A view selected in the list: its file and its name.
struct ViewSelection: Hashable {
    var path: String
    var name: String

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    init(_ view: ProjectView) {
        self.init(path: view.path, name: view.name)
    }

    var id: String { "view:\(path)#\(name)" }
}

/// A row shown by the list: a node and its depth below the project root.
struct ViewTreeRow: Identifiable, Equatable {
    var node: ViewTreeNode
    var depth: Int
    var id: String { node.id }
}

enum ViewTree {
    /// The tree of the folders that hold views, from the project root: under each folder its
    /// folders, then its views, each group in Finder order; views of the same name by file name,
    /// then line.
    static func build(_ views: [ProjectView]) -> [ViewTreeNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var views: [ProjectView] = []
        }
        let root = Folder()
        for view in views {
            var folder = root
            for component in view.path.split(separator: "/").dropLast() {
                let name = String(component)
                let next = folder.folders[name] ?? Folder()
                folder.folders[name] = next
                folder = next
            }
            folder.views.append(view)
        }
        func nodes(_ folder: Folder, path: String) -> [ViewTreeNode] {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                let childPath = path.isEmpty ? name : path + "/" + name
                return ViewTreeNode(kind: .folder(path: childPath, name: name), children: nodes(folder.folders[name]!, path: childPath))
            }
            let views = folder.views.sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                if order != .orderedSame { return order == .orderedAscending }
                let files = fileName(a.path).localizedStandardCompare(fileName(b.path))
                if files != .orderedSame { return files == .orderedAscending }
                return a.line < b.line
            }.map { ViewTreeNode(kind: .view($0)) }
            return folders + views
        }
        return nodes(root, path: "")
    }

    /// The rows shown: every node whose folders above it are expanded.
    static func rows(_ nodes: [ViewTreeNode], collapsed: Set<String>, depth: Int = 0) -> [ViewTreeRow] {
        var rows: [ViewTreeRow] = []
        for node in nodes {
            rows.append(ViewTreeRow(node: node, depth: depth))
            if case .folder(let path, _) = node.kind, !collapsed.contains(path) {
                rows += self.rows(node.children, collapsed: collapsed, depth: depth + 1)
            }
        }
        return rows
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The paths of `files.changed` that make the list read again (docs/views.md › Live updates):
    /// `""`, a path that ends with `.swift`, or a path whose last component has no `.`, outside
    /// the skipped folders.
    static func shouldReload(changed paths: [String]) -> Bool {
        paths.contains { path in
            if path.isEmpty { return true }
            let components = path.split(separator: "/").map(String.init)
            if components.contains(where: ViewFinder.skippedFolderNames.contains) { return false }
            guard let last = components.last else { return true }
            return path.hasSuffix(".swift") || !last.contains(".")
        }
    }
}
