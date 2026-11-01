import Foundation
import Network
import Testing
@testable import HephaestusCore

/// `SyncSocket` on its own (docs/remote.md › Closing a connection).
@Suite("Sync socket")
struct SyncSocketTests {
    /// Network.framework answers the close frame itself, so the closing side often ends the TCP
    /// connection before the receiving side read the close frame; it must still see the code.
    @Test("A close frame sent right after a data frame reaches the peer with its code", arguments: [true, false])
    func closeAfterData(serverCloses: Bool) async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        let code: SyncCloseCode = serverCloses ? .goingAway : .normal
        var received: [UInt16?] = []
        for _ in 0..<25 {
            received += await withTaskGroup(of: UInt16?.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        let client = RawPeer(port: server.port)
                        guard await client.waitReady(), let accepted = await server.nextPeer(), await accepted.waitReady() else {
                            return nil
                        }
                        let (closing, peer) = serverCloses ? (accepted, client) : (client, accepted)
                        closing.socket.queue.async {
                            closing.socket.sendBinary(Data(repeating: 7, count: 497))
                            closing.socket.close(code)
                        }
                        return await peer.closeCode()
                    }
                }
                var codes: [UInt16?] = []
                for await code in group {
                    codes.append(code)
                }
                return codes
            }
        }
        let wrong = received.filter { $0 != code.rawValue }
        #expect(wrong.isEmpty, "\(wrong.count) of \(received.count) connections: \(Set(wrong.map { $0.map(String.init) ?? "open" }))")
    }
}
