import Foundation

// docs/engine-api.md › Claude.

/// `claude.models`: the cached model list. Actors: user.
public enum ClaudeModels: EngineMethod {
    public static let name = "claude.models"
    public typealias Params = Empty
    public typealias Result = [ClaudeModel]
}

/// `claude.status`: locates the CLI again, runs `--version` and returns the new status.
/// Actors: user.
public enum ClaudeStatusMethod: EngineMethod {
    public static let name = "claude.status"
    public typealias Params = Empty
    public typealias Result = ClaudeStatus
}
