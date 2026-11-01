import CryptoKit
import Foundation
import Network
import Testing
@testable import HephaestusCore

/// `SyncSocket` on its own (docs/remote.md › Closing a connection).
@Suite("Sync socket")
struct SyncSocketTests {
    /// Network.framework answers the close frame itself, so the closing side often ends the TCP
    /// connection before the receiving side read the close frame; it must still see the code. On
    /// a busy machine Network.framework can also take longer than the close wait to send the
    /// frame. Every round closes 20 connections at once; the waits are long, so that a slow
    /// machine makes the test slower, not wrong.
    @Test("A close frame sent right after a data frame reaches the peer with its code", arguments: [true, false])
    func closeAfterData(serverCloses: Bool) async throws {
        let server = try await FakeSyncServer()
        defer { server.stop() }
        let code: SyncCloseCode = serverCloses ? .goingAway : .normal
        var received: [UInt16?] = []
        for _ in 0..<10 {
            let pairs = try await connectedPairs(20, server: server)
            received += await withTaskGroup(of: UInt16?.self) { group in
                for (client, accepted) in pairs {
                    group.addTask {
                        let (closing, peer) = serverCloses ? (accepted, client) : (client, accepted)
                        closing.socket.queue.async {
                            closing.socket.sendBinary(Data(repeating: 7, count: 497))
                            closing.socket.close(code)
                        }
                        return await peer.closeCode(timeout: .seconds(30))
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

    /// A peer that leaves the data in front of the close frame unread for longer than the close
    /// wait: the close frame cannot be sent before it reads, and must still reach it then.
    @Test("A close frame queued behind data that the peer reads late reaches it", arguments: [true, false])
    func closeBehindUnreadData(serverCloses: Bool) async throws {
        let frames = 24
        let (closing, stalled, done) = try await Self.stalledPair(serverCloses: serverCloses)
        defer { done() }
        let code: SyncCloseCode = serverCloses ? .goingAway : .normal
        closing.socket.queue.async {
            for _ in 0..<frames {
                closing.socket.sendBinary(Data(repeating: 7, count: 1 << 20))
            }
            closing.socket.close(code)
        }
        // 24 MiB, more than the buffers of a loopback connection hold, stay unread for 4 close
        // waits.
        try await Task.sleep(for: .seconds(SyncTimings.fast.closeWait * 4))
        let received = await stalled.readToEnd()
        #expect(StalledPeer.frames(in: received).filter { $0.opcode == 2 }.count == frames)
        #expect(StalledPeer.frames(in: received).first { $0.opcode == 8 }?.closeCode == code.rawValue)
    }

    @Test("A close frame behind data that the peer does not read is given up after the close limit")
    func closeLimit() async throws {
        // The peer never reads: the close frame stays behind the data.
        let (closing, _, done) = try await Self.stalledPair(serverCloses: false, closeLimit: 1)
        defer { done() }
        let start = ContinuousClock.now
        closing.socket.queue.async {
            for _ in 0..<24 {
                closing.socket.sendBinary(Data(repeating: 7, count: 1 << 20))
            }
            closing.socket.close(.normal)
        }
        await closing.socket.waitUntilEnded()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .seconds(1))
        #expect(elapsed < .seconds(20))
    }

    /// A `RawPeer` and a `StalledPeer` connected to each other, the raw peer on the server side
    /// when `serverCloses`; `done` closes what is left.
    private static func stalledPair(serverCloses: Bool, closeLimit: TimeInterval = SyncTimings.fast.closeLimit) async throws
        -> (RawPeer, StalledPeer, @Sendable () -> Void) {
        if serverCloses {
            let server = try await FakeSyncServer()
            let stalled = StalledPeer(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(server.port)),
                                                               using: .tcp))
            try #require(await stalled.ready())
            await stalled.send("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(StalledPeer.key)\r\nSec-WebSocket-Version: 13\r\n\r\n")
            let head = try #require(await stalled.readHead())
            try #require(head.hasPrefix("HTTP/1.1 101"))
            let accepted = try #require(await server.nextPeer(timeout: .seconds(30)))
            try #require(await accepted.waitReady(timeout: .seconds(30)))
            return (accepted, stalled, { server.stop(); stalled.connection.cancel() })
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        let accepted = Collected<NWConnection>()
        listener.newConnectionHandler = { accepted.append($0) }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnceThrowing(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(Int(listener.port!.rawValue)))
                case .failed(let error): once.resume(.failure(error))
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.stalled-listener"))
        }
        let client = RawPeer(port: port, closeLimit: closeLimit)
        #expect(await eventually(timeout: .seconds(30)) { !accepted.values.isEmpty })
        let stalled = StalledPeer(connection: try #require(accepted.values.first))
        try #require(await stalled.ready())
        let head = try #require(await stalled.readHead())
        let key = try #require(head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces))
        await stalled.send("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(StalledPeer.accept(key))\r\n\r\n")
        try #require(await client.waitReady(timeout: .seconds(30)))
        return (client, stalled, { listener.cancel(); stalled.connection.cancel() })
    }

    /// `count` open clients of `server`, each with the connection the server accepted for it.
    private func connectedPairs(_ count: Int, server: FakeSyncServer) async throws -> [(client: RawPeer, accepted: RawPeer)] {
        let clients = (0..<count).map { _ in RawPeer(port: server.port) }
        var accepted: [Int: RawPeer] = [:]
        for _ in 0..<count {
            let peer = try #require(await server.nextPeer(timeout: .seconds(30)))
            try #require(await peer.waitReady(timeout: .seconds(30)))
            let port = try #require(await peer.ports.remote)
            accepted[port] = peer
        }
        var pairs: [(client: RawPeer, accepted: RawPeer)] = []
        for client in clients {
            try #require(await client.waitReady(timeout: .seconds(30)))
            let port = try #require(await client.ports.local)
            pairs.append((client, try #require(accepted[port])))
        }
        return pairs
    }
}

/// The other end of a WebSocket as a plain TCP connection: the test makes or answers the upgrade
/// and reads only when it chooses, so that the sent frames wait in the buffers meanwhile.
final class StalledPeer: @unchecked Sendable {
    static let key = "dGhlIHNhbXBsZSBub25jZQ=="

    let connection: NWConnection
    private let queue = DispatchQueue(label: "test.stalled")
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection; true once it is ready.
    func ready() async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Flag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                case .waiting, .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// The HTTP head up to the empty line; the bytes after it stay in the buffer.
    func readHead() async -> String? {
        while true {
            if let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                return head
            }
            guard let chunk = await receive() else { return nil }
            buffer.append(chunk)
        }
    }

    /// Every byte until the other side ends the connection, or 30 s.
    func readToEnd() async -> Data {
        let connection = self.connection
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        while let chunk = await receive() {
            buffer.append(chunk)
        }
        return buffer
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: isComplete || error != nil ? nil : Data())
                }
            }
        }
    }

    /// The `Sec-WebSocket-Accept` value of `key` (RFC 6455 › 4.2.2).
    static func accept(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    struct Frame {
        var opcode: UInt8
        /// The payload of a control frame; empty for a data frame.
        var payload: [UInt8]

        /// The code of a close frame.
        var closeCode: UInt16? {
            payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil
        }
    }

    /// The complete frames of `data`, masked or not (RFC 6455 › 5.2).
    static func frames(in data: Data) -> [Frame] {
        let bytes = [UInt8](data)
        var frames: [Frame] = []
        var index = 0
        while index + 2 <= bytes.count {
            let opcode = bytes[index] & 0x0F
            let masked = bytes[index + 1] & 0x80 != 0
            var length = Int(bytes[index + 1] & 0x7F)
            index += 2
            let extra = length == 126 ? 2 : length == 127 ? 8 : 0
            guard index + extra <= bytes.count else { break }
            if extra > 0 {
                length = bytes[index..<index + extra].reduce(0) { $0 << 8 | Int($1) }
                index += extra
            }
            let mask = masked ? Array(bytes[min(index, bytes.count)..<min(index + 4, bytes.count)]) : []
            index += mask.count
            guard mask.count == (masked ? 4 : 0), index + length <= bytes.count else { break }
            var payload = opcode >= 8 ? Array(bytes[index..<index + length]) : []
            if masked {
                for offset in payload.indices {
                    payload[offset] ^= mask[offset % 4]
                }
            }
            frames.append(Frame(opcode: opcode, payload: payload))
            index += length
        }
        return frames
    }
}
