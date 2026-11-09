import Foundation

/// A name and a value, in order: request and response headers, added headers.
public struct OpenAPIHeader: Sendable, Hashable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A credential typed in a form, applied to the request (docs/openapi.md › Sending a request).
public enum OpenAPICredential: Sendable, Equatable {
    /// `location` is `query`, `header` or `cookie`.
    case apiKey(name: String, location: String, value: String)
    case basic(username: String, password: String)
    case bearer(token: String)
}

/// What a request form holds when Send is clicked.
public struct OpenAPIRequestInput: Sendable, Equatable {
    /// The base URL of the selected environment (`ProjectEnvironment.baseURL`).
    public var baseURL: String
    /// Lowercase or uppercase.
    public var method: String
    /// The operation's path, with its `{name}` templates.
    public var path: String
    /// Every parameter of the form, in its order, with the value typed (possibly empty).
    public var parameters: [(location: OpenAPIParameterLocation, name: String, value: String)]
    public var credentials: [OpenAPICredential]
    /// The selected media type, when the operation has a request body.
    public var mediaType: String?
    /// The body of the selected media type.
    public var body: String
    /// Added headers.
    public var headers: [OpenAPIHeader]

    public init(baseURL: String, method: String, path: String,
                parameters: [(location: OpenAPIParameterLocation, name: String, value: String)] = [],
                credentials: [OpenAPICredential] = [], mediaType: String? = nil, body: String = "",
                headers: [OpenAPIHeader] = []) {
        self.baseURL = baseURL
        self.method = method
        self.path = path
        self.parameters = parameters
        self.credentials = credentials
        self.mediaType = mediaType
        self.body = body
        self.headers = headers
    }

    public static func == (lhs: OpenAPIRequestInput, rhs: OpenAPIRequestInput) -> Bool {
        lhs.baseURL == rhs.baseURL && lhs.method == rhs.method && lhs.path == rhs.path
            && lhs.parameters.map { "\($0.location):\($0.name)=\($0.value)" } == rhs.parameters.map { "\($0.location):\($0.name)=\($0.value)" }
            && lhs.credentials == rhs.credentials && lhs.mediaType == rhs.mediaType && lhs.body == rhs.body
            && lhs.headers == rhs.headers
    }
}

/// Builds the URL, headers and body of a request (docs/openapi.md › Sending a request).
public enum OpenAPIRequestBuilder {
    /// The RFC 3986 unreserved characters.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Every byte outside the unreserved characters percent-encoded.
    public static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// The base URL trimmed, without a trailing `/`.
    public static func normalizedBaseURL(_ text: String) -> String {
        var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    /// True for an absolute `http` or `https` URL with a host.
    public static func isUsableBaseURL(_ text: String) -> Bool {
        guard let url = URL(string: normalizedBaseURL(text)), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// The request URL: base URL, path with its parameters, then the query.
    public static func url(for input: OpenAPIRequestInput) -> String {
        var path = input.path
        for parameter in input.parameters where parameter.location == .path {
            path = path.replacingOccurrences(of: "{\(parameter.name)}", with: percentEncoded(parameter.value))
        }
        var pairs = input.parameters.filter { $0.location == .query && !$0.value.isEmpty }.map { ($0.name, $0.value) }
        for credential in input.credentials {
            if case .apiKey(let name, "query", let value) = credential, !value.isEmpty {
                pairs.append((name, value))
            }
        }
        let base = normalizedBaseURL(input.baseURL)
        var url = base + path
        if !pairs.isEmpty {
            let query = pairs.map { percentEncoded($0.0) + "=" + percentEncoded($0.1) }.joined(separator: "&")
            url += (base.contains("?") ? "&" : "?") + query
        }
        return url
    }

    /// The request headers, in order; an added header replaces a header of the same name.
    public static func headers(for input: OpenAPIRequestInput) -> [OpenAPIHeader] {
        var headers: [OpenAPIHeader] = []
        for parameter in input.parameters where parameter.location == .header && !parameter.value.isEmpty {
            headers.append(OpenAPIHeader(name: parameter.name, value: parameter.value))
        }
        var cookies = input.parameters.filter { $0.location == .cookie && !$0.value.isEmpty }.map { "\($0.name)=\($0.value)" }
        for credential in input.credentials {
            if case .apiKey(let name, "cookie", let value) = credential, !value.isEmpty {
                cookies.append("\(name)=\(value)")
            }
        }
        if !cookies.isEmpty {
            headers.append(OpenAPIHeader(name: "Cookie", value: cookies.joined(separator: "; ")))
        }
        for credential in input.credentials {
            if case .apiKey(let name, "header", let value) = credential, !value.isEmpty {
                headers.append(OpenAPIHeader(name: name, value: value))
            }
        }
        for credential in input.credentials {
            if case .basic(let username, let password) = credential, !username.isEmpty || !password.isEmpty {
                let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
                headers.append(OpenAPIHeader(name: "Authorization", value: "Basic \(encoded)"))
            }
        }
        for credential in input.credentials {
            if case .bearer(let token) = credential, !token.isEmpty {
                headers.append(OpenAPIHeader(name: "Authorization", value: "Bearer \(token)"))
            }
        }
        if let mediaType = input.mediaType, !input.body.isEmpty {
            headers.append(OpenAPIHeader(name: "Content-Type", value: mediaType))
        }
        for added in input.headers where !added.name.trimmingCharacters(in: .whitespaces).isEmpty {
            let name = added.name.trimmingCharacters(in: .whitespaces)
            headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            headers.append(OpenAPIHeader(name: name, value: added.value))
        }
        return headers
    }

    /// The request, or nil when its URL is not valid.
    public static func request(for input: OpenAPIRequestInput) -> URLRequest? {
        guard isUsableBaseURL(input.baseURL), let url = URL(string: url(for: input)) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = input.method.uppercased()
        for header in headers(for: input) {
            // Several headers of the same name are sent as one, separated by commas.
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if input.mediaType != nil, !input.body.isEmpty {
            request.httpBody = Data(input.body.utf8)
        }
        return request
    }
}
