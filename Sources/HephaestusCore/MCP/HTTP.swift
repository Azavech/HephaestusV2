import Foundation

// The HTTP/1.1 layer of the MCP server (docs/mcp.md › HTTP transport): an incremental request
// parser and the responses, with the exact rejection texts of docs/mcp.md › Status codes.

/// The HTTP version of a request line.
enum HTTPVersion: String, Sendable, Hashable {
    case http10 = "HTTP/1.0"
    case http11 = "HTTP/1.1"
}

/// One header field, its name as sent.
struct HTTPField: Sendable, Hashable {
    var name: String
    var value: String
}

/// The request line and the header fields of a request (docs/mcp.md › Request handling, step 1).
struct HTTPRequestHead: Sendable, Hashable {
    var method: String
    /// The request target as sent, query string included.
    var target: String
    var version: HTTPVersion
    var fields: [HTTPField]
    /// The digits of the one `Content-Length` field; `Int.max` when they overflow.
    var contentLength: Int?
    /// A `Transfer-Encoding: chunked` field is present; it takes precedence over `Content-Length`.
    var isChunked: Bool

    /// The values of the fields named `name`, compared case-insensitively, in order.
    func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// The path of the request target without its query string (docs/mcp.md › Request
    /// handling, step 3). An absolute-form target gives its path; any other form is returned as
    /// sent, so it never equals `/mcp`.
    var path: String {
        if target.hasPrefix("/") {
            return String(target.prefix { $0 != "?" && $0 != "#" })
        }
        if target.contains("://"), let components = URLComponents(string: target) {
            let path = components.percentEncodedPath
            return path.isEmpty ? "/" : path
        }
        return target
    }

    /// `Expect: 100-continue` (docs/mcp.md › Request headers).
    var expectsContinue: Bool {
        values("Expect").contains { $0.caseInsensitiveCompare("100-continue") == .orderedSame }
    }

    /// The connection stays open after the response: an HTTP/1.1 request without a `close`
    /// token in `Connection` (docs/mcp.md › Connections).
    var keepsAlive: Bool {
        guard version == .http11 else { return false }
        let tokens = values("Connection").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return !tokens.contains { $0.caseInsensitiveCompare("close") == .orderedSame }
    }
}

/// A request the parser refuses (docs/mcp.md › Status codes).
enum HTTPParseError: Error, Sendable, Hashable {
    /// 400 `Bad Request: malformed HTTP request.`
    case malformed
    /// 413 `Content Too Large: the request head exceeds 65536 bytes.`
    case headTooLarge
    /// 413 `Content Too Large: the request body exceeds 4194304 bytes.`
    case bodyTooLarge

    var rejection: HTTPRejection {
        switch self {
        case .malformed: return .malformed
        case .headTooLarge: return .headTooLarge
        case .bodyTooLarge: return .bodyTooLarge
        }
    }
}

/// Incremental HTTP/1.1 request parser (docs/mcp.md › Swift shape): the head with its
/// 65 536-byte limit, then a `Content-Length` or chunked body with its 4 194 304-byte limit.
/// Bytes after a complete request stay buffered for the next one, so pipelined requests are
/// read one after the other.
struct HTTPRequestParser: Sendable {
    /// Longest request head, its final empty line included (docs/mcp.md › Request handling).
    static let headLimit = 65_536
    /// Longest body, declared or decoded (docs/mcp.md › Request handling).
    static let bodyLimit = 4_194_304

    private enum BodyState: Sendable {
        case length(Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailers(bytes: Int)
    }

    private var buffer: [UInt8] = []
    private var start = 0
    private var bodyState: BodyState?
    private var body: [UInt8] = []

    /// Bytes received and not yet part of a parsed head or body.
    var bufferedByteCount: Int { buffer.count - start }

    mutating func append(_ data: Data) {
        if start > 0, start >= buffer.count / 2 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: data)
    }

    /// The next request head; nil when more bytes are needed. Empty lines before the request
    /// line are skipped.
    // DOC-GAP: docs/mcp.md › Request handling, step 1 does not mention empty lines before the
    // request line; they are skipped, as RFC 9112 › 2.2 recommends, for clients that end a body
    // with an extra CRLF.
    mutating func nextHead() throws(HTTPParseError) -> HTTPRequestHead? {
        while start < buffer.count {
            if buffer[start] == 0x0A {
                start += 1
            } else if buffer[start] == 0x0D, start + 1 < buffer.count, buffer[start + 1] == 0x0A {
                start += 2
            } else if buffer[start] == 0x0D, start + 1 == buffer.count {
                return nil
            } else {
                break
            }
        }
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = start
        var index = start
        var headEnd: Int?
        while index < buffer.count {
            if buffer[index] == 0x0A {
                var lineEnd = index
                if lineEnd > lineStart, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                if lineEnd == lineStart {
                    headEnd = index + 1
                    break
                }
                lines.append(buffer[lineStart..<lineEnd])
                lineStart = index + 1
            }
            index += 1
        }
        guard let end = headEnd else {
            if bufferedByteCount >= Self.headLimit { throw .headTooLarge }
            return nil
        }
        if end - start > Self.headLimit { throw .headTooLarge }
        let head = try Self.parseHead(lines)
        start = end
        return head
    }

    /// Starts reading the body of `head`, which `nextHead()` returned.
    mutating func beginBody(of head: HTTPRequestHead) {
        body = []
        if head.isChunked {
            bodyState = .chunkSize
        } else {
            bodyState = .length(head.contentLength ?? 0)
        }
    }

    /// The body of the request whose head was given to `beginBody(of:)`: the `Content-Length`
    /// bytes or the decoded chunks; nil when more bytes are needed.
    mutating func nextBody() throws(HTTPParseError) -> Data? {
        while let state = bodyState {
            switch state {
            case .length(let length):
                if length > Self.bodyLimit { throw .bodyTooLarge }
                guard bufferedByteCount >= length else { return nil }
                let data = Data(buffer[start..<start + length])
                start += length
                bodyState = nil
                return data
            case .chunkSize:
                guard let line = try nextLine() else { return nil }
                let size = try Self.chunkSize(line)
                if size > Self.bodyLimit - body.count { throw .bodyTooLarge }
                bodyState = size == 0 ? .trailers(bytes: 0) : .chunkData(remaining: size)
            case .chunkData(let remaining):
                let available = min(remaining, bufferedByteCount)
                guard available > 0 else { return nil }
                body.append(contentsOf: buffer[start..<start + available])
                start += available
                bodyState = available == remaining ? .chunkDataEnd : .chunkData(remaining: remaining - available)
            case .chunkDataEnd:
                guard let line = try nextLine() else { return nil }
                guard line.isEmpty else { throw .malformed }
                bodyState = .chunkSize
            case .trailers(let bytes):
                let before = start
                guard let line = try nextLine() else { return nil }
                // DOC-GAP: docs/mcp.md › Request handling, step 9 ignores trailer fields but sets
                // no limit on them; a trailer section longer than the head limit is malformed.
                let total = bytes + (start - before)
                if total > Self.headLimit { throw .malformed }
                if line.isEmpty {
                    bodyState = nil
                    let data = Data(body)
                    body = []
                    return data
                }
                bodyState = .trailers(bytes: total)
            }
        }
        return Data()
    }

    /// The next line of a chunked body without its CRLF or LF; nil when it is not complete.
    // DOC-GAP: docs/mcp.md › Request handling, step 9 sets no limit on a chunk-size line; one
    // longer than the head limit is malformed.
    private mutating func nextLine() throws(HTTPParseError) -> ArraySlice<UInt8>? {
        var index = start
        while index < buffer.count {
            if buffer[index] == 0x0A {
                var end = index
                if end > start, buffer[end - 1] == 0x0D { end -= 1 }
                let line = buffer[start..<end]
                start = index + 1
                return line
            }
            index += 1
            if index - start > Self.headLimit { throw .malformed }
        }
        if bufferedByteCount > Self.headLimit { throw .malformed }
        return nil
    }

    /// `1*HEXDIG [ BWS ";" chunk-ext ]`; a size that cannot fit the body limit counts as too large.
    private static func chunkSize(_ line: ArraySlice<UInt8>) throws(HTTPParseError) -> Int {
        var size = 0
        var digits = 0
        var index = line.startIndex
        while index < line.endIndex, let digit = hexValue(line[index]) {
            if size > bodyLimit {
                // Keeps scanning the digits but the size is already beyond the limit.
            } else {
                size = size * 16 + digit
            }
            digits += 1
            index += 1
        }
        guard digits > 0 else { throw .malformed }
        while index < line.endIndex, line[index] == 0x20 || line[index] == 0x09 {
            index += 1
        }
        if index < line.endIndex, line[index] != 0x3B { throw .malformed }
        return size
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41 + 10)
        case 0x61...0x66: return Int(byte - 0x61 + 10)
        default: return nil
        }
    }

    // MARK: Head

    /// docs/mcp.md › Request handling, step 1: `<method> <target> HTTP/1.1` or `HTTP/1.0`,
    /// fields `<name>: <value>`, at most one `Content-Length` made of digits, no
    /// `Transfer-Encoding` other than `chunked`.
    private static func parseHead(_ lines: [ArraySlice<UInt8>]) throws(HTTPParseError) -> HTTPRequestHead {
        guard let requestLine = lines.first else { throw .malformed }
        let parts = requestLine.split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy(isTokenByte),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0 > 0x20 && $0 != 0x7F }),
              let version = HTTPVersion(rawValue: latin1(parts[2]))
        else { throw .malformed }

        var fields: [HTTPField] = []
        var contentLength: Int?
        var contentLengthCount = 0
        var isChunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: 0x3A) else { throw .malformed }
            let name = line[line.startIndex..<colon]
            guard !name.isEmpty, name.allSatisfy(isTokenByte) else { throw .malformed }
            var value = line[(colon + 1)...]
            while let first = value.first, first == 0x20 || first == 0x09 { value = value.dropFirst() }
            while let last = value.last, last == 0x20 || last == 0x09 { value = value.dropLast() }
            guard value.allSatisfy({ $0 >= 0x20 && $0 != 0x7F || $0 == 0x09 }) else { throw .malformed }
            let field = HTTPField(name: latin1(name), value: latin1(value))
            fields.append(field)

            if field.name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLengthCount += 1
                guard contentLengthCount == 1, !value.isEmpty, value.allSatisfy({ (0x30...0x39).contains($0) }) else {
                    throw .malformed
                }
                var length = 0
                for digit in value {
                    let (times, overflow1) = length.multipliedReportingOverflow(by: 10)
                    let (sum, overflow2) = times.addingReportingOverflow(Int(digit - 0x30))
                    if overflow1 || overflow2 {
                        length = Int.max
                        break
                    }
                    length = sum
                }
                contentLength = length
            } else if field.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame {
                guard field.value.caseInsensitiveCompare("chunked") == .orderedSame else { throw .malformed }
                isChunked = true
            }
        }
        return HTTPRequestHead(method: latin1(parts[0]), target: latin1(parts[1]), version: version, fields: fields,
                               contentLength: contentLength, isChunked: isChunked)
    }

    /// `tchar` of RFC 9110 › 5.6.2.
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E: return true
        default: return false
        }
    }

    private static func latin1<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(bytes.map { Character(Unicode.Scalar($0)) })
    }
}

// MARK: - Responses

/// A rejected request: its status, its exact `text/plain` body and its extra headers
/// (docs/mcp.md › Status codes, Response headers).
enum HTTPRejection: Error, Sendable, Hashable {
    case malformed
    case unsupportedProtocolVersion(String)
    case unauthorized
    case origin
    case notFound
    case methodNotAllowed
    case headTooLarge
    case bodyTooLarge

    var status: Int {
        switch self {
        case .malformed, .unsupportedProtocolVersion: return 400
        case .unauthorized: return 401
        case .origin: return 403
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .headTooLarge, .bodyTooLarge: return 413
        }
    }

    var text: String {
        switch self {
        case .malformed:
            return "Bad Request: malformed HTTP request."
        case .unsupportedProtocolVersion(let value):
            return "Bad Request: unsupported MCP-Protocol-Version \(value); supported: \(MCPProtocol.versions.joined(separator: ", "))."
        case .unauthorized:
            return "Unauthorized: missing or invalid bearer token."
        case .origin:
            return "Forbidden: requests with an Origin header are refused."
        case .notFound:
            return "Not Found: the MCP endpoint is /mcp."
        case .methodNotAllowed:
            return "Method Not Allowed: use POST."
        case .headTooLarge:
            return "Content Too Large: the request head exceeds \(HTTPRequestParser.headLimit) bytes."
        case .bodyTooLarge:
            return "Content Too Large: the request body exceeds \(HTTPRequestParser.bodyLimit) bytes."
        }
    }

    /// The complete response; every rejection closes the connection.
    var response: HTTPResponse {
        var extra: [HTTPField] = []
        if self == .unauthorized {
            extra.append(HTTPField(name: "WWW-Authenticate", value: #"Bearer realm="hephaestus""#))
        }
        if self == .methodNotAllowed {
            extra.append(HTTPField(name: "Allow", value: "POST"))
        }
        return HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8), closes: true,
                            extraHeaders: extra)
    }
}

/// A response: status line, headers and body, and their serialization (docs/mcp.md › Response
/// headers).
struct HTTPResponse: Sendable, Hashable {
    var status: Int
    /// nil on 202.
    var contentType: String?
    var body: Data
    /// `Connection: close` is sent and the connection closes after the response.
    var closes: Bool
    /// `WWW-Authenticate` on 401, `Allow` on 405.
    var extraHeaders: [HTTPField] = []

    /// 200 with a JSON-RPC response.
    static func json(_ body: Data, closes: Bool) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: body, closes: closes)
    }

    /// 202 without a body.
    static func accepted(closes: Bool) -> HTTPResponse {
        HTTPResponse(status: 202, contentType: nil, body: Data(), closes: closes)
    }

    /// The interim response of `Expect: 100-continue` (docs/mcp.md › Request handling, step 8).
    static let continueBytes = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        default: return "Status"
        }
    }

    /// The bytes on the wire, headers in the order of the example of docs/mcp.md › Rejected
    /// request: Content-Type, Content-Length, Cache-Control, Connection, then the extra headers.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        if closes {
            head += "Connection: close\r\n"
        }
        for field in extraHeaders {
            head += "\(field.name): \(field.value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}
