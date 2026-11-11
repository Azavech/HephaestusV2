import CoreServices
import Foundation

/// Watches `devices.json` in a data directory with FSEvents and calls `onChange` 300 ms after the
/// last change of the file, its creation and its removal included (docs/views.md › Devices file).
/// `stop()` ends the stream; no call follows it.
public final class PreviewDevicesWatcher: @unchecked Sendable {
    /// Quiet time after the last change before `onChange` runs.
    static let debounce: DispatchTimeInterval = .milliseconds(300)

    private let queue = DispatchQueue(label: "HephaestusCore.PreviewDevicesWatcher")
    private let path: String
    private let onChange: @Sendable () -> Void
    // The stream and the pending call are used on `queue` only.
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    /// Starts watching the file; watches nothing when the stream cannot start.
    public init(file: URL, onChange: @escaping @Sendable () -> Void) {
        // The real path, `/private` kept, as FSEvents reports it.
        let folder = ClaudeMemoryFolderResolver.realPath(file.deletingLastPathComponent().path)
        path = folder + "/" + file.lastPathComponent
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PreviewDevicesWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: { $0 == watcher.path }) { watcher.changed() }
        }
        queue.sync {
            guard let stream = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }
            self.stream = stream
        }
    }

    deinit {
        stop()
    }

    /// Ends the stream and drops a pending call.
    public func stop() {
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
