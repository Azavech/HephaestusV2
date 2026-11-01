import Foundation

// docs/engine-api.md › File system.

/// `fs.browse`: lists folders of the main device. Actors: user.
public enum FSBrowse: EngineMethod {
    public static let name = "fs.browse"
    public struct Params: Codable, Sendable, Hashable {
        /// Absolute directory path. Default: the home directory of the user running the engine.
        public var path: String?

        public init(path: String? = nil) {
            self.path = path
        }
    }
    public typealias Result = BrowseResult
}
