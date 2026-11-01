import Foundation
@testable import HephaestusText

/// The renderer options of a Markdown fixture pair: `<name>.options.json` when it exists,
/// otherwise the options of the path resolution examples of docs/documentation-viewer.md
/// (`baseDirectory` `docs`, `projectRootPath` `/Users/example/Developer/App`) with
/// `stripFrontMatter` true, as for the doc preview.
enum MarkdownFixtureOptions {
    struct File: Decodable {
        var baseDirectory: String?
        var projectRootPath: String?
        var stripFrontMatter: Bool?
    }

    static let standard = MarkdownRenderOptions(baseDirectory: "docs", projectRootPath: "/Users/example/Developer/App",
                                                stripFrontMatter: true)

    static func load(for markdownFile: URL) throws -> MarkdownRenderOptions {
        let url = markdownFile.deletingPathExtension().appendingPathExtension("options.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return standard }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return MarkdownRenderOptions(baseDirectory: file.baseDirectory ?? standard.baseDirectory,
                                     projectRootPath: file.projectRootPath ?? standard.projectRootPath,
                                     stripFrontMatter: file.stripFrontMatter ?? standard.stripFrontMatter)
    }
}
