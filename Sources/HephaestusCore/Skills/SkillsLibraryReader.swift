import Darwin
import Foundation

/// A skill of the library as read from disk.
struct LibrarySkill: Hashable, Sendable {
    /// The folder name, which is the skill name.
    var name: String
    /// `<library>/<name>`: the folder, or the symbolic link to the folder.
    var folder: URL
    var document: SkillDocument
    /// Modification date of `SKILL.md`.
    var modified: Date

    var skillFile: URL { folder.appendingPathComponent(SkillsLibraryReader.skillFileName) }
    var summary: SkillSummary { SkillSummary(name: name, description: document.frontmatter.description) }
}

/// Reads the skills library folder (docs/skills.md › Library, docs/data-model.md › Skill file).
/// Every function reads the disk at each call; none needs the engine actor.
enum SkillsLibraryReader {
    static let skillFileName = "SKILL.md"

    /// The names of the entries directly inside the library folder; throws when the folder
    /// cannot be read.
    static func entryNames(in library: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: library.path)
    }

    /// Every skill of the library, sorted by name. An entry is a skill when it is a folder or a
    /// symbolic link to a folder, has a valid skill name and holds a readable SKILL.md; hidden
    /// entries and other entries are skipped, and every other skipped folder is logged.
    static func skills(in library: URL, log: LogSink?) throws -> [LibrarySkill] {
        try entryNames(in: library).compactMap { skill(named: $0, in: library, log: log) }.sorted { $0.name < $1.name }
    }

    /// The skill whose folder is the entry `name` of the library, compared exactly (a folder
    /// `Release-Notes` is not the skill `release-notes`), or nil when that entry is not a skill.
    static func existingSkill(named name: String, in library: URL, log: LogSink?) -> LibrarySkill? {
        guard Identifiers.isSkillName(name), let names = try? entryNames(in: library), names.contains(name) else { return nil }
        return skill(named: name, in: library, log: log)
    }

    /// True when the library entry `name` is a skill (docs/skills.md › Generation, step 1).
    static func isSkill(named name: String, in library: URL) -> Bool {
        existingSkill(named: name, in: library, log: nil) != nil
    }

    /// The entry `name` read as a skill, or nil when it is skipped.
    static func skill(named name: String, in library: URL, log: LogSink?) -> LibrarySkill? {
        guard !name.hasPrefix(".") else { return nil }
        let folder = library.appendingPathComponent(name, isDirectory: true)
        guard isDirectory(folder) else { return nil }
        // Hidden entries and entries that are not folders are skipped without a log line, every
        // other skipped folder is logged (docs/skills.md › Library).
        guard Identifiers.isSkillName(name) else {
            log?.warn(.skills, "\(folder.path) skipped: \(name) is not a valid skill name")
            return nil
        }
        let file = folder.appendingPathComponent(skillFileName)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            log?.warn(.skills, "\(folder.path) skipped: SKILL.md cannot be read")
            return nil
        }
        do {
            let document = try SkillDocument.parse(data, folderName: name)
            return LibrarySkill(name: name, folder: folder, document: document, modified: modificationDate(file) ?? Date(timeIntervalSince1970: 0))
        } catch {
            log?.warn(.skills, "\(folder.path) skipped: \(error)")
            return nil
        }
    }

    /// The skill paths of every regular file of a skill folder except its SKILL.md, recursively,
    /// skipping names that start with `.`, sorted by path. A symbolic link is neither listed nor
    /// followed (docs/data-model.md › SKILL.md format).
    static func extraFiles(of folder: URL) -> [String] {
        let caseSensitive = isCaseSensitiveVolume(folder)
        var files: [String] = []
        func walk(_ directory: URL, prefix: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if prefix.isEmpty, isSkillFile(path, caseSensitive: caseSensitive) { continue }
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG: files.append(path)
                case S_IFDIR: walk(url, prefix: path)
                default: continue
                }
            }
        }
        walk(folder, prefix: "")
        return files.sorted()
    }

    /// True when the skill path `path` names the skill's SKILL.md: equal to `SKILL.md`, or equal
    /// ignoring case on a case-insensitive volume, where `skill.md` is the same file
    /// (docs/skills.md › Skill files).
    static func isSkillFile(_ path: String, caseSensitive: Bool) -> Bool {
        path == skillFileName || (!caseSensitive && path.lowercased() == skillFileName.lowercased())
    }

    /// True when the volume holding `url` compares names case-sensitively.
    static func isCaseSensitiveVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
    }

    /// True when `url` is a folder or a symbolic link to a folder.
    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// True when something exists at `url`, a broken symbolic link included.
    static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The modification date of the item at `url`, following symbolic links.
    static func modificationDate(_ url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
