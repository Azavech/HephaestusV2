import Foundation

/// Moves items to the Trash of the main device; what the API removes is never deleted
/// (docs/engine-api.md › Writes and consistency).
struct FileTrash: Sendable {
    /// Moves the item at the URL to the Trash, or throws.
    var move: @Sendable (URL) throws -> Void

    /// The Trash of this Mac (`FileManager.trashItem`).
    static let system = FileTrash { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The `unavailable` error of a move that failed: `<path> cannot be moved to the Trash:
    /// <reason>.`
    static func unavailable(path: String, error: Error) -> EngineError {
        var reason = error.localizedDescription
        while reason.hasSuffix(".") {
            reason.removeLast()
        }
        return EngineError(.unavailable, "\(path) cannot be moved to the Trash: \(reason).")
    }
}

extension Engine {
    /// Moves the item at `url` to the Trash. `path` names it in the error: `unavailable`
    /// `<path> cannot be moved to the Trash: <reason>.` Available to every area that removes
    /// files (tickets, chats, skills).
    func moveItemToTrash(_ url: URL, path: String) throws {
        do {
            try files.trash.move(url)
        } catch {
            throw FileTrash.unavailable(path: path, error: error)
        }
    }

    /// Replaces the Trash, for tests: they never fill the Trash of the user running them.
    func useFileTrash(_ trash: FileTrash) {
        files.trash = trash
    }
}
