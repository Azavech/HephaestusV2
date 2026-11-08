import Foundation

/// The global memories of a chat launch (docs/memories.md › In chats).
struct GlobalMemoriesLaunch: Equatable {
    /// The global memories folder, absolute and without final `/`.
    var folder: String
    /// The folder exists, so the chat gets it with `--add-dir`.
    var exists: Bool
    /// `{{globalMemories}}` of the common prompt.
    var block: String
}

extension Engine {
    /// Resolves the global memories folder with the chat environment, creates it when it is
    /// missing, then renders `{{globalMemories}}` from its `MEMORY.md`; a `MEMORY.md` that cannot
    /// be read counts as missing (docs/memories.md › In chats, docs/chats.md › Rendered blocks).
    func globalMemoriesForLaunch(environment: [String: String]) -> GlobalMemoriesLaunch {
        let path = configuration.memoryFolders.globalMemoryFolder(environment: environment)
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        var exists = true
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            exists = false
            log.warn(.memories, "the global memories folder \(path) cannot be created: \(MemoryReadFailure.sentence(error.localizedDescription))")
        }
        var index: String?
        do {
            index = try readIndexTextForChange(in: folder)
        } catch {
            log.warn(.memories, MemoryReadFailure.sentence(Engine.message(of: error)))
        }
        return GlobalMemoriesLaunch(folder: path, exists: exists, block: Prompts.globalMemories(folder: path, index: index))
    }
}
