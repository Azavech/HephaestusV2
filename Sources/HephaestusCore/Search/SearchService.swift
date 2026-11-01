import Darwin
import Foundation

/// `search.query`: sources, matching, ranking, snippets and code search (docs/search.md). The
/// handler copies the in-memory data it needs on the engine actor and reads files in a child
/// task (docs/search.md › Engine method). Used only on the engine actor
/// (docs/architecture.md › HephaestusCore folders).
final class SearchService {
    /// The texts of the transcripts, kept between queries (docs/search.md › Sources, Chats).
    let transcripts = TranscriptTextCache()

    init() {}
}

/// What one search reads: the copied in-memory data of the projects in the filter, the library
/// folder, the scopes and the git tool.
struct SearchInput: Sendable {
    var terms: SearchTerms
    var scopes: Set<SearchScope>
    /// Maximum number of results, 1–1,000.
    var limit: Int
    /// The projects in the filter, depth first.
    var projects: [SearchProjectData]
    /// The skills library folder; nil when the skills scope is not searched.
    var skillsLibrary: URL?
    /// The git executable and its environment; nil when git is not used.
    var git: SearchGit?
}

/// The data of one project in the filter.
struct SearchProjectData: Sendable {
    var project: Project
    /// The project folder.
    var root: URL
    var tickets: [Ticket] = []
    var bundles: [TicketBundle] = []
    var chats: [ChatMeta] = []
    /// The `docs.list` result.
    var docs: [DocEntry] = []
}

/// `git` with the login-shell environment used for Claude processes (docs/search.md › File list).
struct SearchGit: Sendable {
    var executable: String
    /// Without any `HEPHAESTUS_*` variable.
    var environment: [String: String]
}

/// The texts of the `user` and `assistant` items of each transcript, in transcript order, kept
/// by chat id with the file size and modification date they were read at; a transcript whose
/// size or date changed is read again (docs/search.md › Sources, Chats). Thread-safe.
final class TranscriptTextCache: @unchecked Sendable {
    private struct Entry {
        var size: Int64
        var modified: timespec
        var texts: [String]
    }

    private let lock = NSLock()
    private var entries: [ChatID: Entry] = [:]

    /// The texts of the transcript at `file`, replayed: an `update` line replaces the item with
    /// the same id. A missing or unreadable transcript has no text.
    func texts(chatID: ChatID, file: URL, log: LogSink?) -> [String] {
        var info = stat()
        guard stat(file.path, &info) == 0 else {
            lock.withLock { entries[chatID] = nil }
            return []
        }
        let size = Int64(info.st_size)
        let modified = info.st_mtimespec
        if let entry = lock.withLock({ entries[chatID] }), entry.size == size,
           entry.modified.tv_sec == modified.tv_sec, entry.modified.tv_nsec == modified.tv_nsec {
            return entry.texts
        }
        guard let items = try? TranscriptReplay.replay(fileAt: file, log: log) else { return [] }
        let texts = items.compactMap { item -> String? in
            switch item {
            case .user(let user): return user.text
            case .assistant(let assistant): return assistant.text
            default: return nil
            }
        }
        lock.withLock { entries[chatID] = Entry(size: size, modified: modified, texts: texts) }
        return texts
    }

    /// The number of transcripts kept, for tests.
    var count: Int {
        lock.withLock { entries.count }
    }
}
