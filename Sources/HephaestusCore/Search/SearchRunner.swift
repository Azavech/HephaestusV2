import Darwin
import Foundation

/// Runs one search over a `SearchInput` off the engine actor: every scope's items, fields,
/// dates and targets (docs/search.md › Sources), then the ranking and the limit.
enum SearchRunner {
    /// `limit` of search.query: 1–1,000, default 200.
    static let limits = 1...1000
    static let defaultLimit = 200
    /// A doc file larger than this, or not valid UTF-8, is matched on its path and title only.
    static let maximumDocSize = 1_048_576

    /// The results in rank order, cut to `limit`. Files and folders that cannot be read are
    /// skipped without error.
    static func run(_ input: SearchInput, transcripts: TranscriptTextCache, log: LogSink?) async -> [SearchResult] {
        let terms = input.terms
        var ranked: [RankedResult] = []
        for data in input.projects {
            if input.scopes.contains(.projects) {
                ranked += project(data, terms)
            }
            if input.scopes.contains(.tickets) {
                ranked += data.tickets.compactMap { ticket($0, in: data, terms) }
            }
            if input.scopes.contains(.bundles) {
                let titles = Dictionary(data.tickets.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
                ranked += data.bundles.compactMap { bundle($0, titles: titles, in: data, terms) }
            }
            if input.scopes.contains(.docs) {
                ranked += data.docs.compactMap { doc($0, in: data, terms) }
            }
            if input.scopes.contains(.chats) {
                ranked += data.chats.compactMap { chat($0, in: data, terms, transcripts: transcripts, log: log) }
            }
            if input.scopes.contains(.web) {
                ranked += data.project.webTabs.enumerated().compactMap { webTab($0.element, position: $0.offset, in: data, terms) }
            }
        }
        if input.scopes.contains(.code) {
            ranked += await CodeSearch.results(input)
        }
        if input.scopes.contains(.skills), let library = input.skillsLibrary {
            ranked += skills(in: library, terms, log: log)
        }
        ranked.sort(by: RankedResult.precedes)
        return ranked.prefix(input.limit).map(\.result)
    }

    // MARK: Sources

    /// projects: id field the identifier; title fields the name and the folder name.
    static func project(_ data: SearchProjectData, _ terms: SearchTerms) -> [RankedResult] {
        let project = data.project
        guard let level = terms.level(id: project.id, titles: [project.name, data.root.lastPathComponent], body: []) else { return [] }
        let result = SearchResult(id: "project:\(project.id)", kind: .projects, projectID: project.id, title: project.name,
                                  subtitle: "\(project.id) · \(data.root.path)", target: .project(projectID: project.id))
        return [RankedResult(result: result, level: level, date: project.created, key: project.id)]
    }

    /// tickets: id field the ticket id; title field the title; body fields the description, the
    /// comment texts oldest first, then the attachment names, ticket attachments first.
    static func ticket(_ ticket: Ticket, in data: SearchProjectData, _ terms: SearchTerms) -> RankedResult? {
        let comments = ticket.comments.enumerated().sorted {
            ($0.element.created, $0.offset) < ($1.element.created, $1.offset)
        }.map(\.element)
        let body = [ticket.description] + comments.map(\.text) + ticket.attachments.map(\.name)
            + comments.flatMap { $0.attachments.map(\.name) }
        guard let level = terms.level(id: ticket.id, titles: [ticket.title], body: body) else { return nil }
        let result = SearchResult(id: "ticket:\(ticket.id)", kind: .tickets, projectID: data.project.id,
                                  title: "\(ticket.id) \(ticket.title)", subtitle: "\(data.project.name) · \(ticket.status.label)",
                                  snippet: terms.snippet(fromFirstOf: body), target: .ticket(ticketID: ticket.id))
        return RankedResult(result: result, level: level, date: ticket.updated, key: ticket.id)
    }

    /// bundles: id field the bundle id; title field the title; body fields each member ticket as
    /// `<id> <title>` in bundle order, the id alone when the ticket no longer exists.
    static func bundle(_ bundle: TicketBundle, titles: [TicketID: String], in data: SearchProjectData,
                       _ terms: SearchTerms) -> RankedResult? {
        let body = bundle.ticketIDs.map { id in titles[id].map { "\(id) \($0)" } ?? id }
        guard let level = terms.level(id: bundle.id, titles: [bundle.title], body: body) else { return nil }
        let result = SearchResult(id: "bundle:\(bundle.id)", kind: .bundles, projectID: data.project.id,
                                  title: "\(bundle.id) \(bundle.title)", subtitle: data.project.name,
                                  snippet: terms.snippet(fromFirstOf: body), target: .bundle(bundleID: bundle.id))
        return RankedResult(result: result, level: level, date: bundle.updated, key: bundle.id)
    }

    /// docs: id field the doc path; title field the doc title; body fields the lines of the file,
    /// unless it is larger than 1 MB or not valid UTF-8; date the file's modification date. A
    /// doc whose file cannot be read is skipped.
    static func doc(_ entry: DocEntry, in data: SearchProjectData, _ terms: SearchTerms) -> RankedResult? {
        let file = data.root.appendingPathComponent(entry.path)
        var info = stat()
        guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var text: String?
        if info.st_size <= maximumDocSize {
            guard let data = try? Data(contentsOf: file) else { return nil }
            if data.count <= maximumDocSize {
                text = String(validating: data, as: UTF8.self)
            }
        }
        guard let level = terms.level(id: entry.path, titles: [entry.title], body: text.map { [$0] } ?? []) else { return nil }
        let snippet = text.flatMap { text in
            terms.snippet(fromFirstOf: text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map {
                String(String.UnicodeScalarView($0))
            })
        }
        let projectID = data.project.id
        let result = SearchResult(id: "doc:\(projectID):\(entry.path)", kind: .docs, projectID: projectID, title: entry.title,
                                  subtitle: entry.path, snippet: snippet, target: .doc(projectID: projectID, path: entry.path))
        return RankedResult(result: result, level: level, date: modificationDate(info), key: entry.path)
    }

    /// chats: id field the chat id; title field the title; body fields the `text` of every `user`
    /// and `assistant` item in transcript order.
    static func chat(_ meta: ChatMeta, in data: SearchProjectData, _ terms: SearchTerms, transcripts: TranscriptTextCache,
                     log: LogSink?) -> RankedResult? {
        let id = meta.id.uuidString
        let file = ProjectFolder(root: data.root).transcriptFile(meta.id)
        let body = transcripts.texts(chatID: meta.id, file: file, log: log)
        guard let level = terms.level(id: id, titles: [meta.title], body: body) else { return nil }
        // DOC-GAP: docs/engine-api.md › SearchResult writes the chat subtitle
        // `<project name> · <chat kind>` but gives no label for the kinds; the stored value
        // (`project`, `ticket`, `bundle`, `feedback`) is used.
        let result = SearchResult(id: "chat:\(id)", kind: .chats, projectID: data.project.id, title: meta.title,
                                  subtitle: "\(data.project.name) · \(meta.kind.rawValue)", snippet: terms.snippet(fromFirstOf: body),
                                  target: .chat(chatID: meta.id))
        return RankedResult(result: result, level: level, date: meta.updated, key: id)
    }

    /// web: id field the tab id; title fields the title and the URL; no date; key the tab's
    /// zero-based position in its project's tab list.
    static func webTab(_ tab: WebTab, position: Int, in data: SearchProjectData, _ terms: SearchTerms) -> RankedResult? {
        let id = tab.id.uuidString
        guard let level = terms.level(id: id, titles: [tab.title, tab.url], body: []) else { return nil }
        let projectID = data.project.id
        let result = SearchResult(id: "web:\(projectID):\(id)", kind: .web, projectID: projectID, title: tab.title, subtitle: tab.url,
                                  target: .webTab(projectID: projectID, tabID: tab.id))
        return RankedResult(result: result, level: level, date: nil, key: String(position))
    }

    /// skills: id and title field the name; body fields the description and the SKILL.md body;
    /// date the SKILL.md modification date. Skills belong to no project.
    static func skills(in library: URL, _ terms: SearchTerms, log: LogSink?) -> [RankedResult] {
        guard let skills = try? SkillsLibraryReader.skills(in: library, log: log) else { return [] }
        return skills.compactMap { skill in
            let description = skill.document.frontmatter.description
            let body = [description, skill.document.body]
            guard let level = terms.level(id: skill.name, titles: [skill.name], body: body) else { return nil }
            // DOC-GAP: docs/engine-api.md › SearchResult gives the skill description as subtitle;
            // an empty description gives no subtitle.
            let result = SearchResult(id: "skill:\(skill.name)", kind: .skills, title: skill.name,
                                      subtitle: description.isEmpty ? nil : description, snippet: terms.snippet(fromFirstOf: body),
                                      target: .skill(name: skill.name))
            return RankedResult(result: result, level: level, date: skill.modified, key: skill.name)
        }
    }

    /// The modification date of a `stat`.
    static func modificationDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
