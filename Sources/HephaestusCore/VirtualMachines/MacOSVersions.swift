import Foundation

/// The list of macOS versions for virtual machines that ipsw.me gives
/// (docs/virtual-machines.md › macOS versions).
public enum MacOSVersions {
    /// `GET` of this URL gives the list.
    public static let listURL = URL(string: "https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw")!
    /// The timeout of the request.
    public static let timeout: TimeInterval = 30

    /// The answer is not a JSON object with a `firmwares` array.
    public struct UnexpectedAnswer: Error, Sendable {}

    /// One element of `firmwares`, with the members the engine reads.
    private struct Firmware {
        var version: MacOSVersion
        var released: Date?
        /// The position in the answer, to keep its order among equal versions and dates.
        var index: Int
    }

    /// Reads the answer of ipsw.me: the elements of `firmwares` that have a `version`, a `buildid`
    /// and an `https` `url`, the first of each build, newest first. Throws `UnexpectedAnswer` for
    /// anything but a JSON object with a `firmwares` array.
    public static func parse(_ data: Data) throws -> [MacOSVersion] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = object["firmwares"] as? [Any] else {
            throw UnexpectedAnswer()
        }
        var seenBuilds: Set<String> = []
        var firmwares: [Firmware] = []
        for (index, element) in elements.enumerated() {
            guard let members = element as? [String: Any],
                  let version = members["version"] as? String, !version.isEmpty,
                  let build = members["buildid"] as? String, !build.isEmpty,
                  let urlText = members["url"] as? String, let url = URL(string: urlText),
                  url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                  seenBuilds.insert(build).inserted else { continue }
            let size = (members["filesize"] as? NSNumber)?.intValue ?? 0
            let released = (members["releasedate"] as? String).flatMap(ISODate.date(from:))
            firmwares.append(Firmware(
                version: MacOSVersion(version: version, build: build, url: urlText, sizeBytes: max(0, size),
                                      sha256: sha256(members["sha256sum"])),
                released: released, index: index))
        }
        firmwares.sort { first, second in
            let order = compare(first.version.version, second.version.version)
            if order != .orderedSame { return order == .orderedDescending }
            let firstDate = first.released ?? .distantPast
            let secondDate = second.released ?? .distantPast
            if firstDate != secondDate { return firstDate > secondDate }
            return first.index < second.index
        }
        return firmwares.map(\.version)
    }

    /// `sha256sum` in lowercase; nil when it is not 64 hexadecimal digits.
    private static func sha256(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 64,
              text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return text
    }

    /// Compares two versions number by number: `27.2.1` is after `27.2`, and `27.2` after `26.6.2`.
    /// A part that is not a number counts as 0.
    public static func compare(_ first: String, _ second: String) -> ComparisonResult {
        let firstParts = first.split(separator: ".").map { Int($0) ?? 0 }
        let secondParts = second.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(firstParts.count, secondParts.count) {
            let left = index < firstParts.count ? firstParts[index] : 0
            let right = index < secondParts.count ? secondParts[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// `unavailable` `The macOS versions cannot be read from ipsw.me: <reason>.`
    public static func unavailable(_ reason: String) -> EngineError {
        var reason = reason.split(whereSeparator: \.isNewline).joined(separator: " ")
        while reason.hasSuffix(".") {
            reason.removeLast()
        }
        return EngineError(.unavailable, "The macOS versions cannot be read from ipsw.me: \(reason).")
    }
}
