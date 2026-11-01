import Foundation

// docs/engine-api.md › UI navigation.

/// `ui.open`: asks clients to show something; called by the MCP tool `open_in_app`.
/// Actors: user, claude.
public enum UIOpen: EngineMethod {
    public static let name = "ui.open"
    public struct Params: Codable, Sendable, Hashable {
        /// What to show.
        public var target: NavigationTarget
        /// Device whose windows show the target; absent means every client. Ignored for claude.
        public var deviceID: String?

        public init(target: NavigationTarget, deviceID: String? = nil) {
            self.target = target
            self.deviceID = deviceID
        }
    }
    public typealias Result = Empty
}
