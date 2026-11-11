import Darwin
import Foundation

/// A running preview host that the engine sends commands to: the Mac host's process, or the iOS
/// host's connection (docs/views.md › Preview host).
protocol PreviewHostConnection: AnyObject, Sendable {
    func send(_ command: PreviewHost.Command)
    func stop()
}

extension PreviewHost: PreviewHostConnection {}

/// The connection of an iOS preview host (docs/views.md › Preview host): the engine listens on a
/// port of `127.0.0.1` and the app, launched in a simulator device with the port and a random
/// token, connects and sends the token as its first line; a connection without it is closed. The
/// commands and the messages are one JSON object per line on the connection; the lines of the
/// app's standard error come as messages `stderr` and the last 40 are kept. The host ends when the
/// connection closes, or when the engine gives up launching the app.
final class PreviewSimulatorHost: PreviewHostConnection, @unchecked Sendable {
    /// The wait for the app's connection after a launch, and the most launches.
    static let connectWait: Duration = .seconds(30)
    static let launches = 4

    let token = UUID().uuidString
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private var pending: [Data] = []
    private var errorTail: [String] = []
    private var ended = false
    private let onMessage: @Sendable (PreviewHost.Message) -> Void
    private let onEnd: @Sendable (String, [String]) -> Void

    /// Listens on a free port of `127.0.0.1`. `onMessage` receives each message; `onEnd` the end
    /// that the engine did not ask for, with its reason and the last lines of the standard error.
    init(onMessage: @escaping @Sendable (PreviewHost.Message) -> Void, onEnd: @escaping @Sendable (String, [String]) -> Void) throws {
        self.onMessage = onMessage
        self.onEnd = onEnd
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = descriptor
        let thread = Thread { [self] in acceptLoop(descriptor) }
        thread.name = "PreviewSimulatorHost.accept"
        thread.start()
    }

    /// The app connected with its token.
    var isConnected: Bool {
        lock.withLock { connection >= 0 }
    }

    /// The host stopped or failed.
    var isEnded: Bool {
        lock.withLock { ended }
    }

    /// The simulator could not run the app: the host ends with this reason.
    func fail(_ reason: String) {
        let tail: [String]? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            return errorTail
        }
        guard let tail else { return }
        closeSockets()
        onEnd(reason, tail)
    }

    /// Writes a command; the commands sent before the app connected wait for it.
    func send(_ command: PreviewHost.Command) {
        guard var data = try? JSONEncoder().encode(command) else { return }
        data.append(0x0A)
        let descriptor: Int32? = lock.withLock {
            guard !ended else { return nil }
            if connection < 0 {
                pending.append(data)
                return nil
            }
            return connection
        }
        if let descriptor { write(data, to: descriptor) }
    }

    /// Ends the host: the connection closes, which ends the app.
    func stop() {
        lock.withLock { ended = true }
        closeSockets()
    }

    // MARK: Socket

    private func closeSockets() {
        let (listening, connected) = lock.withLock { () -> (Int32, Int32) in
            defer {
                listener = -1
                connection = -1
            }
            return (listener, connection)
        }
        if listening >= 0 { close(listening) }
        if connected >= 0 {
            shutdown(connected, SHUT_RDWR)
            close(connected)
        }
    }

    private func acceptLoop(_ listening: Int32) {
        while true {
            var poller = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if lock.withLock({ ended || listener != listening }) { return }
            if ready <= 0 { continue }
            let accepted = accept(listening, nil, nil)
            if accepted < 0 { continue }
            var on: Int32 = 1
            setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = Data()
            guard let first = readLine(accepted, &buffer), String(decoding: first, as: UTF8.self) == token else {
                close(accepted)
                continue
            }
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let waiting: [Data]? = lock.withLock {
                guard !ended else { return nil }
                connection = accepted
                if listener >= 0 { close(listener) }
                listener = -1
                defer { pending = [] }
                return pending
            }
            guard let waiting else {
                close(accepted)
                return
            }
            for data in waiting { write(data, to: accepted) }
            readLoop(accepted, buffer)
            return
        }
    }

    /// One line from the socket, the bytes after it kept in `buffer`; nil at its end.
    private func readLine(_ descriptor: Int32, _ buffer: inout Data) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.firstIndex(of: 0x0A) == nil {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > 1024 { return nil }
        }
        let newline = buffer.firstIndex(of: 0x0A)!
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }

    private func readLoop(_ descriptor: Int32, _ initial: Data) {
        var buffer = initial
        var chunk = [UInt8](repeating: 0, count: 262_144)
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                receive(line)
            }
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
        }
        fail("the app ended in the iOS Simulator")
    }

    private func receive(_ line: Data) {
        guard let message = try? JSONDecoder().decode(PreviewHost.Message.self, from: line) else { return }
        if message.type == "stderr" {
            lock.withLock {
                errorTail.append(message.line ?? "")
                if errorTail.count > PreviewHost.stderrLines { errorTail.removeFirst(errorTail.count - PreviewHost.stderrLines) }
            }
            return
        }
        onMessage(message)
    }

    private func write(_ data: Data, to descriptor: Int32) {
        lock.withLock {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }
}
