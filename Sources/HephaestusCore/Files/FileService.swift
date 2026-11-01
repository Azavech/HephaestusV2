import Foundation

/// The files of the projects: `files.*`, `docs.list`, `fs.browse`, the FSEvents streams of the
/// project roots and of the data directory, `files.changed` batching, and moving items to the
/// Trash (docs/architecture.md › HephaestusCore folders, docs/engine-api.md › Files). Used only
/// on the engine actor.
// DOC-GAP: the docs describe this work but name no Swift type for it; the type name is a
// design choice.
// STUB: core-domain — path checks (docs/engine-api.md › Paths), listing, reading, writing with
// format on save, create, rename, Trash, docs listing, folder browsing, FSEvents and the
// external-change reload of docs/data-model.md › External changes.
final class FileService {
    init() {}
}

extension Engine {
    /// Startup step 4: starts watching every loaded project root and the data directory
    /// (docs/architecture.md › File system changes).
    // STUB: core-domain
    func startFileWatching() async {}

    /// docs/architecture.md › Shutdown, step 3: closes the FSEvents streams.
    // STUB: core-domain
    func stopFileWatching() async {}
}
