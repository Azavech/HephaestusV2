import Foundation

/// The replay of a chat agents file (docs/data-model.md › Chat agents file): each line replaces the
/// workflow or the agent with the same `id`, or adds it after the others.
public enum ChatAgentsReplay {
    public struct Result: Sendable {
        public var workflows: [ChatWorkflow] = []
        public var agents: [ChatAgent] = []
        public var skipped: [TranscriptReplay.SkippedLine] = []

        public init() {}
    }

    public static func replay(_ data: Data) -> Result {
        var result = Result()
        let decoder = StorageJSON.decoder()
        for (offset, line) in JSONLines.lines(of: data).enumerated() {
            let entry: ChatAgentsLine
            do {
                entry = try decoder.decode(ChatAgentsLine.self, from: line)
            } catch {
                result.skipped.append(TranscriptReplay.SkippedLine(line: offset + 1, reason: FormatError.describe(error)))
                continue
            }
            if let workflow = entry.workflow {
                if let index = result.workflows.firstIndex(where: { $0.id == workflow.id }) {
                    result.workflows[index] = workflow
                } else {
                    result.workflows.append(workflow)
                }
            }
            if let agent = entry.agent {
                if let index = result.agents.firstIndex(where: { $0.id == agent.id }) {
                    result.agents[index] = agent
                } else {
                    result.agents.append(agent)
                }
            }
        }
        return result
    }

    /// Replays the file at `url`; a missing file holds no record. Skipped lines are logged.
    public static func replay(fileAt url: URL, log: LogSink?) throws -> Result {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Result()
        } catch {
            throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
        }
        let result = replay(data)
        for line in result.skipped {
            log?.warn(.storage, "\(url.path):\(line.line): agents line skipped: \(line.reason)")
        }
        return result
    }
}
