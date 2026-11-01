import Foundation

/// Replay of a chat transcript (docs/data-model.md › Replay).
public enum TranscriptReplay {
    /// A line that replay skipped, numbered from 1.
    public struct SkippedLine: Equatable, Sendable {
        public var line: Int
        public var reason: String
    }

    public struct Result: Sendable {
        public var items: [ChatItem]
        public var skipped: [SkippedLine]
    }

    /// Replays the lines in order: `add` appends the item, or replaces in place an item with
    /// the same `id`; `update` replaces the item with the same `id` in place, or appends it.
    /// A line that is not valid JSON, has an unknown `op` or `type`, or lacks a required key is
    /// skipped. Unknown keys of an item are ignored.
    public static func replay(_ data: Data) -> Result {
        var items: [ChatItem] = []
        var positions: [String: Int] = [:]
        var skipped: [SkippedLine] = []
        let decoder = StorageJSON.decoder()
        for (offset, line) in JSONLines.lines(of: data).enumerated() {
            let entry: TranscriptLine
            do {
                entry = try decoder.decode(TranscriptLine.self, from: line)
            } catch {
                skipped.append(SkippedLine(line: offset + 1, reason: FormatError.describe(error)))
                continue
            }
            if let position = positions[entry.item.id] {
                items[position] = entry.item
            } else {
                positions[entry.item.id] = items.count
                items.append(entry.item)
            }
        }
        return Result(items: items, skipped: skipped)
    }

    /// Replays the transcript file at `url`; a missing file is an empty transcript. Skipped
    /// lines are logged.
    public static func replay(fileAt url: URL, log: LogSink?) throws -> [ChatItem] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
        }
        let result = replay(data)
        for line in result.skipped {
            log?.warn(.storage, "\(url.path):\(line.line): transcript line skipped: \(line.reason)")
        }
        return result.items
    }
}
