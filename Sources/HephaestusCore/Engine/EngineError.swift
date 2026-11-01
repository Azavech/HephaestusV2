import Foundation

/// The error of a failed call, `{code, message}` (docs/engine-api.md › EngineError). The message
/// is one or two English sentences, shown to the user as-is and returned to Claude as the tool
/// error text (docs/engine-api.md › Messages).
public struct EngineError: Error, Codable, Sendable, Hashable {
    /// docs/engine-api.md › Error codes.
    public enum Code: String, Codable, Sendable, Hashable, CaseIterable {
        case notFound, invalid, conflict, forbidden, unavailable, `internal`
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ code: Code, _ message: String) {
        self.init(code: code, message: message)
    }

    /// A broken write rule: `invalid` or `conflict` with the rule's message.
    public init(_ error: ValidationError) {
        switch error.kind {
        case .invalid: self.init(.invalid, error.message)
        case .conflict: self.init(.conflict, error.message)
        }
    }
}

extension EngineError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - Dispatcher errors (docs/engine-api.md › Dispatcher errors)

extension EngineError {
    /// `notFound` `Unknown method <name>.`
    public static func unknownMethod(_ name: String) -> EngineError {
        EngineError(.notFound, "Unknown method \(name).")
    }

    /// `forbidden` `<name> is not available to <user, claude or system>.`
    public static func notAvailable(_ name: String, to kind: ActorKind) -> EngineError {
        EngineError(.forbidden, "\(name) is not available to \(kind.rawValue).")
    }

    /// `invalid` `Invalid params for <name>: <coding path>: <reason>.`
    public static func invalidParams(_ name: String, path: String, reason: String) -> EngineError {
        EngineError(.invalid, "Invalid params for \(name): \(path): \(reason).")
    }

    /// The `invalidParams` error of a decoding error.
    static func invalidParams(_ name: String, decoding error: Error) -> EngineError {
        let (path, reason) = DecodingErrorDescription.describe(error)
        return invalidParams(name, path: path, reason: reason)
    }

    /// `internal` `Internal error: <localized description>.`
    public static func internalError(_ error: Error) -> EngineError {
        // A Swift error without a localized description (StorageError, for example) is described
        // by its `description`; a final period is dropped (docs/engine-api.md › Dispatcher errors).
        var description = error is LocalizedError || type(of: error) is NSError.Type
            ? error.localizedDescription
            : String(describing: error)
        while description.hasSuffix(".") {
            description.removeLast()
        }
        return EngineError(.internal, "Internal error: \(description).")
    }

    /// `internal` `Unexpected result for <method>.`: a result that does not decode as the
    /// method's result type (docs/engine-api.md › EngineConnection).
    public static func unexpectedResult(_ method: String) -> EngineError {
        EngineError(.internal, "Unexpected result for \(method).")
    }
}

// MARK: - Common messages

extension EngineError {
    /// `notFound` `<Kind> <id> not found.`, the message of a `notFound` that no document defines
    /// (docs/engine-api.md › Messages).
    public static func notFound(_ kind: String, _ id: String) -> EngineError {
        EngineError(.notFound, "\(kind) \(id) not found.")
    }

    /// `invalid` `<param>: <reason>.` (docs/engine-api.md › Messages).
    public static func invalid(_ param: String, _ reason: String) -> EngineError {
        EngineError(.invalid, "\(param): \(reason).")
    }

    /// `internal` for a storage failure, naming the path (docs/engine-api.md › Writes and
    /// consistency).
    public static func storage(_ error: StorageError) -> EngineError {
        var text = error.description
        if !text.hasSuffix(".") { text += "." }
        return EngineError(.internal, text.prefix(1).uppercased() + text.dropFirst())
    }
}
