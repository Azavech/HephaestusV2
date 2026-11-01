// OWNER: ui-code-docs — link resolution and activation of rendered Markdown, and the resource URLs
// (docs/documentation-viewer.md › Links, › Path resolution, › Link activation, › Resource URL schemes).
import Foundation

/// What a click on a link of the doc preview does (docs/documentation-viewer.md › Link activation).
enum DocLinkActivation: Equatable {
    /// A `#fragment` link: the page scrolls.
    case scroll(fragment: String)
    /// An `http` or `https` URL: a web tab, or the default browser with ⌘.
    case web(url: String)
    /// A doc under the docs folder, with the fragment to scroll to.
    case doc(path: String, fragment: String?)
    /// Any other project file, with the line of a GitHub line fragment.
    case file(path: String, line: Int?)
    /// Nothing happens.
    case none
}

/// Link and image references of rendered Markdown. Chats and tickets use the same path
/// resolution with `baseDirectory` `""` (docs/documentation-viewer.md › Link activation).
enum DocLinks {
    /// The scheme of a link destination: the text before the first `:` when it matches
    /// `[A-Za-z][A-Za-z0-9+.-]*` and no `/`, `?` or `#` comes before the `:`
    /// (docs/documentation-viewer.md › Links).
    static func scheme(of destination: String) -> String? {
        guard let colon = destination.firstIndex(of: ":") else { return nil }
        let candidate = destination[..<colon]
        guard let first = candidate.unicodeScalars.first, isASCIILetter(first) else { return nil }
        for scalar in candidate.unicodeScalars {
            guard isASCIILetter(scalar) || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "." || scalar == "-" else {
                return nil
            }
        }
        return String(candidate)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// Resolves a reference without scheme, or a `file` URL, to a project path and the link's
    /// fragment (docs/documentation-viewer.md › Path resolution). Nil when it resolves to nothing.
    static func resolve(_ reference: String, baseDirectory: String, projectRootPath: String?) -> (path: String, fragment: String?)? {
        // 1. The fragment (kept) and the query, then percent-decoding.
        var rest = Substring(reference)
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        if let question = rest.firstIndex(of: "?") {
            rest = rest[..<question]
        }
        // A reference made of a fragment or a query only resolves to nothing.
        guard !rest.isEmpty else { return nil }
        let isFileURL = scheme(of: String(rest))?.lowercased() == "file"
        if isFileURL {
            rest = rest.dropFirst("file:".count)
            if rest.hasPrefix("//") {
                // The authority: empty or `localhost`.
                let afterSlashes = rest.dropFirst(2)
                let slash = afterSlashes.firstIndex(of: "/") ?? afterSlashes.endIndex
                let host = afterSlashes[..<slash]
                guard host.isEmpty || host.lowercased() == "localhost" else { return nil }
                rest = afterSlashes[slash...]
            }
        }
        guard let decoded = String(rest).removingPercentEncoding else { return nil }

        // 2 to 4. The path relative to the project root.
        let relative: String
        let root = projectRootPath.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        if isFileURL {
            guard let root, let inside = pathInside(decoded, root: root) else { return nil }
            relative = inside
        } else if decoded.hasPrefix("/") {
            if let root, let inside = pathInside(decoded, root: root) {
                relative = inside
            } else {
                relative = String(decoded.dropFirst())
            }
        } else {
            relative = baseDirectory.isEmpty ? decoded : baseDirectory + "/" + decoded
        }

        // 5. Components.
        var components: [Substring] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
                continue
            }
            components.append(component)
        }
        return (components.joined(separator: "/"), fragment)
    }

    /// The rest of an absolute path below `root` without its leading `/`; nil outside the root.
    private static func pathInside(_ path: String, root: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The action of a click on a link whose `href` is `url` in a doc of `baseDirectory`
    /// (docs/documentation-viewer.md › Link activation).
    static func activation(of url: String, baseDirectory: String, projectRootPath: String?, docsPath: String) -> DocLinkActivation {
        if url.hasPrefix("#") {
            return .scroll(fragment: decodedFragment(String(url.dropFirst())))
        }
        if url.hasPrefix("//") || url.isEmpty {
            return .none
        }
        switch scheme(of: url)?.lowercased() {
        case "http", "https":
            return .web(url: url)
        case nil, "file":
            guard let (path, fragment) = resolve(url, baseDirectory: baseDirectory, projectRootPath: projectRootPath),
                  !path.isEmpty else {
                // A path that resolves to nothing or to the project root itself does nothing
                // (docs/documentation-viewer.md › Link activation).
                return .none
            }
            let folder = docsPath.hasSuffix("/") ? String(docsPath.dropLast()) : docsPath
            if (folder.isEmpty || path.hasPrefix(folder + "/")), ProjectPaths.isMarkdownName(ProjectPaths.name(of: path)) {
                return .doc(path: path, fragment: fragment.map(decodedFragment).flatMap { $0.isEmpty ? nil : $0 })
            }
            return .file(path: path, line: line(fromFragment: fragment))
        default:
            return .none
        }
    }

    /// The line of a GitHub line fragment `L<n>`, `L<n>-L<m>` or `L<n>C<c>`; nil otherwise.
    static func line(fromFragment fragment: String?) -> Int? {
        guard let fragment, fragment.hasPrefix("L") else { return nil }
        let body = fragment.dropFirst()
        let digits = body.prefix { ("0"..."9").contains($0) }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let tail = body.dropFirst(digits.count)
        if tail.isEmpty { return number }
        func isNumber(_ text: Substring) -> Bool {
            !text.isEmpty && text.allSatisfy { ("0"..."9").contains($0) }
        }
        if tail.hasPrefix("-L"), isNumber(tail.dropFirst(2)) { return number }
        if tail.hasPrefix("C"), isNumber(tail.dropFirst()) { return number }
        return nil
    }

    /// A fragment as written in an `href`, percent-decoded when it is valid percent-encoding, so
    /// that `#%C3%BCber-uns` reaches the heading `über-uns` (docs/documentation-viewer.md ›
    /// Preview web view).
    static func decodedFragment(_ fragment: String) -> String {
        fragment.removingPercentEncoding ?? fragment
    }

    // MARK: Resource URLs (docs/documentation-viewer.md › Resource URL schemes)

    /// Each component UTF-8 encoded, every byte outside `A`–`Z`, `a`–`z`, `0`–`9`, `-`, `.`, `_`
    /// and `~` written as `%` and two uppercase hexadecimal digits; components joined with `/`.
    static func percentEncodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { component in
            var result = ""
            for byte in component.utf8 {
                let scalar = Unicode.Scalar(byte)
                if ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                    || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "~") {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += String(format: "%%%02X", byte)
                }
            }
            return result
        }.joined(separator: "/")
    }

    /// `hephaestus-file://project/<percent-encoded project path>`.
    static func projectFileURL(_ path: String) -> String {
        "hephaestus-file://project/" + percentEncodedPath(path)
    }

    /// `hephaestus-attachment://attachment/<percent-encoded data path>`.
    static func attachmentURL(_ dataPath: String) -> String {
        "hephaestus-attachment://attachment/" + percentEncodedPath(dataPath)
    }
}
