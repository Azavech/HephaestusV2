import Foundation
import Testing
@testable import HephaestusCore

/// docs/mcp.md › Request handling, steps 1 and 9, and docs/mcp.md › Status codes and Response
/// headers: the incremental parser and the serialized responses.
@Suite("MCP HTTP parser")
struct HTTPRequestParserTests {
    /// Parses one complete request: its head, then its body.
    static func parse(_ text: String) throws(HTTPParseError) -> (HTTPRequestHead, Data)? {
        var parser = HTTPRequestParser()
        parser.append(Data(text.utf8))
        guard let head = try parser.nextHead() else { return nil }
        parser.beginBody(of: head)
        guard let body = try parser.nextBody() else { return nil }
        return (head, body)
    }

    static func error(_ text: String) -> HTTPParseError? {
        do {
            _ = try parse(text)
            return nil
        } catch {
            return error
        }
    }

    @Test("A request with Content-Length: head fields, path and body")
    func contentLength() throws {
        let request = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization:   Bearer abc  \r\nContent-Length: 2\r\n\r\n{}"
        let (head, body) = try #require(try Self.parse(request))
        #expect(head.method == "POST")
        #expect(head.target == "/mcp?x=1")
        #expect(head.path == "/mcp")
        #expect(head.version == .http11)
        #expect(head.values("authorization") == ["Bearer abc"])
        #expect(head.contentLength == 2)
        #expect(!head.isChunked)
        #expect(head.keepsAlive)
        #expect(body == Data("{}".utf8))
    }

    @Test("Bytes arrive one at a time")
    func incremental() throws {
        let request = Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        var parser = HTTPRequestParser()
        var head: HTTPRequestHead?
        var index = 0
        while head == nil {
            parser.append(request[index..<index + 1])
            index += 1
            head = try parser.nextHead()
        }
        #expect(index == request.count - 5)
        parser.beginBody(of: try #require(head))
        var body: Data?
        while body == nil {
            body = try parser.nextBody()
            if body == nil {
                parser.append(request[index..<index + 1])
                index += 1
            }
        }
        #expect(body == Data("hello".utf8))
    }

    @Test("Without Content-Length or Transfer-Encoding the body is empty")
    func noBody() throws {
        let (head, body) = try #require(try Self.parse("POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n"))
        #expect(head.contentLength == nil)
        #expect(body.isEmpty)
    }

    @Test("Lines may end with LF alone, and empty lines before the request line are skipped")
    func lenientLines() throws {
        let (head, body) = try #require(try Self.parse("\r\n\nPOST /mcp HTTP/1.0\nContent-Length: 1\n\nx"))
        #expect(head.version == .http10)
        #expect(!head.keepsAlive)
        #expect(body == Data("x".utf8))
    }

    @Test("Pipelined requests are read one after the other")
    func pipelined() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 1\r\n\r\naPOST /mcp HTTP/1.1\r\nContent-Length: 1\r\n\r\nb".utf8))
        for expected in ["a", "b"] {
            let head = try #require(try parser.nextHead())
            parser.beginBody(of: head)
            #expect(try parser.nextBody() == Data(expected.utf8))
        }
        #expect(parser.bufferedByteCount == 0)
        #expect(try parser.nextHead() == nil)
    }

    @Test("Malformed heads get 400", arguments: [
        "POST /mcp HTTP/2.0\r\n\r\n",
        "POST /mcp\r\n\r\n",
        "POST  /mcp HTTP/1.1\r\n\r\n",
        "POST /mcp HTTP/1.1 extra\r\n\r\n",
        "PO(ST /mcp HTTP/1.1\r\n\r\n",
        "POST /mcp http/1.1\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nNoColon\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nBad Name: x\r\n\r\n",
        "POST /mcp HTTP/1.1\r\n: empty name\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nHost: x\r\n folded\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        "POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: 1x\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length:\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nX: a\u{0}b\r\n\r\n",
    ])
    func malformedHeads(request: String) {
        #expect(Self.error(request) == .malformed)
    }

    @Test("A head longer than 65 536 bytes gets 413; one of exactly 65 536 bytes is accepted")
    func headLimit() throws {
        let prefix = "POST /mcp HTTP/1.1\r\nX: "
        let exact = prefix + String(repeating: "a", count: 65_536 - prefix.utf8.count - 4) + "\r\n\r\n"
        #expect(exact.utf8.count == 65_536)
        #expect(try Self.parse(exact) != nil)
        let over = prefix + String(repeating: "a", count: 65_536 - prefix.utf8.count - 3) + "\r\n\r\n"
        #expect(Self.error(over) == .headTooLarge)

        var parser = HTTPRequestParser()
        parser.append(Data((prefix + String(repeating: "a", count: 70_000)).utf8))
        #expect(throws: HTTPParseError.headTooLarge) { try parser.nextHead() }
    }

    @Test("A Content-Length beyond the integer range is kept as the largest integer")
    func hugeContentLength() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n".utf8))
        let head = try #require(try parser.nextHead())
        #expect(head.contentLength == Int.max)
    }

    @Test("Chunked bodies: extensions and trailers ignored, precedence over Content-Length")
    func chunked() throws {
        let request = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: Chunked\r\nContent-Length: 3\r\n\r\n"
            + "4;name=value\r\n{\"a\"\r\n3 ; ext\r\n:1}\r\n0\r\nTrailer: x\r\n\r\n"
        let (head, body) = try #require(try Self.parse(request))
        #expect(head.isChunked)
        #expect(body == Data(#"{"a":1}"#.utf8))
    }

    @Test("A chunked body arriving in pieces")
    func chunkedIncremental() throws {
        let request = Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nA\r\n0123456789\r\n1\r\nx\r\n0\r\n\r\nNEXT".utf8)
        var parser = HTTPRequestParser()
        var index = 0
        var head: HTTPRequestHead?
        while head == nil {
            parser.append(request[index..<index + 1])
            index += 1
            head = try parser.nextHead()
        }
        parser.beginBody(of: try #require(head))
        var body: Data?
        while body == nil {
            body = try parser.nextBody()
            if body == nil {
                parser.append(request[index..<index + 1])
                index += 1
            }
        }
        #expect(body == Data("0123456789x".utf8))
        #expect(index == request.count - 4)
    }

    @Test("Malformed chunks get 400", arguments: [
        "zz\r\n",
        "\r\n",
        "4 x\r\nabcd\r\n0\r\n\r\n",
        "4\r\nabcdXY0\r\n\r\n",
        "-1\r\n",
    ])
    func malformedChunks(chunks: String) {
        #expect(Self.error("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + chunks) == .malformed)
    }

    @Test("A chunk-size line or a trailer section longer than 65 536 bytes is malformed")
    func chunkLineLimits() {
        let head = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(Self.error(head + "1;" + String(repeating: "e", count: 70_000)) == .malformed)
        #expect(Self.error(head + "0\r\n" + String(repeating: "T: x\r\n", count: 12_000) + "\r\n") == .malformed)
    }

    @Test("A chunked body beyond 4 194 304 bytes gets 413")
    func chunkedLimit() throws {
        let head = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(Self.error(head + "400001\r\n") == .bodyTooLarge)
        #expect(Self.error(head + "FFFFFFFFFFFFFFFFFFFFFFFF\r\n") == .bodyTooLarge)
        let chunk = String(repeating: "a", count: 0x200000)
        #expect(Self.error(head + "200000\r\n\(chunk)\r\n200000\r\n\(chunk)\r\n1\r\n") == .bodyTooLarge)
        let (_, body) = try #require(try Self.parse(head + "200000\r\n\(chunk)\r\n200000\r\n\(chunk)\r\n0\r\n\r\n"))
        #expect(body.count == HTTPRequestParser.bodyLimit)
    }

    @Test("Paths: query string removed, absolute-form targets, other forms kept")
    func paths() {
        func head(_ target: String) -> HTTPRequestHead {
            HTTPRequestHead(method: "POST", target: target, version: .http11, fields: [], contentLength: nil, isChunked: false)
        }
        #expect(head("/mcp").path == "/mcp")
        #expect(head("/mcp?token=1#x").path == "/mcp")
        #expect(head("/mcp/").path == "/mcp/")
        #expect(head("http://127.0.0.1:47820/mcp?x").path == "/mcp")
        #expect(head("*").path == "*")
    }

    @Test("Connection and Expect fields")
    func connectionFields() {
        func head(_ version: HTTPVersion, _ fields: [HTTPField]) -> HTTPRequestHead {
            HTTPRequestHead(method: "POST", target: "/mcp", version: version, fields: fields, contentLength: nil, isChunked: false)
        }
        #expect(head(.http11, []).keepsAlive)
        #expect(!head(.http11, [HTTPField(name: "connection", value: "keep-alive, Close")]).keepsAlive)
        #expect(!head(.http10, [HTTPField(name: "Connection", value: "keep-alive")]).keepsAlive)
        #expect(head(.http11, [HTTPField(name: "Expect", value: "100-Continue")]).expectsContinue)
        #expect(!head(.http11, [HTTPField(name: "Expect", value: "something")]).expectsContinue)
    }

    @Test("Rejections: exact texts, text/plain, Connection: close and their extra headers")
    func rejections() {
        let expected: [(HTTPRejection, Int, String)] = [
            (.malformed, 400, "Bad Request: malformed HTTP request."),
            (.unsupportedProtocolVersion("2024-11-05"), 400,
             "Bad Request: unsupported MCP-Protocol-Version 2024-11-05; supported: 2025-06-18, 2025-03-26."),
            (.unauthorized, 401, "Unauthorized: missing or invalid bearer token."),
            (.origin, 403, "Forbidden: requests with an Origin header are refused."),
            (.notFound, 404, "Not Found: the MCP endpoint is /mcp."),
            (.methodNotAllowed, 405, "Method Not Allowed: use POST."),
            (.headTooLarge, 413, "Content Too Large: the request head exceeds 65536 bytes."),
            (.bodyTooLarge, 413, "Content Too Large: the request body exceeds 4194304 bytes."),
        ]
        for (rejection, status, text) in expected {
            #expect(rejection.status == status)
            #expect(rejection.text == text)
            let response = rejection.response
            #expect(response.closes)
            #expect(response.contentType == "text/plain; charset=utf-8")
            #expect(response.body == Data(text.utf8))
        }
    }

    @Test("The 401 response is byte for byte the example of docs/mcp.md › Rejected request")
    func unauthorizedBytes() {
        let expected = """
        HTTP/1.1 401 Unauthorized\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: 46\r
        Cache-Control: no-store\r
        Connection: close\r
        WWW-Authenticate: Bearer realm="hephaestus"\r
        \r
        Unauthorized: missing or invalid bearer token.
        """
        #expect(String(decoding: HTTPRejection.unauthorized.response.serialized(), as: UTF8.self) == expected)
    }

    @Test("405 carries Allow: POST; 202 has no Content-Type and Content-Length 0")
    func otherResponses() {
        let notAllowed = String(decoding: HTTPRejection.methodNotAllowed.response.serialized(), as: UTF8.self)
        #expect(notAllowed.contains("\r\nAllow: POST\r\n"))
        #expect(!notAllowed.contains("WWW-Authenticate"))
        let accepted = String(decoding: HTTPResponse.accepted(closes: false).serialized(), as: UTF8.self)
        #expect(accepted == "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nCache-Control: no-store\r\n\r\n")
        let json = String(decoding: HTTPResponse.json(Data("{}".utf8), closes: true).serialized(), as: UTF8.self)
        #expect(json == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{}")
    }
}
