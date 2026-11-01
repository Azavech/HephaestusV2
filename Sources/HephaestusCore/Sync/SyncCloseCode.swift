import Foundation
import Network

/// The close codes of the sync protocol (docs/remote.md › Close codes). 1000–1011 are RFC 6455
/// codes; 4001–4009 are private codes of this protocol. Close frames carry the code and an empty
/// reason.
public enum SyncCloseCode: UInt16, Error, Sendable, Hashable, CaseIterable {
    /// Normal: no window shows the device any more, the device is removed, the app quits, an Add
    /// Device attempt is cancelled or replaces the connection, the `welcome` came from another
    /// device, or the side's next counter would be 2^64.
    case normal = 1000
    /// Going away: the server stops.
    case goingAway = 1001
    /// Protocol error: malformed or unexpected message, wrong frame type, invalid base64.
    case protocolError = 1002
    /// Message too big: a message exceeds the limit of its phase.
    case messageTooBig = 1009
    /// Internal error: building the snapshot failed.
    case internalError = 1011
    /// `hello.protocol` is not 1.
    case unsupportedProtocol = 4001
    /// A proof did not verify.
    case authenticationFailed = 4002
    /// Regenerate on the main device.
    case pairingCodeChanged = 4003
    /// A frame shorter than 28 bytes, a non-zero nonce prefix, or a failed tag check.
    case decryptionFailed = 4004
    /// The frame counter differs from the expected counter.
    case unexpectedCounter = 4005
    /// A handshake deadline expired.
    case handshakeTimeout = 4006
    /// `hello.deviceID` is the server's own device id.
    case sameDevice = 4007
    /// A newer session with the same device id authenticated.
    case replaced = 4008
    /// The session's send queue exceeds 64 MiB.
    case tooSlow = 4009

    /// The code a connection that ends without a close frame counts as.
    public static let abnormalClosure: UInt16 = 1006

    /// The Network.framework form of the code.
    var webSocketCode: NWProtocolWebSocket.CloseCode {
        switch self {
        case .normal: return .protocolCode(.normalClosure)
        case .goingAway: return .protocolCode(.goingAway)
        case .protocolError: return .protocolCode(.protocolError)
        case .messageTooBig: return .protocolCode(.messageTooBig)
        case .internalError: return .protocolCode(.internalServerError)
        default: return .privateCode(rawValue)
        }
    }

    /// The numeric value of a received close code.
    static func number(of code: NWProtocolWebSocket.CloseCode) -> UInt16 {
        switch code {
        case .protocolCode(let defined): return defined.rawValue
        case .applicationCode(let value), .privateCode(let value): return value
        @unknown default: return abnormalClosure
        }
    }
}
