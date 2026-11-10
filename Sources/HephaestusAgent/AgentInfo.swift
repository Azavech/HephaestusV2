import Darwin
import Foundation

/// What the agent is: its version and the constants of its protocol
/// (docs/virtual-machines.md › Connection, › Messages).
enum AgentInfo {
    /// The agent's version, reported in its status.
    static let version = "1.1"
    /// The version of the protocol.
    static let protocolVersion = 1
    /// The port of the host on which the agent connects.
    static let hostPort: UInt32 = 47822
    /// The delay between two attempts to connect.
    static let retryDelay: TimeInterval = 2
}

/// A failed request: its message, one line, goes to the host as the response's `error`.
struct AgentError: Error {
    let message: String

    init(_ message: String) {
        self.message = message.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// The result of a request: the `result` object and the data part of the response.
struct AgentResult {
    var json: [String: Any] = [:]
    var data = Data()
}

/// Connects to the host over virtio-vsock and serves one connection at a time, for ever
/// (docs/virtual-machines.md › Connection).
enum AgentConnector {
    static func run() -> Never {
        while true {
            // This thread never ends: only a pool frees what Foundation autoreleases on it.
            autoreleasepool {
                let descriptor = connectToHost()
                if descriptor >= 0 {
                    AgentSession(input: descriptor, output: descriptor).run()
                    close(descriptor)
                }
            }
            Thread.sleep(forTimeInterval: AgentInfo.retryDelay)
        }
    }

    /// A stream socket connected to the port of the host (`AF_VSOCK`, CID 2), or -1.
    private static func connectToHost() -> Int32 {
        let descriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = AgentInfo.hostPort
        address.svm_cid = UInt32(VMADDR_CID_HOST)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
    }
}
