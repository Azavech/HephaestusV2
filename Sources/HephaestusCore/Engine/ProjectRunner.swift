import Foundation

/// Project runs: `projects.run`, `projects.stopRun`, the `run.*` events and their output
/// (docs/engine-api.md › projects.run, docs/projects.md › Run commands). Used only on the engine
/// actor.
// DOC-GAP: docs/architecture.md › HephaestusCore folders assigns no folder to project runs; the
// runner is engine state, so it lives in `Engine/`.
// STUB: core-domain — process start with ChildProcess, output coalescing (100 ms), the output
// tail, waits and timeouts, the stop sequence (SIGINT, SIGTERM, SIGKILL).
final class ProjectRunner {
    init() {}

    /// The running runs, ordered by `started` (the `runs` of a Snapshot).
    // STUB: core-domain — no run is started yet.
    func runningRuns() -> [RunInfo] {
        []
    }
}

extension Engine {
    /// docs/architecture.md › Shutdown, step 1 for project runs: SIGTERM to every run's process
    /// group, SIGKILL 3 s later when it is still alive; returns once every run has ended.
    // STUB: core-domain
    func stopProjectRuns() async {}
}
