import Foundation
import Network

/// The timings of the sync protocol (docs/remote.md › Timeouts and limits). Tests shorten them;
/// the app always uses `standard`.
struct SyncTimings: Sendable {
    /// Client: from the start of the connection to WebSocket open.
    var connect: TimeInterval = 10
    /// Server: from accepting the TCP connection to the `hello`.
    var helloDeadline: TimeInterval = 10
    /// Client: after sending `hello`.
    var challengeDeadline: TimeInterval = 10
    /// Server: after sending `challenge`.
    var authDeadline: TimeInterval = 10
    /// Client: after sending `auth`.
    var welcomeDeadline: TimeInterval = 30
    /// Client: the keepalive ping.
    var pingInterval: TimeInterval = 15
    /// Client: nothing received for this long at a ping tick cancels the connection.
    var clientSilence: TimeInterval = 30
    /// Server: nothing received from an open session for this long cancels it.
    var serverSilence: TimeInterval = 45
    /// Both: the wait for the peer's close frame after sending one.
    var closeWait: TimeInterval = 2
    /// Client: the delays before successive attempts, the last one repeated.
    var backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    /// Server: the bind attempts and the delay between them.
    var bindAttempts = 5
    var bindRetryDelay: TimeInterval = 1

    static let standard = SyncTimings()

    /// The delay before the attempt that follows `failures` consecutive failed attempts.
    func backoffDelay(after failures: Int) -> TimeInterval {
        backoff[min(max(failures - 1, 0), backoff.count - 1)]
    }
}

/// One WebSocket connection of the sync protocol on Network.framework, used by the server's
/// sessions and by `RemoteEngineConnection` (docs/remote.md › Transport). Every method must be
/// called on `queue`, and the handler is called on it. Pings and pongs are reported as received
/// frames; close frames follow docs/remote.md › Closing a connection: the closing side sends its
/// code, then cancels when the peer's close frame arrives or after the close wait; a side that
/// receives a close frame cancels. No frame is reported after a close frame was sent or received.
/// A connection that fails while a receive is pending ends when that receive completes, so that a
/// close frame delivered with the error is reported first.
final class SyncSocket: @unchecked Sendable {
    enum Input {
        /// The WebSocket is open.
        case ready
        /// The connection cannot be established for now (client side).
        case waiting(NWError)
        case text(Data)
        case binary(Data)
        case ping
        case pong
        /// A close frame was received; the socket cancels itself.
        case close(UInt16)
        /// The connection ended; reported once, last.
        case ended(NWError?)
    }

    let connection: NWConnection
    let queue: DispatchQueue
    private let closeWait: TimeInterval
    private var handler: ((Input) -> Void)?
    /// Keeps the socket alive from `start` until the connection ended, so that a close frame's
    /// wait and cancel complete after its owner released it.
    private var retainedSelf: SyncSocket?
    private var endWaiters: [CheckedContinuation<Void, Never>] = []
    /// True once the WebSocket is open.
    private(set) var isReady = false
    /// True once a close frame was sent or received.
    private(set) var isClosing = false
    private var closeSent = false
    /// True once the connection ended.
    private(set) var hasEnded = false
    /// Bytes handed to the connection whose sending has not completed.
    private(set) var unsentBytes = 0
    /// True while a receive is pending.
    private var isReceiving = false
    /// The error of a connection that failed while a receive was pending, reported once that
    /// receive completed.
    private var failure: NWError?

    init(connection: NWConnection, queue: DispatchQueue, closeWait: TimeInterval) {
        self.connection = connection
        self.queue = queue
        self.closeWait = closeWait
    }

    /// TCP with WebSocket version 13, no TLS, no subprotocol, automatic pongs and the frame limit
    /// of docs/remote.md › Message size limits. `ipv4Only` is set for connections to Bonjour
    /// endpoints.
    static func parameters(ipv4Only: Bool = false, reuseLocalEndpoint: Bool = false) -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = reuseLocalEndpoint
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let webSocket = NWProtocolWebSocket.Options(.version13)
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = SyncLimits.binaryFrame
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    /// Starts the connection; `handler` receives every input until `.ended`.
    func start(_ handler: @escaping (Input) -> Void) {
        self.handler = handler
        retainedSelf = self
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        connection.start(queue: queue)
    }

    func sendText(_ data: Data) {
        send(data, opcode: .text)
    }

    func sendBinary(_ data: Data) {
        send(data, opcode: .binary)
    }

    /// A ping with an empty payload.
    func sendPing() {
        guard isReady, !isClosing, !hasEnded else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { _ in }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Sends a close frame with `code` and an empty reason, then cancels when the peer's close
    /// frame arrives or after the close wait. Without an open WebSocket it cancels at once.
    func close(_ code: SyncCloseCode) {
        guard !isClosing, !hasEnded else { return }
        isClosing = true
        guard isReady else {
            connection.cancel()
            return
        }
        closeSent = true
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code.webSocketCode
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        queue.asyncAfter(deadline: .now() + closeWait) { [weak self] in
            self?.connection.cancel()
        }
    }

    /// Cancels the connection without a close frame.
    func cancel() {
        isClosing = true
        connection.cancel()
    }

    /// Returns once the connection ended. May be called from any context.
    func waitUntilEnded() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.hasEnded {
                    continuation.resume()
                } else {
                    self.endWaiters.append(continuation)
                }
            }
        }
    }

    /// The IP address and port of the remote endpoint once connected; nil before.
    var remoteHostPort: (host: String, port: Int)? {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        return SyncAddress.hostPort(of: endpoint)
    }

    // MARK: Private

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        guard isReady, !isClosing, !hasEnded else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        let count = data.count
        unsentBytes += count
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.unsentBytes -= count
        })
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady, !hasEnded else { return }
            isReady = true
            receive()
            handler?(.ready)
        case .waiting(let error):
            guard !isReady, !hasEnded else { return }
            handler?(.waiting(error))
        case .failed(let error):
            guard isReceiving, !hasEnded else {
                end(error)
                return
            }
            // The pending receive may carry the peer's close frame: end when it completes, or
            // after the close wait if it never does.
            failure = error
            queue.asyncAfter(deadline: .now() + closeWait) { [weak self] in
                self?.end(error)
            }
        case .cancelled:
            end(nil)
        default:
            break
        }
    }

    private func receive() {
        isReceiving = true
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            self.isReceiving = false
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let error {
                // A close frame can arrive together with the error of the connection it ended.
                if let metadata, metadata.opcode == .close {
                    self.received(metadata, content: Data())
                }
                self.end(self.failure ?? error)
                return
            }
            if let metadata {
                self.received(metadata, content: content ?? Data())
            }
            if self.hasEnded {
                return
            }
            if context?.isFinal == true, metadata == nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func received(_ metadata: NWProtocolWebSocket.Metadata, content: Data) {
        switch metadata.opcode {
        case .close:
            let code = SyncCloseCode.number(of: metadata.closeCode)
            let reportsClose = !isClosing
            isClosing = true
            if reportsClose {
                handler?(.close(code))
            }
            connection.cancel()
        case .text:
            if !isClosing { handler?(.text(content)) }
        case .binary:
            if !isClosing { handler?(.binary(content)) }
        case .ping:
            if !isClosing { handler?(.ping) }
        case .pong:
            if !isClosing { handler?(.pong) }
        default:
            break
        }
    }

    private func end(_ error: NWError?) {
        guard !hasEnded else { return }
        hasEnded = true
        isClosing = true
        connection.cancel()
        let handler = self.handler
        self.handler = nil
        handler?(.ended(error))
        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        retainedSelf = nil
    }
}

/// Addresses in the forms of docs/remote.md: `host:port`, an IPv6 address in brackets.
enum SyncAddress {
    /// The host and port of an endpoint with an IP address or a host name; the zone of an IPv6
    /// address is dropped.
    static func hostPort(of endpoint: NWEndpoint?) -> (host: String, port: Int)? {
        guard case .hostPort(let host, let port)? = endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address):
            text = "\(address)"
        case .ipv6(let address):
            text = "\(address)"
        case .name(let name, _):
            text = name
        @unknown default:
            text = "\(host)"
        }
        let withoutZone = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        return (withoutZone, Int(port.rawValue))
    }

    /// `host:port`, with an IPv6 address in brackets.
    static func display(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The `ws://<host>:<port>/` URL of a stored or typed address.
    static func webSocketURL(host: String, port: Int) -> URL? {
        let urlHost = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        return URL(string: "ws://\(urlHost):\(port)/")
    }
}
