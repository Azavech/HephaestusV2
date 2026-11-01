import CoreServices
import Foundation

/// Watches the skills library folder recursively with FSEvents and calls `onChange` 300 ms after
/// the last change it sees (docs/skills.md › Library). Changes inside the target of a symbolically
/// linked skill folder are not seen. `stop()` ends the stream; no call follows it.
final class SkillsLibraryWatcher: @unchecked Sendable {
    /// Quiet time after the last change before `onChange` runs.
    static let debounce: DispatchTimeInterval = .milliseconds(300)

    private let queue = DispatchQueue(label: "HephaestusCore.SkillsLibraryWatcher")
    private let onChange: @Sendable () -> Void
    // The stream and the pending call are used on `queue` only.
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    /// Starts watching `folder`; logs and watches nothing when the stream cannot start.
    init(folder: URL, log: LogSink?, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let path = folder.resolvingSymlinksInPath().path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SkillsLibraryWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        queue.sync {
            guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
            else {
                log?.error(.skills, "the skills library \(path) cannot be watched")
                return
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                log?.error(.skills, "the skills library \(path) cannot be watched")
                return
            }
            self.stream = stream
        }
    }

    deinit {
        stop()
    }

    /// Ends the stream and drops a pending call.
    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Runs on `queue`: restarts the 300 ms delay.
    private func changed() {
        guard stream != nil else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }
}
