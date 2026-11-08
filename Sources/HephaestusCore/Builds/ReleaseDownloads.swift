import CoreServices
import Foundation

/// The steps of `builds.downloadAsset` around the gh run (docs/builds.md › Downloads): the pattern
/// that matches one asset, the move into the Downloads folder under a free name, and the
/// quarantine attributes of a web download.
enum ReleaseDownloads {
    /// The asset's name with `\` written before each `\`, `*`, `?` and `[`, so that the glob pattern
    /// of `gh release download --pattern` matches that name only.
    static func pattern(forAsset name: String) -> String {
        var pattern = ""
        for character in name {
            if character == "\\" || character == "*" || character == "?" || character == "[" {
                pattern.append("\\")
            }
            pattern.append(character)
        }
        return pattern
    }

    /// The file gh saved in `folder`: `<asset>`, else the only regular file of the folder; nil
    /// when gh saved none.
    static func downloadedFile(in folder: URL, asset: String) -> URL? {
        let manager = FileManager.default
        let expected = folder.appendingPathComponent(asset, isDirectory: false)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: expected.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return expected
        }
        let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        let files = entries.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        return files.count == 1 ? files[0] : nil
    }

    /// Moves `file` into `downloads` with the asset's name under the rules of a web download
    /// (docs/web-tabs.md › Downloads): ` (1)`, ` (2)`, … inserted before the extension when the
    /// name is taken, also when another download takes it meanwhile. A name is taken by any item,
    /// a symbolic link that leads nowhere included, as the move sees it.
    static func move(_ file: URL, asset: String, into downloads: URL) throws -> URL {
        let manager = FileManager.default
        let name = DownloadNames.safeName(asset)
        var refused: Set<String> = []
        while true {
            let destination = DownloadNames.uniqueURL(in: downloads, name: name) { candidate in
                refused.contains(candidate.path) || (try? manager.attributesOfItem(atPath: candidate.path)) != nil
            }
            do {
                try manager.moveItem(at: file, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                refused.insert(destination.path)
            }
        }
    }

    /// The quarantine attributes of a web download, with the asset's URL and the release's page,
    /// so that Gatekeeper checks the file when it is opened.
    static func quarantine(_ file: URL, owner: String, name: String, tag: String, asset: String) {
        var properties: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        if let assetURL = releaseURL(owner: owner, name: name, components: ["download", tag, asset]) {
            properties[kLSQuarantineDataURLKey as String] = assetURL
        }
        if let pageURL = releaseURL(owner: owner, name: name, components: ["tag", tag]) {
            properties[kLSQuarantineOriginURLKey as String] = pageURL
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var url = file
        try? url.setResourceValues(values)
    }

    /// `https://github.com/<owner>/<name>/releases/<components>`, each component percent-encoded.
    static func releaseURL(owner: String, name: String, components: [String]) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return URL(string: "https://github.com/\(owner)/\(name)/releases/" + encoded.joined(separator: "/"))
    }
}
