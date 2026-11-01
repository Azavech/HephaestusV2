import Foundation
@testable import HephaestusCore

/// Writes `<library>/<name>/SKILL.md` with `content`, creating the folders.
@discardableResult
func writeSkill(_ name: String, in library: URL, _ content: String) throws -> URL {
    let folder = library.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(content.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    return folder
}

/// Writes a SKILL.md with a frontmatter holding `description`, then `body`.
@discardableResult
func writeSkill(_ name: String, in library: URL, description: String, body: String = "") throws -> URL {
    try writeSkill(name, in: library, "---\nname: \(name)\ndescription: \(description)\n---\n\(body)")
}

/// Writes `text` at `path` under `folder`, creating the folders.
func writeFile(_ path: String, in folder: URL, _ text: String) throws {
    let url = folder.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Sets the modification date of a file.
func setModified(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

extension Engine {
    /// Makes skills.delete and skills.deleteFile move items into `folder` instead of the user's
    /// Trash.
    func useTestTrash(_ folder: URL) {
        skillsLibrary.moveToTrash = { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
        }
    }

    /// Makes moving to the Trash fail.
    func useFailingTrash() {
        skillsLibrary.moveToTrash = { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
