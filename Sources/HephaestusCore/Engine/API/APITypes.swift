import Foundation

// The API types of docs/engine-api.md › API types. Stage 1 declares only `ChatState`, which the
// persisted `ChatMeta` carries at runtime; the other API types are added with the engine API.

/// String enum, the `state` of a ChatMeta in the API (docs/engine-api.md › ChatState).
public enum ChatState: String, Codable, Sendable, Hashable, CaseIterable {
    case idle
    case starting
    case running
    case waitingPermission
    case waitingAnswers
    case error
}
