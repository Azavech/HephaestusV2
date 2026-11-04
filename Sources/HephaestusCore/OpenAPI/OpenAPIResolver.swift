import Foundation

/// A value with the project path of the file that holds it, against which its refs resolve.
public struct OpenAPINode: Sendable {
    public var value: OpenAPIValue
    public var file: String

    public init(value: OpenAPIValue, file: String) {
        self.value = value
        self.file = file
    }
}

/// The result of following the `$ref` members of a node.
public struct OpenAPIResolution: Sendable {
    /// The target; nil when a ref cannot be resolved.
    public var node: OpenAPINode?
    /// The first `$ref` followed, as written.
    public var ref: String?
    /// `<file>#<pointer>` of every ref followed, in order.
    public var keys: [String]

    public var isUnresolved: Bool { node == nil }
}

/// The parsed files of a contract and the resolution of `$ref` pointers between them
/// (docs/openapi.md › $ref resolution). Immutable once loaded.
public final class OpenAPIResolver: Sendable {
    /// The most refs followed from one value.
    public static let maximumHops = 32

    /// Project path of the contract.
    public let mainPath: String
    /// Parsed files by project path; a file that could not be read or parsed is absent.
    public let files: [String: OpenAPIValue]

    public init(mainPath: String, files: [String: OpenAPIValue]) {
        self.mainPath = mainPath
        self.files = files
    }

    /// Follows the `$ref` members from `node`, at most `maximumHops` times.
    public func resolve(_ node: OpenAPINode) -> OpenAPIResolution {
        var current = node
        var keys: [String] = []
        var first: String?
        for _ in 0..<Self.maximumHops {
            guard let ref = current.value["$ref"]?.stringValue else {
                return OpenAPIResolution(node: current, ref: first, keys: keys)
            }
            first = first ?? ref
            guard let target = Self.target(of: ref, from: current.file), let file = files[target.file],
                  let value = file.value(at: target.pointer) else {
                return OpenAPIResolution(node: nil, ref: first, keys: keys)
            }
            let key = target.key
            guard !keys.contains(key) else { return OpenAPIResolution(node: nil, ref: first, keys: keys) }
            keys.append(key)
            current = OpenAPINode(value: value, file: target.file)
        }
        return OpenAPIResolution(node: nil, ref: first, keys: keys)
    }

    /// The node at a ref from `file`, or nil.
    public func value(atRef ref: String, from file: String) -> OpenAPINode? {
        resolve(OpenAPINode(value: .object([OpenAPIMember(key: "$ref", value: .string(ref))]), file: file)).node
    }

    // MARK: Ref syntax

    /// The file and JSON pointer a ref names.
    public struct Target: Sendable, Equatable {
        public var file: String
        public var pointer: [String]

        /// `<file>#/<pointer tokens>`, the identity of a target.
        public var key: String {
            file + "#" + pointer.map { "/" + $0 }.joined()
        }
    }

    /// Splits a ref and resolves its file part against the folder of `file`; nil when the file part
    /// has a URL scheme, starts with `/` or leaves the project's folder, or the pointer is invalid.
    public static func target(of ref: String, from file: String) -> Target? {
        let filePart: Substring
        let fragment: Substring
        if let hash = ref.firstIndex(of: "#") {
            filePart = ref[..<hash]
            fragment = ref[ref.index(after: hash)...]
        } else {
            filePart = Substring(ref)
            fragment = ""
        }
        let targetFile: String
        if filePart.isEmpty {
            targetFile = file
        } else {
            let decoded = String(filePart).removingPercentEncoding ?? String(filePart)
            guard decoded.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil,
                  !decoded.hasPrefix("/"), let joined = join(folder: folder(of: file), relative: decoded) else { return nil }
            targetFile = joined
        }
        let decodedFragment = String(fragment).removingPercentEncoding ?? String(fragment)
        guard decodedFragment.isEmpty || decodedFragment.hasPrefix("/") else { return nil }
        let pointer = decodedFragment.isEmpty
            ? []
            : decodedFragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
                $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
        return Target(file: targetFile, pointer: pointer)
    }

    /// The folder of a project path; `""` for the project root.
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Joins a relative path to a folder and removes `.` and `..`; nil when it leaves the root.
    static func join(folder: String, relative: String) -> String? {
        var components = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// The name a ref gives its target: the last pointer token, else the file's name.
    public static func name(of ref: String) -> String {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let last = parts[1].split(separator: "/").last {
            let token = String(last).removingPercentEncoding ?? String(last)
            return token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        let file = String(parts.first ?? "")
        return file.split(separator: "/").last.map(String.init) ?? ref
    }
}

extension OpenAPIValue {
    /// The value a JSON pointer names (RFC 6901), or nil.
    public func value(at pointer: [String]) -> OpenAPIValue? {
        var current = self
        for token in pointer {
            switch current {
            case .object(let members):
                guard let member = members.first(where: { $0.key == token }) else { return nil }
                current = member.value
            case .array(let items):
                guard let index = Int(token), items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    /// Every `$ref` string of the value, depth first.
    func refs() -> [String] {
        var found: [String] = []
        collectRefs(into: &found)
        return found
    }

    private func collectRefs(into found: inout [String]) {
        switch self {
        case .object(let members):
            for member in members {
                if member.key == "$ref", case .string(let ref) = member.value {
                    found.append(ref)
                } else {
                    member.value.collectRefs(into: &found)
                }
            }
        case .array(let items):
            for item in items {
                item.collectRefs(into: &found)
            }
        default:
            break
        }
    }
}

// MARK: - Loading

/// Parses a contract and reads the project files its refs name (docs/openapi.md › $ref
/// resolution).
public enum OpenAPILoader {
    /// The text of a project path, or nil when it cannot be read.
    public typealias Reader = @Sendable (String) async -> String?

    /// The most files a contract reads besides its own.
    public static let maximumFiles = 500

    /// - Parameters:
    ///   - isJSON: true for a project path whose language is `json`.
    ///   - read: reads the other files.
    public static func load(path: String, text: String, isJSON: @Sendable (String) -> Bool,
                            read: Reader) async -> Result<OpenAPIContract, OpenAPIParseError> {
        let root: OpenAPIValue
        do {
            root = try OpenAPIValue.parse(text, asJSON: isJSON(path))
        } catch let error as OpenAPIParseError {
            return .failure(error)
        } catch {
            return .failure(OpenAPIParseError(String(describing: error)))
        }
        guard case .object = root else {
            return .failure(OpenAPIParseError("The root of the document is not a mapping."))
        }
        guard let version = root["openapi"]?.scalarText, root["openapi"]?.members == nil, version.hasPrefix("3") else {
            return .failure(OpenAPIParseError("The document has no openapi version starting with 3."))
        }
        var files: [String: OpenAPIValue] = [path: root]
        var attempted: Set<String> = [path]
        var queue = [path]
        while !queue.isEmpty {
            let file = queue.removeFirst()
            guard let value = files[file] else { continue }
            for ref in value.refs() {
                guard let target = OpenAPIResolver.target(of: ref, from: file), !attempted.contains(target.file),
                      attempted.count <= maximumFiles else { continue }
                attempted.insert(target.file)
                guard let other = await read(target.file),
                      let parsed = try? OpenAPIValue.parse(other, asJSON: isJSON(target.file)) else { continue }
                files[target.file] = parsed
                queue.append(target.file)
            }
        }
        let resolver = OpenAPIResolver(mainPath: path, files: files)
        return .success(OpenAPIContract(resolver: resolver, version: version, readFiles: attempted.subtracting([path])))
    }
}
