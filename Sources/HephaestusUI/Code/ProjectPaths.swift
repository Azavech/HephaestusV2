// OWNER: ui-code-docs — project path helpers of the file tree, the docs tree and their sheets
// (docs/code-editor.md › New File and New Folder, › Rename, › File tree; docs/documentation-viewer.md
// › New Doc, › Rename, › Docs tree).
import Foundation
import UniformTypeIdentifiers

/// Project paths: `/` separators, no leading `/`, `""` for the project root
/// (docs/engine-api.md › Paths).
enum ProjectPaths {
    /// The last component; `""` for the root.
    static func name(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// The parent folder; `""` for a top-level item and for the root.
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// `folder` joined with `name`; `name` alone in the root.
    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// True when `path` is `ancestor` or lies under it; every path lies under the root `""`.
    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// `path` moved from under `oldPath` to under `newPath`; nil when it is not under `oldPath`.
    static func renamed(_ path: String, from oldPath: String, to newPath: String) -> String? {
        if path == oldPath { return newPath }
        guard path.hasPrefix(oldPath + "/") else { return nil }
        return newPath + path.dropFirst(oldPath.count)
    }

    /// The folders above a path, outermost first, without the root: `a/b/c` gives `a`, `a/b`.
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = parent(of: path)
        while !current.isEmpty {
            result.insert(current, at: 0)
            current = parent(of: current)
        }
        return result
    }

    /// The validity rule of the New File, New Folder, New Doc and Rename sheets: a trimmed name is
    /// invalid when it is empty, starts with `/`, or has an empty, `.` or `..` component.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/") else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    /// The name without its extension: `main.go` gives `main`, `.zshrc` stays `.zshrc`.
    static func baseName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// True for a name ending in `.md` or `.markdown`, any case.
    static func isMarkdownName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown")
    }

    /// True for a file whose extension is an image type.
    static func isImageName(_ name: String) -> Bool {
        let fileExtension = (name as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// The range of `text` that a sheet's field selects: the last component, without its extension
    /// when `withoutExtension` is true.
    static func lastComponentSelection(in text: String, withoutExtension: Bool) -> Range<String.Index> {
        let start = text.lastIndex(of: "/").map { text.index(after: $0) } ?? text.startIndex
        var end = text.endIndex
        if withoutExtension, let dot = text[start...].lastIndex(of: "."), dot != start {
            end = dot
        }
        return start..<end
    }
}
