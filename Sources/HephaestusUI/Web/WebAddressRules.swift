// OWNER: ui-web-search — the rules that turn typed text into a URL and rewrite loopback URLs in
// remote windows (docs/web-tabs.md › Typed addresses; docs/remote.md › Localhost rewrite).
import Darwin
import Foundation

/// The result of the URL field's text (docs/web-tabs.md › Typed addresses).
enum TypedAddress: Equatable {
    /// Rule 1: nothing is loaded and the field keeps the focus.
    case empty
    /// The URL to load.
    case url(URL)
    /// Rule 4, or a result that is not a valid URL: the system beep sounds and the text stays.
    case refused

    /// Applies the first matching rule of docs/web-tabs.md › Typed addresses to the typed text.
    static func resolve(_ typed: String) -> TypedAddress {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Rule 1.
        guard !text.isEmpty else { return .empty }
        let lowered = text.lowercased()
        // Rule 2.
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return validated(text)
        }
        let hasSpace = text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
        let host = hostPart(of: text)
        // Rule 3.
        if !hasSpace, isLocalHostPart(host) {
            return validated("http://" + text)
        }
        // Rule 4.
        if startsWithScheme(text) {
            return .refused
        }
        // Rule 5.
        if !hasSpace, host.contains(".") {
            return validated("https://" + text)
        }
        // Rule 6.
        return validated("https://www.google.com/search?q=" + percentEncodedQueryValue(text))
    }

    /// The text before the first `/`, `?` or `#`.
    static func hostPart(of text: String) -> String {
        String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }

    /// Rule 3's host part: `localhost`, an IPv4 address, a bracketed IPv6 address or a name ending
    /// in `.local`, each optionally followed by `:` and a port; or any host part ending in `:` and
    /// 1 to 5 digits.
    static func isLocalHostPart(_ hostPart: String) -> Bool {
        if endsWithPort(hostPart) { return true }
        let name = hostPart.lowercased()
        // Compared case-insensitively (docs/web-tabs.md › Typed addresses).
        return name == "localhost" || isIPv4(name) || isBracketedIPv6(name) || (name.hasSuffix(".local") && name.count > 6)
    }

    /// True when the text ends with `:` and 1 to 5 digits. A host part made of the port alone
    /// (`:3000`) matches too; its URL has no host and is refused.
    private static func endsWithPort(_ text: String) -> Bool {
        guard let colon = text.lastIndex(of: ":") else { return false }
        let digits = text[text.index(after: colon)...]
        return (1...5).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Four decimal numbers from 0 to 255 separated by dots.
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } && Int(part).map { $0 <= 255 } == true
        }
    }

    /// `[` + an IPv6 address + `]`.
    static func isBracketedIPv6(_ text: String) -> Bool {
        guard text.count > 2, text.hasPrefix("["), text.hasSuffix("]") else { return false }
        let inner = String(text.dropFirst().dropLast())
        var address = in6_addr()
        return inet_pton(AF_INET6, inner, &address) == 1
    }

    /// A letter, then letters, digits, `+`, `-` or `.`, then `:`.
    static func startsWithScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    /// The text percent-encoded as a query value: every character other than the unreserved ones
    /// of RFC 3986 is encoded, a space as `%20`.
    static func percentEncodedQueryValue(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The URL when the text is a valid absolute `http` or `https` URL with a host.
    private static func validated(_ text: String) -> TypedAddress {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return .refused }
        return .url(url)
    }
}

/// The parts of an absolute URL string around its host, so that a host can be replaced while the
/// scheme, user info, port, path, query and fragment stay as written.
struct URLHostParts: Equatable {
    /// Everything before the host: `scheme://` and the user info with its `@`.
    var prefix: String
    /// The host as written; an IPv6 literal keeps its brackets.
    var host: String
    /// Everything after the host: the port with its `:`, the path, the query and the fragment.
    var suffix: String

    /// Splits an absolute URL string with an authority (`scheme://…`); nil otherwise.
    init?(_ url: String) {
        guard let separator = url.range(of: "://") else { return nil }
        let scheme = url[..<separator.lowerBound]
        guard !scheme.isEmpty else { return nil }
        let afterScheme = url[separator.upperBound...]
        let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        let hostStart = authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authority.startIndex
        let hostAndPort = authority[hostStart...]
        let hostEnd: String.Index
        if hostAndPort.hasPrefix("[") {
            guard let bracket = hostAndPort.firstIndex(of: "]") else { return nil }
            hostEnd = hostAndPort.index(after: bracket)
        } else {
            hostEnd = hostAndPort.lastIndex(of: ":") ?? hostAndPort.endIndex
        }
        prefix = String(url[..<hostStart])
        host = String(url[hostStart..<hostEnd])
        suffix = String(url[hostEnd...])
    }

    /// The scheme, lowercased.
    var scheme: String {
        String(prefix.prefix { $0 != ":" }).lowercased()
    }

    /// The host without IPv6 brackets, lowercased, for comparisons.
    var comparableHost: String {
        LocalhostRewrite.comparable(host)
    }

    var string: String {
        prefix + host + suffix
    }
}

/// The localhost rewrite of windows that show a remote device (docs/remote.md › Localhost
/// rewrite). Windows that show This Mac never rewrite.
enum LocalhostRewrite {
    /// The loopback hosts, compared case-insensitively and without brackets.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// A host without IPv6 brackets, lowercased.
    static func comparable(_ host: String) -> String {
        var value = host
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.lowercased()
    }

    /// True when the URL is `http` or `https` and its host is `localhost`, `127.0.0.1` or `::1`.
    static func isLoopback(_ url: String) -> Bool {
        guard let parts = URLHostParts(url), parts.scheme == "http" || parts.scheme == "https" else { return false }
        return loopbackHosts.contains(parts.comparableHost)
    }

    /// The device address as written in a URL: an IPv6 literal in brackets.
    static func urlHost(forAddress address: String) -> String {
        if address.contains(":"), !address.hasPrefix("[") {
            return "[" + address + "]"
        }
        return address
    }

    /// Forward rewrite: a loopback `http` or `https` URL gets the device address as its host;
    /// every other URL is returned unchanged.
    static func forward(_ url: String, deviceAddress: String) -> String {
        guard var parts = URLHostParts(url), parts.scheme == "http" || parts.scheme == "https",
              loopbackHosts.contains(parts.comparableHost), !deviceAddress.isEmpty else { return url }
        parts.host = urlHost(forAddress: deviceAddress)
        return parts.string
    }

    /// Reverse rewrite: when the new URL's host is the device address and the stored URL's host is
    /// a loopback host, the new URL gets the stored URL's host back; otherwise it is unchanged.
    static func reverse(_ url: String, storedURL: String, deviceAddress: String) -> String {
        guard var parts = URLHostParts(url), let stored = URLHostParts(storedURL), !deviceAddress.isEmpty,
              parts.comparableHost == comparable(deviceAddress), loopbackHosts.contains(stored.comparableHost) else {
            return url
        }
        parts.host = stored.host
        return parts.string
    }
}

extension LocalhostRewrite {
    /// The device address of a window that shows a remote device; nil for This Mac. It is the
    /// paired record's host: the stored or typed host, or after a Bonjour connection the IPv4
    /// address of its remote endpoint (docs/remote.md › Device address). Web tabs and the requests
    /// of OpenAPI forms use it (docs/openapi.md › Sending a request).
    @MainActor
    static func deviceAddress(of window: WindowState?) -> String? {
        guard let window, let workspace = window.workspace, !workspace.isLocal else { return nil }
        let deviceID = workspace.deviceID
        return window.app?.pairedDevices.first { $0.id.uuidString == deviceID }?.host
            ?? workspace.remoteConnection?.device.host
    }
}
