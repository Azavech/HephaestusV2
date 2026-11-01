import Foundation

/// Moves removed ticket, bundle and attachment files and folders to the Trash, never deleting
/// them (docs/data-model.md › Atomic writes, docs/tickets.md › Deleting).
// DOC-GAP: docs/architecture.md › HephaestusCore folders puts "moving items to the Trash" in
// `Files/`, whose `FileService` declares no Trash API yet; the project data engine uses this seam
// so that tests can replace the user's Trash with a temporary folder.
protocol DomainTrash: Sendable {
    /// Moves the item at `url` to the Trash; throws when the Trash cannot be used.
    func trashItem(at url: URL) throws
}

/// The Trash of the main device (`FileManager.trashItem`).
struct SystemTrash: DomainTrash {
    func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// A Trash that moves items into a folder, for tests: each item lands in a new sub-folder so
/// that equal names never collide.
struct FolderTrash: DomainTrash {
    let folder: URL

    func trashItem(at url: URL) throws {
        let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
    }
}

/// A Trash that cannot be used, for tests of the `unavailable` errors.
struct UnavailableTrash: DomainTrash {
    struct Failure: LocalizedError {
        var errorDescription: String? { "the volume has no Trash" }
    }

    func trashItem(at url: URL) throws {
        throw Failure()
    }
}
