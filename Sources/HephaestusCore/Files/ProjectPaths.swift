import Foundation

/// Project paths (docs/engine-api.md › Paths): relative to a project root, `/` separators, no
/// leading `/`, no `.`, `..` or empty components, a trailing `/` removed first; `""` is the root.
/// The check is lexical: symbolic links inside a project are followed without further checks.
enum ProjectPaths {
    /// The project's data folder.
    static let dataFolder = ".hephaestus"
    /// The project file, relative to the project root.
    static let projectFile = ".hephaestus/project.yml"
    /// The chats folder, relative to the project root.
    static let chatsFolder = ".hephaestus/chats"

    /// `forbidden`: a path inside a chats folder (docs/engine-api.md › Files).
    static let chatFilesMessage = "Chat files are written only by HephaestusV2."
    /// `forbidden`: the data folder or the project file (docs/engine-api.md › files.rename).
    static let dataFolderMessage = "The project's data folder and project.yml cannot be moved."

    /// The project path of a param: one trailing `/` removed, then the rules checked. `""` is
    /// accepted only when `allowRoot` is true.
    /// - Throws: `invalid` `<param>: <reason>.`
    static func normalize(_ value: String, param: String, allowRoot: Bool) throws -> String {
        var path = value
        if path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty {
            guard allowRoot else {
                throw EngineError.invalid(param, "name a file or folder inside the project, not the project root")
            }
            return ""
        }
        guard isValid(path) else {
            throw EngineError.invalid(param, "use a project path with / separators, without a leading /, and without empty, . or .. components")
        }
        return path
    }

    /// True when `path` is a non-empty project path. A NUL character, which no file name can
    /// hold, breaks the rules too.
    static func isValid(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// The components of a project path; none for the root.
    static func components(_ path: String) -> [Substring] {
        path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false)
    }

    /// `child` inside `parent`; `parent` may be the root.
    static func join(_ parent: String, _ child: String) -> String {
        if parent.isEmpty { return child }
        if child.isEmpty { return parent }
        return parent + "/" + child
    }

    /// The parent of a project path; `""` for a top-level entry.
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The last component of a project path.
    static func name(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// True when `path` is `ancestor` or lies below it. The root contains every path.
    static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// True when `path` lies strictly below `ancestor`.
    static func isStrictlyInside(_ path: String, _ ancestor: String) -> Bool {
        path != ancestor && isSameOrInside(path, ancestor)
    }

    /// The ancestor of `path` made of its first `depth` components, or `path` itself when it has
    /// no more than `depth` components (depth 1 is a top-level entry).
    static func ancestor(of path: String, depth: Int) -> String {
        let parts = components(path)
        guard parts.count > depth else { return path }
        return parts.prefix(depth).joined(separator: "/")
    }

    /// True when `path` is a chats folder `.hephaestus/chats` or lies inside one: the project's
    /// own, or that of a sub project folder inside it (docs/engine-api.md › Files, › Changes made
    /// outside the engine).
    static func isInChatsFolder(_ path: String) -> Bool {
        let parts = components(path)
        guard parts.count >= 2 else { return false }
        for index in 0..<(parts.count - 1) where parts[index] == ".hephaestus" && parts[index + 1] == "chats" {
            return true
        }
        return false
    }

    /// True when `path` is a `.git` item or lies inside one, at any depth
    /// (docs/engine-api.md › Changes made outside the engine).
    static func isInGitFolder(_ path: String) -> Bool {
        components(path).contains(".git")
    }
}
