import Foundation

/// docs/chats.md › Workflow folder: the reads of the CLI's folder of one workflow run. Each read
/// takes the complete lines added since the previous read to `journal.jsonl` and to the
/// transcript `agent-<agentId>.jsonl` of every agent of the workflow. The engine reads it from a
/// child task; the lock keeps two reads from running at once.
final class WorkflowFolderReader: @unchecked Sendable {
    /// A `started` entry of the journal.
    struct StartedAgent: Sendable, Hashable {
        var agentID: String
        var label: String?
        var phase: String?
    }

    /// What one read found.
    struct Batch: Sendable {
        var started: [StartedAgent] = []
        /// The agents of `result` entries.
        var results: [String] = []
        /// The new items of each agent's transcript, in the order the agents became known.
        var items: [(agentID: String, items: [ChatItem])] = []
    }

    /// A file read from where its previous read stopped: the offset after its last complete line.
    private struct Cursor {
        var offset: UInt64 = 0
    }

    let folder: URL
    private let lock = NSLock()
    private var journal = Cursor()
    private var agentIDs: [String] = []
    private var cursors: [String: Cursor] = [:]
    private var mappers: [String: AgentTranscriptMapper] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    /// Reads the journal, then the transcript of each agent: those of `knownAgentIDs` and those
    /// the journal names. `now` dates the items whose line has no timestamp.
    func read(knownAgentIDs: [String], now: Date) -> Batch {
        lock.lock()
        defer { lock.unlock() }
        var batch = Batch()
        for line in Self.newLines(of: folder.appendingPathComponent("journal.jsonl"), cursor: &journal) {
            guard let entry = (try? JSONDecoder().decode(JSONValue.self, from: line))?.objectValue,
                  let agentID = entry["agentId"]?.stringValue, ChatAgent.isWorkflowAgentID(agentID)
            else { continue }
            switch entry["type"]?.stringValue {
            case "started":
                batch.started.append(StartedAgent(agentID: agentID, label: entry["label"]?.stringValue, phase: entry["phase"]?.stringValue))
            case "result":
                batch.results.append(agentID)
            default:
                continue
            }
        }
        for agentID in knownAgentIDs + batch.started.map(\.agentID) where ChatAgent.isWorkflowAgentID(agentID) && !agentIDs.contains(agentID) {
            agentIDs.append(agentID)
        }
        for agentID in agentIDs {
            var cursor = cursors[agentID] ?? Cursor()
            let lines = Self.newLines(of: folder.appendingPathComponent("agent-\(agentID).jsonl"), cursor: &cursor)
            cursors[agentID] = cursor
            guard !lines.isEmpty else { continue }
            var mapper = mappers[agentID] ?? AgentTranscriptMapper()
            let items = lines.flatMap { mapper.map($0, now: now) }
            mappers[agentID] = mapper
            if !items.isEmpty { batch.items.append((agentID, items)) }
        }
        return batch
    }

    /// The complete lines added to a file since `cursor`, which moves after the last one. A file
    /// that does not exist or cannot be read gives none.
    private static func newLines(of url: URL, cursor: inout Cursor) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: cursor.offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty,
              let end = data.lastIndex(of: 0x0A)
        else { return [] }
        let complete = data[data.startIndex...end]
        cursor.offset += UInt64(complete.count)
        return JSONLines.lines(of: Data(complete)).filter { !$0.isEmpty }
    }
}
