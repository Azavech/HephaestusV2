import CoreServices
import Foundation

/// Watches one memory folder recursively with FSEvents, also while it does not exist yet, and
/// calls `onChange` 300 ms after the last change it sees (docs/memories.md › Live updates).
/// `stop()` ends the stream; no call follows it.
final class MemoryFolderWatcher: @unchecked Sendable {
    /// Quiet time after the last change before `onChange` runs.
    static let debounce: DispatchTimeInterval = .milliseconds(300)

    /// The folder, as the engine resolved it.
    let folder: String
    private let queue = DispatchQueue(label: "HephaestusCore.MemoryFolderWatcher")
    private let onChange: @Sendable () -> Void
    // The stream and the pending call are used on `queue` only.
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    /// Starts watching `folder`; logs and watches nothing when the stream cannot start. The
    /// stream watches the folder's path with its existing ancestors' links resolved, as FSEvents
    /// reports paths; with `kFSEventStreamCreateFlagWatchRoot`, it also reports the creation and
    /// the removal of a folder that does not exist yet.
    init(folder: String, log: LogSink?, onChange: @escaping @Sendable () -> Void) {
        self.folder = folder
        self.onChange = onChange
        let path = ClaudeMemoryFolderResolver.realPath(folder)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<MemoryFolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        queue.sync {
            guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
            else {
                log?.error(.memories, "the memory folder \(path) cannot be watched")
                return
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                log?.error(.memories, "the memory folder \(path) cannot be watched")
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
