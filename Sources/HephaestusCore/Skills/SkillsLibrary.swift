import Darwin
import Foundation

/// The skills library folder: `skills.*` reads and writes, SKILL.md parsing and the library
/// watcher (docs/skills.md › Library). Used only on the engine actor.
// DOC-GAP: the docs describe this work but name no Swift type for it; the type name is a
// design choice.
final class SkillsLibrary {
    /// The FSEvents watcher of the current library folder, while the engine runs.
    var watcher: SkillsLibraryWatcher?

    init() {}

    /// The `skills.list` result for a Snapshot and for `skills.changed`: every skill sorted by
    /// name; empty when the library cannot be read (docs/engine-api.md › Snapshot).
    func summaries(in folder: URL, log: LogSink? = nil) -> [SkillSummary] {
        ((try? SkillsLibraryReader.skills(in: folder, log: log)) ?? []).map(\.summary)
    }

    // MARK: Limits and paths (docs/engine-api.md › Limits, › Paths)

    /// Content returned by `skills.readFile`: 20 MiB; a larger file is returned without content.
    static let maximumReadSize = 20 * 1024 * 1024
    /// Text of `skills.writeFile`: 20 MiB of UTF-8.
    static let maximumWriteSize = 20 * 1024 * 1024

    /// A skill path received from a client: a trailing `/` is removed first; then `/`
    /// separators, no leading `/` and no `.`, `..` or empty components. `""` is refused.
    static func skillPath(_ value: String) throws -> String {
        var path = value
        if path.hasSuffix("/") {
            path.removeLast()
        }
        // DOC-GAP: docs/engine-api.md › Paths refuses `""` where a method does not accept it but
        // quotes no message; it uses the form `<param>: <reason>.`.
        guard !path.isEmpty else {
            throw EngineError.invalid("path", "name a file or folder of the skill")
        }
        guard !path.contains("\0") else {
            throw EngineError.invalid("path", "use a path without NUL characters")
        }
        do {
            return try ModelRules.relativePath(path, field: "path")
        } catch let error as ValidationError {
            throw EngineError(error)
        }
    }

    /// A skill name received from a client: the name format, else `invalid`.
    // DOC-GAP: the error tables of docs/engine-api.md › skills.get, skills.delete and the file
    // methods list only `notFound`; a malformed name fails with `invalid`, the rule of
    // docs/engine-api.md › Identifiers for every id.
    static func checkedName(_ name: String, field: String = "name") throws -> String {
        do {
            return try ModelRules.skillName(name, field: field)
        } catch let error as ValidationError {
            throw EngineError(error)
        }
    }

    /// A description written by the engine: line breaks converted to LF, then 1 to 1024
    /// characters.
    static func checkedDescription(_ description: String) throws -> String {
        do {
            return try ModelRules.skillDescription(ModelRules.normalizedLineBreaks(description))
        } catch let error as ValidationError {
            throw EngineError(error)
        }
    }

    // MARK: Files of a skill

    /// The FileContent of a file with the content rules of `files.read`: `text` for valid UTF-8
    /// without NUL bytes, `dataBase64` otherwise, neither above 20 MiB; `modified` truncated to
    /// milliseconds.
    static func fileContent(at url: URL, path: String) throws -> FileContent {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw EngineError.notFound("File", path)
        }
        guard info.st_mode & S_IFMT != S_IFDIR else {
            throw EngineError.invalid("path", "\(path) is a directory")
        }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec / 1_000_000) / 1000
        let modified = Date(timeIntervalSince1970: seconds)
        let size = Int(info.st_size)
        guard size <= maximumReadSize else {
            return FileContent(path: path, modified: modified, size: size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EngineError(.internal, "\(path) cannot be read: \(error.localizedDescription)")
        }
        guard data.count <= maximumReadSize else {
            return FileContent(path: path, modified: modified, size: data.count)
        }
        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return FileContent(path: path, text: text, modified: modified, size: data.count)
        }
        return FileContent(path: path, dataBase64: data.base64EncodedString(), modified: modified, size: data.count)
    }
}

extension Engine {
    /// The skills library folder: `skillsLibraryPath` with `~/` expanded, else `<data dir>/Skills`.
    var skillsLibraryFolder: URL {
        settings.skillsLibraryURL(dataDirectory: dataDirectory)
    }

    /// The `skills.list` result, or `[]` when the library cannot be read.
    func skillSummaries() -> [SkillSummary] {
        skillsLibrary.summaries(in: skillsLibraryFolder, log: log)
    }

    /// Startup step 4: creates the library folder when it is missing and starts watching it
    /// (docs/skills.md › Library).
    func startSkillsLibraryWatching() async {
        let folder = skillsLibraryFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.error(.skills, "the skills library \(folder.path) cannot be created: \(error.localizedDescription)")
        }
        watchSkillsLibrary(folder)
    }

    /// `settings.update` changed `skillsLibraryPath`: the engine uses the new folder, already
    /// created by the handler; skills of the previous folder are not moved (docs/skills.md ›
    /// Settings). The handler emits `skills.changed` afterwards.
    func skillsLibraryFolderDidChange() async {
        watchSkillsLibrary(skillsLibraryFolder)
    }

    /// docs/architecture.md › Shutdown, step 3: closes the library watcher.
    func stopSkillsLibraryWatching() async {
        skillsLibrary.watcher?.stop()
        skillsLibrary.watcher = nil
    }

    /// Replaces the watcher by one on `folder`: every change it sees, the engine's own writes
    /// included, emits `skills.changed` with origin `system` 300 ms after the last change.
    private func watchSkillsLibrary(_ folder: URL) {
        skillsLibrary.watcher?.stop()
        skillsLibrary.watcher = SkillsLibraryWatcher(folder: folder, log: log) { [weak self] in
            Task { await self?.skillsLibraryChangedOnDisk() }
        }
    }

    private func skillsLibraryChangedOnDisk() {
        guard skillsLibrary.watcher != nil else { return }
        emit(SkillsChangedEvent.self, skillSummaries(), origin: .system)
    }

    /// The library folder, created when missing; `unavailable` when it cannot be created or read.
    // DOC-GAP: docs/engine-api.md › skills.list fails with `unavailable` when the library folder
    // cannot be read or created but quotes no message.
    func readableSkillsLibraryFolder() throws -> URL {
        let folder = skillsLibraryFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try SkillsLibraryReader.entryNames(in: folder)
        } catch {
            throw EngineError(.unavailable, "The skills library \(folder.path) cannot be read: \(error.localizedDescription)")
        }
        return folder
    }

    /// The skill named `name`, else `notFound`.
    func existingSkill(_ name: String, in library: URL) throws -> LibrarySkill {
        guard let skill = SkillsLibraryReader.existingSkill(named: name, in: library, log: log) else {
            throw EngineError.notFound("Skill", name)
        }
        return skill
    }

    /// The Skill of the API for a skill read from disk.
    func apiSkill(_ skill: LibrarySkill) -> Skill {
        Skill(name: skill.name, description: skill.document.frontmatter.description, body: skill.document.body,
              extraFrontmatter: skill.document.frontmatter.extraFrontmatter, files: SkillsLibraryReader.extraFiles(of: skill.folder))
    }

    /// Writes a SKILL.md atomically and records the write (docs/data-model.md › Atomic writes).
    func writeSkillFile(_ document: SkillDocument, to url: URL) throws {
        do {
            let data = try document.encoded()
            let digest = try AtomicFile.write(data, to: url)
            ownWrites.recordWrite(path: url.path, sha256: digest)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        } catch {
            throw EngineError(.internal, "\(url.path) cannot be written: \(error.localizedDescription)")
        }
    }

    /// Moves an item of the library to the Trash; `unavailable` with
    /// `<path> cannot be moved to the Trash: <reason>.` when it cannot be.
    func moveSkillItemToTrash(_ url: URL) throws {
        try moveItemToTrash(url, path: url.path)
        ownWrites.recordRemoval(path: url.path)
    }

    /// Regenerates the skills plugin of a project after its `skills` list changed
    /// (docs/skills.md › Generation); a failure is logged, the next chat launch tries again.
    func regenerateSkillsPlugin(_ project: Project) {
        do {
            _ = try skillsPlugins.preparePlugin(projectID: project.id, skills: project.skills, library: skillsLibraryFolder,
                                                dataDirectory: dataDirectory)
        } catch {
            log.warn(.skills, "the skills plugin of \(project.id) could not be prepared: \(error)")
        }
    }
}
