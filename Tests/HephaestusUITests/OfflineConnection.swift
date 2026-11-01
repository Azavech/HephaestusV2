import Foundation
import HephaestusCore
@testable import HephaestusUI

/// A connection that never connects and refuses every call: a test sets the workspace's data
/// itself.
final class OfflineConnection: EngineConnection, @unchecked Sendable {
    var deviceInfo: DeviceInfo? { nil }
    var state: ConnectionState { .connecting }
    var stateUpdates: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }
    var events: AsyncStream<EngineEventEnvelope> { AsyncStream { $0.finish() } }
    func call<M: EngineMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        throw EngineError(.unavailable, "Offline.")
    }
    func close() {}
}
