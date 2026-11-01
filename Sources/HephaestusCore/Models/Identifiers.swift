import Foundation

public typealias ProjectID = String   // project identifier, for example "HEPH"
public typealias TicketID = String    // for example "HEPH-12"
public typealias BundleID = String    // for example "HEPH-B2"
public typealias ChatID = UUID        // also the Claude CLI session id

/// Formats of docs/data-model.md › Ids, and the identifier rules of docs/projects.md.
public enum Identifiers {
    /// `^[A-Z]{2,8}$`
    public static func isProjectID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (2...8).contains(bytes.count) && bytes.allSatisfy(isUppercaseLetter)
    }

    /// `^[A-Z]{2,8}-[1-9][0-9]*$`
    public static func isTicketID(_ value: String) -> Bool {
        split(value, bundle: false) != nil
    }

    /// `^[A-Z]{2,8}-B[1-9][0-9]*$`
    public static func isBundleID(_ value: String) -> Bool {
        split(value, bundle: true) != nil
    }

    /// `^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$`
    public static func isUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == 0x2D else { return false }
            } else {
                guard isHexDigit(byte) else { return false }
            }
        }
        return true
    }

    /// `^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}$`: the form of `<CHAT-ID>` in file names.
    public static func isUppercaseUUID(_ value: String) -> Bool {
        isUUID(value) && value == value.uppercased()
    }

    /// `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 64 characters.
    public static func isSkillName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 64, bytes.first != 0x2D, bytes.last != 0x2D else { return false }
        var previousWasHyphen = false
        for byte in bytes {
            if byte == 0x2D {
                if previousWasHyphen { return false }
                previousWasHyphen = true
            } else if (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) {
                previousWasHyphen = false
            } else {
                return false
            }
        }
        return true
    }

    /// `^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$`: a pairing code in display form.
    public static func isPairingCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 19 else { return false }
        let alphabet = Set(RandomIDs.crockfordAlphabet.map { $0.asciiValue! })
        for (index, byte) in bytes.enumerated() {
            if index % 5 == 4 {
                guard byte == 0x2D else { return false }
            } else {
                guard alphabet.contains(byte) else { return false }
            }
        }
        return true
    }

    /// `^[0-9a-f]{64}$`: the MCP external token.
    public static func isExternalToken(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// `^[A-Za-z]{2,8}$`: an identifier as the user may type it (docs/projects.md › Identifier rules).
    public static func isTypedProjectID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (2...8).contains(bytes.count) && bytes.allSatisfy { isUppercaseLetter($0) || (0x61...0x7A).contains($0) }
    }

    /// Uppercases an identifier received from a client or Claude, then validates it.
    public static func normalizedProjectID(_ value: String) -> ProjectID? {
        let upper = value.uppercased()
        return isProjectID(upper) ? upper : nil
    }

    /// Uppercases a ticket id received from a client or Claude, then validates it.
    public static func normalizedTicketID(_ value: String) -> TicketID? {
        let upper = value.uppercased()
        return isTicketID(upper) ? upper : nil
    }

    /// Uppercases a bundle id received from a client or Claude, then validates it.
    public static func normalizedBundleID(_ value: String) -> BundleID? {
        let upper = value.uppercased()
        return isBundleID(upper) ? upper : nil
    }

    /// `<IDENT>-<n>`
    public static func ticketID(project: ProjectID, number: Int) -> TicketID {
        "\(project)-\(number)"
    }

    /// `<IDENT>-B<n>`
    public static func bundleID(project: ProjectID, number: Int) -> BundleID {
        "\(project)-B\(number)"
    }

    /// The project identifier and number of a ticket id; nil when malformed or when the number
    /// does not fit in an `Int`.
    public static func parseTicketID(_ value: String) -> (project: ProjectID, number: Int)? {
        guard let parts = split(value, bundle: false), let number = Int(parts.number) else { return nil }
        return (parts.project, number)
    }

    /// The project identifier and number of a bundle id; nil when malformed or when the number
    /// does not fit in an `Int`.
    public static func parseBundleID(_ value: String) -> (project: ProjectID, number: Int)? {
        guard let parts = split(value, bundle: true), let number = Int(parts.number) else { return nil }
        return (parts.project, number)
    }

    /// The identifier part of a well-formed ticket or bundle id.
    public static func projectID(of ticketOrBundleID: String) -> ProjectID? {
        if let parts = split(ticketOrBundleID, bundle: false) { return parts.project }
        if let parts = split(ticketOrBundleID, bundle: true) { return parts.project }
        return nil
    }

    /// The identifier the New Project sheet suggests from a name: its letters without
    /// diacritics, uppercased, keeping only A to Z, first four of them; "" with fewer than 2.
    public static func suggestedProjectID(fromName name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let letters = folded.uppercased().unicodeScalars.filter { (0x41...0x5A).contains($0.value) }
        let suggestion = String(String.UnicodeScalarView(letters.prefix(4)))
        return suggestion.count >= 2 ? suggestion : ""
    }

    // MARK: - Private

    private static func split(_ value: String, bundle: Bool) -> (project: String, number: Substring)? {
        guard let dash = value.firstIndex(of: "-") else { return nil }
        let project = String(value[..<dash])
        guard isProjectID(project) else { return nil }
        var rest = value[value.index(after: dash)...]
        if bundle {
            guard rest.first == "B" else { return nil }
            rest = rest.dropFirst()
        }
        let bytes = Array(rest.utf8)
        guard let first = bytes.first, (0x31...0x39).contains(first),
              bytes.allSatisfy({ (0x30...0x39).contains($0) })
        else { return nil }
        return (project, rest)
    }

    private static func isUppercaseLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
