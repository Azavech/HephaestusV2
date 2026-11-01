import Foundation
import Yams

/// Errors of the storage layer. Messages name the path and never include file contents.
public enum StorageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file breaks a read rule of docs/data-model.md › Read rules.
    case invalidFile(path: String, reason: String)
    /// The file could not be read.
    case readFailed(path: String, reason: String)
    /// A step of an atomic write failed; the call fails with `internal`, naming the path.
    case writeFailed(path: String, reason: String)
    /// Another process holds the lock of the data directory.
    case dataDirectoryInUse(path: String)
    /// The data directory cannot be created or opened.
    case dataDirectoryUnavailable(path: String, reason: String)

    public var description: String {
        switch self {
        case let .invalidFile(path, reason): return "\(path) is invalid: \(reason)"
        case let .readFailed(path, reason): return "\(path) cannot be read: \(reason)"
        case let .writeFailed(path, reason): return "\(path) cannot be written: \(reason)"
        case let .dataDirectoryInUse(path): return DataDirectoryLock.inUseMessage(path: path)
        case let .dataDirectoryUnavailable(path, reason): return "data directory \(path) cannot be used: \(reason)"
        }
    }

    /// The reason of an invalid file, without the path.
    public var reason: String {
        switch self {
        case let .invalidFile(_, reason), let .readFailed(_, reason), let .writeFailed(_, reason),
             let .dataDirectoryUnavailable(_, reason):
            return reason
        case .dataDirectoryInUse:
            return description
        }
    }
}

/// A file content that breaks the format rules, before the path is known.
public struct FormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }

    /// A short, content-free reason for any decoding error.
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as FormatError:
            return error.reason
        case let error as DecodingError:
            return describe(decoding: error)
        case let error as YamlError:
            return "not valid YAML: " + String(describing: error).split(separator: "\n").first.map(String.init).orEmpty
        default:
            return String(describing: error)
        }
    }

    private static func describe(decoding error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let text = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return text.isEmpty ? "the root" : text
        }
        switch error {
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath + [key])): the required key is missing or null"
        case let .valueNotFound(_, context):
            return "\(path(context.codingPath)): the value is missing"
        case let .typeMismatch(type, context):
            return "\(path(context.codingPath)): expected a value of type \(type)"
        case let .dataCorrupted(context):
            if let underlying = context.underlyingError {
                return "\(path(context.codingPath)): \(describe(underlying))"
            }
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
