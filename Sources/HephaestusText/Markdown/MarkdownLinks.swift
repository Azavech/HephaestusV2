import Foundation

/// A reference resolved to a project path (docs/documentation-viewer.md › Path resolution).
public struct MarkdownResolvedReference: Sendable, Equatable {
    /// The project path; `""` is the project root.
    public var path: String
    /// The fragment after the first `#`, percent-decoded when it is valid percent-encoding;
    /// nil when the reference has no fragment or an empty one.
    public var fragment: String?

    public init(path: String, fragment: String?) {
        self.path = path
        self.fragment = fragment
    }
}

/// The link and image rules of the Markdown renderers (docs/documentation-viewer.md › Links,
/// Images, Path resolution, Resource URL schemes). They are public so that the views that
/// activate links resolve them exactly as the renderers do.
public enum MarkdownLinks {
    /// The scheme of a destination, lowercased: the text before the first `:` when it matches
    /// `[A-Za-z][A-Za-z0-9+.-]*` and no `/`, `?` or `#` comes before the `:`.
    public static func scheme(of destination: String) -> String? {
        var scheme = ""
        for scalar in destination.unicodeScalars {
            if scalar == ":" {
                return scheme.isEmpty ? nil : scheme.lowercased()
            }
            let value = scalar.value
            let isLetter = Scalars.isASCIILetter(value)
            let isOther = Scalars.isASCIIDigit(value) || scalar == "+" || scalar == "." || scalar == "-"
            guard isLetter || (!scheme.isEmpty && isOther) else { return nil }
            scheme.unicodeScalars.append(scalar)
        }
        return nil
    }

    /// Whether a link destination is accepted (docs/documentation-viewer.md › Links): `#…`,
    /// `http`, `https` and `file` URLs, and paths without a scheme other than `//…`.
    public static func isAcceptedLinkDestination(_ destination: String) -> Bool {
        if destination.isEmpty { return false }
        if destination.hasPrefix("#") { return true }
        if let scheme = scheme(of: destination) {
            return scheme == "http" || scheme == "https" || scheme == "file"
        }
        return !destination.hasPrefix("//")
    }

    /// The source of an image (docs/documentation-viewer.md › Images).
    public static func imageSource(_ source: String, options: MarkdownRenderOptions) -> MarkdownImageSource {
        if source.isEmpty || source.hasPrefix("//") { return .blocked }
        switch scheme(of: source) {
        case "http", "https":
            return .remote(source)
        case "file", nil:
            guard let resolved = resolve(source, options: options) else { return .blocked }
            return .projectFile(resolved.path)
        default:
            return .blocked
        }
    }

    /// Resolves a reference without scheme, or a `file` URL, to a project path
    /// (docs/documentation-viewer.md › Path resolution); nil when it resolves to nothing.
    public static func resolve(_ reference: String, options: MarkdownRenderOptions) -> MarkdownResolvedReference? {
        var rest = Substring(reference)
        let scheme = scheme(of: reference)
        if let scheme {
            guard scheme == "file" else { return nil }
            rest = rest.dropFirst(scheme.count + 1)
        }
        // 1. Fragment and query.
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            let raw = String(rest[rest.index(after: hash)...])
            fragment = raw.isEmpty ? nil : (raw.removingPercentEncoding ?? raw)
            rest = rest[..<hash]
        }
        if let question = rest.firstIndex(of: "?") {
            rest = rest[..<question]
        }
        // A reference made of a fragment or a query only resolves to nothing
        // (docs/documentation-viewer.md › Path resolution, step 1).
        guard !rest.isEmpty, let decoded = String(rest).removingPercentEncoding else { return nil }

        let root = options.projectRootPath.map(normalizedRoot)
        let relative: String
        if scheme != nil {
            // 2. A file URL.
            var path = Substring(decoded)
            if path.hasPrefix("//") {
                // The host is empty or `localhost`, any other host resolves to nothing
                // (docs/documentation-viewer.md › Path resolution, step 2).
                let afterSlashes = path.dropFirst(2)
                let hostEnd = afterSlashes.firstIndex(of: "/") ?? afterSlashes.endIndex
                let host = afterSlashes[..<hostEnd]
                guard host.isEmpty || host.lowercased() == "localhost" else { return nil }
                path = afterSlashes[hostEnd...]
            }
            guard let root, let inside = pathInside(root: root, String(path)) else { return nil }
            relative = inside
        } else if decoded.hasPrefix("/") {
            // 3. An absolute path: inside the project root, or relative to the project root.
            if let root, let inside = pathInside(root: root, decoded) {
                relative = inside
            } else {
                relative = String(decoded.dropFirst())
            }
        } else {
            // 4. Relative to the base directory.
            relative = options.baseDirectory.isEmpty ? decoded : options.baseDirectory + "/" + decoded
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
        return MarkdownResolvedReference(path: components.joined(separator: "/"), fragment: fragment)
    }

    /// `hephaestus-file://project/` followed by the percent-encoded project path
    /// (docs/documentation-viewer.md › Resource URL schemes).
    public static func fileResourceURL(projectPath: String) -> String {
        "hephaestus-file://project/" + percentEncodedPath(projectPath)
    }

    /// Each path component UTF-8 encoded, every byte outside `A`–`Z`, `a`–`z`, `0`–`9`, `-`,
    /// `.`, `_` and `~` written as `%` and two uppercase hexadecimal digits; components joined
    /// with `/`.
    public static func percentEncodedPath(_ path: String) -> String {
        let hexDigits = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(path.utf8.count)
        for byte in path.utf8 {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            if isUnreserved || byte == 0x2F {
                bytes.append(byte)
            } else {
                bytes.append(0x25)
                bytes.append(hexDigits[Int(byte >> 4)])
                bytes.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The project root path without a trailing `/` (except the root folder itself).
    private static func normalizedRoot(_ root: String) -> String {
        var root = root
        while root.count > 1, root.hasSuffix("/") {
            root.removeLast()
        }
        return root
    }

    /// The part of `path` after `root` and a `/`, `""` when it equals `root`, else nil.
    private static func pathInside(root: String, _ path: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
