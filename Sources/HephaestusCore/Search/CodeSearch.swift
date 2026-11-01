import Darwin
import Foundation

/// The code scope (docs/search.md › Code search): the file list of each project, the lines of
/// its text files, and at most 100 results, read in ranking order.
enum CodeSearch {
    /// Code results per query.
    static let maximumResults = 100
    /// Size of a code file read for its lines.
    static let maximumFileSize = 1_048_576
    /// Paths listed per project.
    static let maximumPaths = 50_000
    /// Directories the walk skips at any depth.
    static let skippedDirectoryNames: Set<String> = [".git", ".build", "build", "DerivedData", "node_modules"]
    /// The chats folder, which the code scope never reads.
    // DOC-GAP: docs/search.md › File list skips `.hephaestus/chats` in the walk and relies on
    // `.hephaestus/.gitignore` inside a git work tree; it is also left out of the git list, so that
    // the code scope never reads chat files, as docs/search.md › File list states.
    static let chatsFolder = ".hephaestus/chats"
    // DOC-GAP: docs/search.md › File list gives the git commands no timeout; a git command that
    // runs longer than this is ended and counts as failed, so a search cannot hang.
    static let gitTimeout: Duration = .seconds(30)

    /// A listed file with what its stat said.
    struct File: Sendable {
        var projectID: ProjectID
        var projectName: String
        /// Project path.
        var path: String
        var url: URL
        var size: Int
        var modified: Date
    }

    /// The code results of every project of the input, at most 100, collected in ranking order.
    static func results(_ input: SearchInput) async -> [RankedResult] {
        var files: [File] = []
        for data in input.projects {
            files += await fileList(data, git: input.git)
        }
        files.sort(by: readsBefore)
        var results: [RankedResult] = []
        for file in files {
            results += matches(in: file, terms: input.terms, limit: maximumResults - results.count)
            if results.count >= maximumResults { break }
        }
        return results
    }

    /// Files are read in ranking order: newest modification date first (one-second precision),
    /// then project identifier, then path.
    static func readsBefore(_ a: File, _ b: File) -> Bool {
        let dateA = RankedResult.seconds(a.modified), dateB = RankedResult.seconds(b.modified)
        if dateA != dateB { return dateA > dateB }
        let projects = RankedResult.numericOrder(a.projectID, b.projectID)
        if projects != .orderedSame { return projects == .orderedAscending }
        return RankedResult.numericOrder(a.path, b.path) == .orderedAscending
    }

    // MARK: File list

    /// The files of a project: `git ls-files` inside a git work tree, else a walk of the root;
    /// symbolic links, the chats folder and the folders of sub projects left out; sorted by path
    /// in byte order and cut to 50,000 paths.
    static func fileList(_ data: SearchProjectData, git: SearchGit?) async -> [File] {
        let root = data.root
        let excludedFolders = [chatsFolder] + data.project.subprojects.filter(ModelRules.isRelativePath)
        var paths: [String]
        if let git, let listed = await gitList(root: root, git: git) {
            paths = listed
        } else {
            paths = walk(root: root, excludedFolders: Set(excludedFolders))
        }
        paths.removeAll { path in excludedFolders.contains { path == $0 || path.hasPrefix($0 + "/") } }
        var files: [File] = []
        for path in paths {
            let url = root.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            files.append(File(projectID: data.project.id, projectName: data.project.name, path: path, url: url,
                              size: Int(info.st_size), modified: SearchRunner.modificationDate(info)))
        }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return Array(files.prefix(maximumPaths))
    }

    /// Inside a git work tree, tracked files plus untracked files that are not ignored, without
    /// duplicates and without entries ending with `/`; nil outside a work tree or when a command
    /// fails, which makes the caller walk the folder.
    static func gitList(root: URL, git: SearchGit) async -> [String]? {
        guard let inside = await runGit(git, ["-C", root.path, "rev-parse", "--is-inside-work-tree"]),
              inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
              let listing = await runGit(git, ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        else { return nil }
        var seen = Set<String>()
        return listing.split(separator: "\0").map(String.init).filter { !$0.hasSuffix("/") && seen.insert($0).inserted }
    }

    /// The standard output of a git command, or nil when it does not exit with status 0.
    private static func runGit(_ git: SearchGit, _ arguments: [String]) async -> String? {
        let request = ChildProcessRequest(executable: git.executable, arguments: arguments, environment: git.environment)
        guard let result = try? await ChildProcessRunner.run(request, timeout: gitTimeout),
              !result.timedOut, result.termination.isSuccess
        else { return nil }
        return result.standardOutputText
    }

    /// The regular files under `root`, recursively, as project paths; directories named `.git`,
    /// `.build`, `build`, `DerivedData` or `node_modules` at any depth, the folders of
    /// `excludedFolders` and symbolic links are skipped.
    static func walk(root: URL, excludedFolders: Set<String>) -> [String] {
        var paths: [String] = []
        func visit(_ directory: URL, prefix: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    paths.append(path)
                case S_IFDIR:
                    guard !skippedDirectoryNames.contains(name), !excludedFolders.contains(path) else { continue }
                    visit(url, prefix: path)
                default:
                    continue
                }
            }
        }
        visit(root, prefix: "")
        return paths
    }

    // MARK: Lines

    /// The lines of a text file that contain every term, at most `limit`. A file is read when it
    /// is at most 1 MB and is text: no NUL byte and valid UTF-8. Lines are separated by `\n`; a
    /// `\r` at the end of a line is removed before matching.
    static func matches(in file: File, terms: SearchTerms, limit: Int) -> [RankedResult] {
        guard limit > 0, file.size <= maximumFileSize, let data = try? Data(contentsOf: file.url),
              data.count <= maximumFileSize, !data.contains(0),
              let text = String(validating: data, as: UTF8.self), terms.allContained(in: text)
        else { return [] }
        var results: [RankedResult] = []
        var number = 0
        for var line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            number += 1
            if line.last == 0x0D {
                line = line.dropLast()
            }
            let lineText = String(decoding: line, as: UTF8.self)
            guard terms.allContained(in: lineText) else { continue }
            let result = SearchResult(id: "code:\(file.projectID):\(file.path):\(number)", kind: .code, projectID: file.projectID,
                                      title: "\(file.path):\(number)", subtitle: file.projectName,
                                      snippet: SearchSnippet.make(lineText, terms: terms.terms),
                                      target: .file(projectID: file.projectID, path: file.path, line: number))
            results.append(RankedResult(result: result, level: 3, date: file.modified, key: file.path, line: number))
            if results.count == limit { break }
        }
        return results
    }
}
