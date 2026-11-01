import Foundation

/// The skills library folder: `skills.*` reads and writes, SKILL.md parsing and the library
/// watcher (docs/skills.md › Library). Used only on the engine actor.
// DOC-GAP: the docs describe this work but name no Swift type for it; the type name is a
// design choice.
// STUB: core-search-skills — reading the library, the skill files, renames and deletes with
// their project updates, and the FSEvents watcher of the library folder.
final class SkillsLibrary {
    init() {}

    /// The `skills.list` result for a Snapshot and for `skills.changed`: every skill sorted by
    /// name; empty when the library cannot be read (docs/engine-api.md › Snapshot).
    // STUB: core-search-skills — the library is not read yet.
    func summaries(in folder: URL) -> [SkillSummary] {
        []
    }
}

extension Engine {
    /// The skills library folder: `skillsLibraryPath` with `~/` expanded, else `<data dir>/Skills`.
    var skillsLibraryFolder: URL {
        settings.skillsLibraryURL(dataDirectory: dataDirectory)
    }

    /// The `skills.list` result, or `[]` when the library cannot be read.
    func skillSummaries() -> [SkillSummary] {
        skillsLibrary.summaries(in: skillsLibraryFolder)
    }

    /// Startup step 4: starts watching the skills library folder (docs/skills.md › Library).
    // STUB: core-search-skills
    func startSkillsLibraryWatching() async {}

    /// `settings.update` changed `skillsLibraryPath`: the engine uses the new folder, already
    /// created by the handler; skills of the previous folder are not moved (docs/skills.md ›
    /// Settings). The handler emits `skills.changed` afterwards.
    // STUB: core-search-skills — move the watcher to the new folder.
    func skillsLibraryFolderDidChange() async {}

    /// docs/architecture.md › Shutdown, step 3: closes the library watcher.
    // STUB: core-search-skills
    func stopSkillsLibraryWatching() async {}
}
