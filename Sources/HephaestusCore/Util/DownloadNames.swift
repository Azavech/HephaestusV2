import Foundation

/// The names of downloaded files in a Downloads folder (docs/web-tabs.md › Downloads), shared by
/// the downloads of web tabs and the release assets of the Builds section
/// (docs/builds.md › Downloads).
public enum DownloadNames {
    /// The name without path separators: `/` and `:` replaced by `_`, trimmed; a name that is
    /// then empty, `.` or `..` becomes `download`.
    public static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "download" : trimmed
    }

    /// `name` in `folder`, else `base (n).ext` with the first n from 1 that `isTaken` refuses.
    public static func uniqueURL(in folder: URL, name: String, isTaken: (URL) -> Bool) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard isTaken(candidate) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 1
        while true {
            let numbered = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            let url = folder.appendingPathComponent(numbered)
            if !isTaken(url) { return url }
            number += 1
        }
    }
}
