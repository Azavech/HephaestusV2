import Foundation
import UniformTypeIdentifiers

/// The response of a request sent from a form (docs/openapi.md › Response).
public struct OpenAPIHTTPResponse: Sendable {
    public var status: Int
    /// Sorted by name, case-insensitively.
    public var headers: [OpenAPIHeader]
    public var body: Data
    /// From the start of the request to the last byte of the body, in milliseconds.
    public var milliseconds: Int
    /// The `Content-Type` header.
    public var contentType: String?

    public init(status: Int, headers: [OpenAPIHeader], body: Data, milliseconds: Int, contentType: String?) {
        self.status = status
        self.headers = headers
        self.body = body
        self.milliseconds = milliseconds
        self.contentType = contentType
    }

    /// `<code> <reason phrase>`, or the code alone.
    public var statusText: String {
        OpenAPIHTTPClient.reasonPhrases[status].map { "\(status) \($0)" } ?? String(status)
    }

    /// The body as text when it is UTF-8 text, valid UTF-8 without NUL bytes; nil for a binary
    /// body (docs/openapi.md › Response).
    public var bodyText: String? {
        guard let text = String(data: body, encoding: .utf8), !text.contains("\0") else { return nil }
        return text
    }
}

/// The files that hold a response body on the Mac that received it: Quick Look's, and those of
/// `api_call` (docs/openapi.md › Response, docs/mcp.md › api_call).
public enum OpenAPIResponseFiles {
    /// `response.<extension>`, the extension coming from the media type of `contentType`;
    /// `response` alone when it has none.
    public static func name(contentType: String?) -> String {
        let essence = contentType.map(OpenAPISample.essence(of:)) ?? ""
        if let fileExtension = UTType(mimeType: essence)?.preferredFilenameExtension {
            return "response.\(fileExtension)"
        }
        return "response"
    }

    /// Writes `data` to `<temporary folder>/HephaestusV2/Files/<UUID>/<name>`, `file` for an empty
    /// name, and returns the file.
    public static func write(_ data: Data, name: String,
                             temporaryFolder: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = temporaryFolder
            .appendingPathComponent("HephaestusV2", isDirectory: true)
            .appendingPathComponent("Files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }
}

/// Sends the requests of the forms with `URLSession` on the Mac that shows the window
/// (docs/openapi.md › Sending a request).
public enum OpenAPIHTTPClient {
    /// The ephemeral session of the requests with the system's certificate check, and that of the
    /// requests that accept any server certificate. They never share a connection or a TLS session,
    /// so a server trusted for a request with `Allow invalid certificates` on is checked again for a
    /// request with it off (docs/openapi.md › Sending a request).
    static let checkingSession = makeSession()
    static let permissiveSession = makeSession()

    /// The session of a request.
    static func session(allowInvalidCertificates: Bool) -> URLSession {
        allowInvalidCertificates ? permissiveSession : checkingSession
    }

    /// An ephemeral session without cookie storage, cache or credential storage.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// Sends a request; `rewrite` changes the URL of the request and of each redirect (the localhost
    /// rewrite of windows that show a remote device). With `allowInvalidCertificates`, the request
    /// accepts any server certificate, on every server it reaches. Throws the session's error, or
    /// `CancellationError` when the task is cancelled.
    public static func send(_ request: URLRequest, rewrite: (@Sendable (URL) -> URL)? = nil,
                            allowInvalidCertificates: Bool = false) async throws -> OpenAPIHTTPResponse {
        var request = request
        if let rewrite, let url = request.url {
            request.url = rewrite(url)
        }
        let delegate = TaskDelegate(rewrite: rewrite, allowInvalidCertificates: allowInvalidCertificates)
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session(allowInvalidCertificates: allowInvalidCertificates).data(for: request, delegate: delegate)
        let elapsed = clock.now - start
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [OpenAPIHeader] = []
        for (name, value) in http.allHeaderFields {
            headers.append(OpenAPIHeader(name: String(describing: name), value: String(describing: value)))
        }
        headers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return OpenAPIHTTPResponse(status: http.statusCode, headers: headers, body: data, milliseconds: milliseconds,
                                   contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    /// How a request answers a server trust challenge: with `allowInvalidCertificates`, it trusts
    /// the server's certificate whatever it is; otherwise, and for every other challenge, the
    /// system's default handling applies (docs/openapi.md › Sending a request).
    static func trustDecision(authenticationMethod: String, serverTrust: SecTrust?, allowInvalidCertificates: Bool)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard allowInvalidCertificates, authenticationMethod == NSURLAuthenticationMethodServerTrust, let serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: serverTrust))
    }

    /// Applies the rewrite to every redirect, and answers the server trust challenges of the
    /// request and of its redirects.
    private final class TaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        let rewrite: (@Sendable (URL) -> URL)?
        let allowInvalidCertificates: Bool

        init(rewrite: (@Sendable (URL) -> URL)?, allowInvalidCertificates: Bool) {
            self.rewrite = rewrite
            self.allowInvalidCertificates = allowInvalidCertificates
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            OpenAPIHTTPClient.trustDecision(authenticationMethod: challenge.protectionSpace.authenticationMethod,
                                            serverTrust: challenge.protectionSpace.serverTrust,
                                            allowInvalidCertificates: allowInvalidCertificates)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let rewrite, let url = request.url else { return request }
            var rewritten = request
            rewritten.url = rewrite(url)
            return rewritten
        }
    }

    /// The reason phrases of RFC 9110 and RFC 6585.
    public static let reasonPhrases: [Int: String] = [
        100: "Continue", 101: "Switching Protocols",
        200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information", 204: "No Content",
        205: "Reset Content", 206: "Partial Content",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        305: "Use Proxy", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 406: "Not Acceptable", 407: "Proxy Authentication Required", 408: "Request Timeout",
        409: "Conflict", 410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large",
        414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed",
        421: "Misdirected Request", 422: "Unprocessable Content", 426: "Upgrade Required",
        428: "Precondition Required", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout", 505: "HTTP Version Not Supported", 511: "Network Authentication Required",
    ]
}
