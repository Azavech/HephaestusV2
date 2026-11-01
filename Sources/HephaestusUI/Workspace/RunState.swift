// OWNER: ui-shell — RunState of DeviceWorkspace.runs (docs/ui.md › DeviceWorkspace;
// docs/projects.md › Console).
import Foundation
import HephaestusCore

/// A run known to a workspace: its `RunInfo`, its starter, its console buffer, its exit code and
/// whether its end was missed (docs/ui.md › DeviceWorkspace).
struct RunState: Identifiable {
    var info: RunInfo
    /// The actor of the `run.started` origin; nil for a run known from a snapshot.
    var starter: EngineActor?
    /// The console buffer, shared by the windows of this app and never persisted.
    var output: String = ""
    /// Exit status, or 128 + the signal number; nil while the run runs.
    var exitCode: Int?
    /// True when the run was running and is absent from the snapshot after a reconnection.
    var endMissed = false

    var id: String { info.runID.uuidString }

    var isRunning: Bool { exitCode == nil && !endMissed }

    init(info: RunInfo, starter: EngineActor?) {
        self.info = info
        self.starter = starter
    }

    /// A run first known from a snapshot: it starts with the line
    /// `Output before <HH:mm:ss> is not available here.`
    init(info: RunInfo, starter: EngineActor?, knownFromSnapshotAt date: Date) {
        self.init(info: info, starter: starter)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        output = "Output before \(formatter.string(from: date)) is not available here.\n"
    }

    /// Appends `run.output` text to the buffer.
    // STUB: ui-shell — docs/projects.md › Console: remove ANSI escape sequences, turn CR LF and a
    // lone CR into line breaks, keep the last 20,000 lines with the first line
    // `… earlier output dropped …`.
    mutating func append(_ text: String) {
        output += text
    }

    /// `run.finished`.
    mutating func finish(exitCode: Int) {
        self.exitCode = exitCode
    }

    /// After a reconnection, a run still running gets the line
    /// `… output missed while disconnected …`.
    mutating func noteMissedOutput() {
        if !output.isEmpty, !output.hasSuffix("\n") {
            output += "\n"
        }
        output += "… output missed while disconnected …\n"
    }

    /// A run that was running and is absent from the new snapshot.
    mutating func markEndedWhileDisconnected() {
        endMissed = true
    }

    /// Clear (⌘K) empties the buffer for every window of this app.
    mutating func clear() {
        output = ""
    }
}
