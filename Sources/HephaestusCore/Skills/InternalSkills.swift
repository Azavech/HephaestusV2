import Foundation

/// The internal skills of HephaestusV2: their names, their default SKILL.md, read from the app's
/// resources, and the record of the defaults the engine wrote in the library folder
/// (docs/skills.md › Internal skills).
public enum InternalSkills {
    /// The names of the internal skills, sorted.
    public static let names = ["feedback", "finish-implementation", "implement-bundle", "implement-ticket"]

    public static func isInternal(_ name: String) -> Bool {
        names.contains(name)
    }

    /// The hidden file of the library folder that records the SHA-256 of the default SKILL.md the
    /// engine last wrote for each internal skill (docs/data-model.md › Skill file).
    static let recordFileName = ".internal-skills.json"

    private static let cache = DefaultCache()

    /// The default SKILL.md of an internal skill: the resource `skills/<name>/SKILL.md`, as is.
    public static func defaultContent(_ name: String) -> Data? {
        cache.content(name)
    }

    // MARK: Record

    /// The record of `library`: skill names to lowercase hexadecimal SHA-256 digests; empty when
    /// the file is missing or cannot be read as such an object.
    static func record(in library: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: library.appendingPathComponent(recordFileName)),
              let record = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return record
    }

    /// The record's file content: compact JSON with sorted keys and a final newline.
    static func recordData(_ record: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record) + Data("\n".utf8)
    }

    // MARK: Ensuring the defaults

    /// What `ensure` decided for one internal skill.
    enum Action: Equatable {
        /// Write the default SKILL.md: the file is missing, or it is an unedited copy of an older
        /// default.
        case writeDefault
        /// The file equals the default; its digest must be recorded.
        case recordDigest
        /// Nothing to do: the file is the recorded default, or a copy the user edited.
        case keep
    }

    /// The action for a skill whose SKILL.md has the digest `current` (nil when it is missing),
    /// with `recorded` the digest of the record and `defaultDigest` that of the app's default
    /// (docs/skills.md › Protection).
    static func action(current: String?, recorded: String?, defaultDigest: String) -> Action {
        guard let current else { return .writeDefault }
        if current == defaultDigest {
            return recorded == defaultDigest ? .keep : .recordDigest
        }
        // A copy whose digest is the recorded one was never edited: it takes the new default.
        return current == recorded ? .writeDefault : .keep
    }
}

/// Reads the default SKILL.md files once.
private final class DefaultCache: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: Data] = [:]

    func content(_ name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let data = contents[name] { return data }
        guard InternalSkills.isInternal(name),
              let url = Bundle.module.url(forResource: "SKILL", withExtension: "md", subdirectory: "skills/\(name)"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        contents[name] = data
        return data
    }
}

extension Engine {
    /// Writes the missing internal skills and lets an unedited copy take a new default, then
    /// records the digests of the defaults written (docs/skills.md › Protection). Called at engine
    /// start, when the library location changes and before a project's plugin is generated. A
    /// skill that cannot be written is logged and skipped.
    func ensureInternalSkills() {
        let library = skillsLibraryFolder
        let manager = FileManager.default
        var record = InternalSkills.record(in: library)
        let original = record
        for name in InternalSkills.names {
            guard let content = InternalSkills.defaultContent(name) else {
                log.error(.skills, "the internal skill \(name) cannot be written: its default is missing from the app")
                continue
            }
            let folder = library.appendingPathComponent(name, isDirectory: true)
            let file = folder.appendingPathComponent(SkillsLibraryReader.skillFileName)
            if SkillsLibraryReader.itemExists(folder), !SkillsLibraryReader.isDirectory(folder) {
                log.warn(.skills, "the internal skill \(name) cannot be written: \(folder.path) is not a folder")
                continue
            }
            let current = manager.fileExists(atPath: file.path) ? (try? Data(contentsOf: file)).map(AtomicFile.sha256) : nil
            if current == nil, manager.fileExists(atPath: file.path) {
                log.warn(.skills, "the internal skill \(name) cannot be written: \(file.path) cannot be read")
                continue
            }
            let defaultDigest = AtomicFile.sha256(content)
            switch InternalSkills.action(current: current, recorded: record[name], defaultDigest: defaultDigest) {
            case .keep:
                break
            case .recordDigest:
                record[name] = defaultDigest
            case .writeDefault:
                do {
                    try writeInternalSkillDefault(content, to: file)
                    record[name] = defaultDigest
                } catch {
                    log.warn(.skills, "the internal skill \(name) cannot be written: \(Engine.message(of: error))")
                }
            }
        }
        if record != original {
            do {
                try writeInternalSkillsRecord(record, in: library)
            } catch {
                log.warn(.skills, "\(library.appendingPathComponent(InternalSkills.recordFileName).path) cannot be written: \(Engine.message(of: error))")
            }
        }
    }

    /// Writes the default SKILL.md of an internal skill, creating its folder, and records the
    /// write as the engine's own.
    func writeInternalSkillDefault(_ content: Data, to file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let digest = try AtomicFile.write(content, to: file)
            ownWrites.recordWrite(path: file.path, sha256: digest)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        } catch {
            throw EngineError(.internal, "\(file.path) cannot be written: \(error.localizedDescription)")
        }
    }

    /// Writes `.internal-skills.json` of the library atomically.
    func writeInternalSkillsRecord(_ record: [String: String], in library: URL) throws {
        let url = library.appendingPathComponent(InternalSkills.recordFileName)
        do {
            let digest = try AtomicFile.write(try InternalSkills.recordData(record), to: url)
            ownWrites.recordWrite(path: url.path, sha256: digest)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        } catch {
            throw EngineError(.internal, "\(url.path) cannot be written: \(error.localizedDescription)")
        }
    }

    /// True when the internal skills are hidden from the actor: a claude actor whose chat is not
    /// a chat of the HephaestusV2 project, the external token and an answer token
    /// (docs/skills.md › Claude's skill tools).
    func hidesInternalSkills(from actor: Actor) -> Bool {
        guard actor.kind == .claude else { return false }
        guard let chatID = actor.chat, let chat = domain.chat(chatID), let hephaestus = hephaestusProjectID else { return true }
        return chat.projectID != hephaestus
    }

    /// `forbidden` `<name> is an internal skill of HephaestusV2: <consequence>`.
    static func internalSkillRefusal(_ name: String, _ consequence: String) -> EngineError {
        EngineError(.forbidden, "\(name) is an internal skill of HephaestusV2: \(consequence)")
    }
}
