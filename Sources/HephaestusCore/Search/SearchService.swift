import Foundation

/// `search.query`: sources, matching, ranking, snippets and code search (docs/search.md). The
/// handler copies the in-memory data it needs on the engine actor and reads files in a child
/// task (docs/search.md › Engine method). Used only on the engine actor.
// DOC-GAP: the docs describe this work but name no Swift type for it; the type name is a
// design choice.
// STUB: core-search-skills — every part of docs/search.md › Query and matching to › Limits.
final class SearchService {
    init() {}
}
