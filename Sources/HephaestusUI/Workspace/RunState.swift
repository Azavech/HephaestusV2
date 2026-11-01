// OWNER: ui-shell — RunState of DeviceWorkspace.runs and its console buffer (docs/ui.md ›
// DeviceWorkspace; docs/projects.md › Console).
import Foundation
import HephaestusCore

/// A run known to a workspace: its `RunInfo`, its starter, its console buffer, its exit code and
/// whether its end was missed (docs/ui.md › DeviceWorkspace).
struct RunState: Identifiable {
    var info: RunInfo
    /// The actor of the `run.started` origin; nil for a run known from a snapshot.
    var starter: EngineActor?
    /// The console buffer, shared by the windows of this app and never persisted.
    private(set) var console = ConsoleBuffer()
    /// Exit status, or 128 + the signal number; nil while the run runs.
    var exitCode: Int?
    /// True when the run was running and is absent from the snapshot after a reconnection.
    var endMissed = false

    var id: String { info.runID.uuidString }

    var isRunning: Bool { exitCode == nil && !endMissed }

    /// The whole console text.
    var output: String { console.text }

    init(info: RunInfo, starter: EngineActor?) {
        self.info = info
        self.starter = starter
    }

    /// A run first known from a snapshot: it starts with the line
    /// `Output before <HH:mm:ss> is not available here.`
    init(info: RunInfo, starter: EngineActor?, knownFromSnapshotAt date: Date) {
        self.init(info: info, starter: starter)
        console.appendLine("Output before \(Self.timeFormatter.string(from: date)) is not available here.")
    }

    /// Appends `run.output` text to the buffer: ANSI escape sequences are removed, CR LF and a
    /// lone CR become line breaks, and the last 20,000 lines are kept (docs/projects.md › Console).
    mutating func append(_ text: String) {
        console.append(text)
    }

    /// `run.finished`.
    mutating func finish(exitCode: Int) {
        self.exitCode = exitCode
    }

    /// After a reconnection, a run still running gets the line
    /// `… output missed while disconnected …`.
    mutating func noteMissedOutput() {
        console.appendLine("… output missed while disconnected …")
    }

    /// A run that was running and is absent from the new snapshot.
    mutating func markEndedWhileDisconnected() {
        endMissed = true
    }

    /// Clear (⌘K) empties the buffer for every window of this app.
    mutating func clear() {
        console.clear()
    }

    /// Local time `HH:mm:ss`, the start time of the run picker and the snapshot line.
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// The console buffer of one run (docs/projects.md › Console): complete lines and the current
/// unfinished line. Output processing removes ANSI escape sequences (CSI `ESC [` up to a final
/// byte from `@` to `~`, OSC `ESC ]` up to `BEL` or `ESC \`, and every other two-character `ESC`
/// sequence) and turns CR LF and a lone CR into line breaks; a sequence or a CR LF split between
/// two chunks is handled as if the chunks were one. The buffer keeps its last 20,000 lines; once
/// lines were dropped, the first line reads `… earlier output dropped …`.
///
/// Apart from `clear()`, the text only grows at its end and loses lines at its start, so a view
/// can follow it incrementally with `firstLineNumber`, `lineCount`, `lines(from:)`, `partial`,
/// `dropped` and `clearCount`.
// DOC-GAP: docs/projects.md › Console keeps "the last 20,000 lines" without saying whether the
// dropped-output line and the unfinished last line count; the dropped-output line does not, the
// unfinished line does. "Every other two-character ESC sequence" removes ESC and the next
// character only, so the third character of a sequence such as `ESC ( B` stays.
struct ConsoleBuffer {
    /// Lines kept, the dropped-output line excluded.
    static let lineLimit = 20_000
    /// The first line once lines were dropped.
    static let droppedLine = "… earlier output dropped …"

    /// Complete lines without their line break, oldest first, starting at `head`.
    private var storage: [String] = []
    private var head = 0
    /// The current line, not ended by a line break yet.
    private(set) var partial = ""
    /// True once lines were dropped since the last clear.
    private(set) var dropped = false
    /// The number of lines dropped since the last clear: the line number of the first kept line.
    private(set) var firstLineNumber = 0
    /// Incremented by each `clear()`.
    private(set) var clearCount = 0
    /// The start of an escape sequence that the last chunk did not complete.
    private var pendingEscape: [Unicode.Scalar] = []
    /// True when the last character processed was a CR: an LF right after it belongs to it.
    private var afterCR = false

    /// The number of complete lines since the last clear, dropped lines included: the line
    /// number after the last complete line.
    var lineCount: Int { firstLineNumber + storage.count - head }

    /// The kept complete lines.
    var lines: ArraySlice<String> { storage[head...] }

    /// The kept complete lines from line number `number` on.
    func lines(from number: Int) -> ArraySlice<String> {
        let start = head + max(0, number - firstLineNumber)
        return start < storage.count ? storage[start...] : []
    }

    var isEmpty: Bool { storage.count == head && partial.isEmpty && !dropped }

    /// The whole text: the dropped-output line, the complete lines each followed by a line
    /// break, then the current line.
    var text: String {
        var result = dropped ? Self.droppedLine + "\n" : ""
        for line in lines {
            result += line
            result += "\n"
        }
        return result + partial
    }

    /// Processes a chunk of output.
    mutating func append(_ chunk: String) {
        var current = String.UnicodeScalarView()
        current.append(contentsOf: partial.unicodeScalars)
        var escape = pendingEscape
        pendingEscape = []
        for scalar in chunk.unicodeScalars {
            if !escape.isEmpty {
                escape.append(scalar)
                if Self.escapeIsComplete(escape) {
                    escape.removeAll()
                }
                continue
            }
            switch scalar {
            case "\u{1B}":
                escape.append(scalar)
                afterCR = false
            case "\n":
                if afterCR {
                    afterCR = false
                } else {
                    endLine(&current)
                }
            case "\r":
                endLine(&current)
                afterCR = true
            default:
                afterCR = false
                current.append(scalar)
            }
        }
        pendingEscape = escape
        partial = String(current)
        enforceLimit()
    }

    /// Adds a whole line of the app's own (the snapshot and reconnection lines), ending the
    /// current line first.
    mutating func appendLine(_ line: String) {
        if !partial.isEmpty {
            storage.append(partial)
            partial = ""
        }
        storage.append(line)
        afterCR = false
        enforceLimit()
    }

    /// Empties the buffer; an escape sequence or a CR LF in progress still completes.
    mutating func clear() {
        storage = []
        head = 0
        partial = ""
        dropped = false
        firstLineNumber = 0
        clearCount += 1
    }

    private mutating func endLine(_ current: inout String.UnicodeScalarView) {
        storage.append(String(current))
        current = String.UnicodeScalarView()
    }

    /// Keeps at most `lineLimit` lines, the current line included when it is not empty.
    private mutating func enforceLimit() {
        let limit = Self.lineLimit - (partial.isEmpty ? 0 : 1)
        let excess = storage.count - head - limit
        guard excess > 0 else { return }
        head += excess
        firstLineNumber += excess
        dropped = true
        if head > 4_096, head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// True when `sequence`, which starts with ESC, is a complete escape sequence.
    static func escapeIsComplete(_ sequence: [Unicode.Scalar]) -> Bool {
        guard sequence.count >= 2 else { return false }
        switch sequence[1] {
        case "[":
            // CSI: parameter and intermediate bytes, then a final byte from `@` to `~`.
            guard sequence.count >= 3, let last = sequence.last else { return false }
            return (0x40...0x7E).contains(last.value)
        case "]":
            // OSC: up to BEL or ST (`ESC \`).
            guard let last = sequence.last, sequence.count >= 3 else { return false }
            if last == "\u{07}" { return true }
            return last == "\\" && sequence[sequence.count - 2] == "\u{1B}"
        default:
            // Every other two-character sequence.
            return true
        }
    }
}
