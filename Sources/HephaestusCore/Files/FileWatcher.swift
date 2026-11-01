import CoreServices
import Foundation

/// One FSEvents stream on one folder, with file-level events (docs/data-model.md › Watching).
/// Events are delivered on a private queue to `handler`, in order. The folder may not exist
/// yet: FSEvents then reports only `rootChanged`, and the owner restarts the stream once the
/// folder appears (`restart()`).
final class FileWatcher: @unchecked Sendable {
    /// One file system event: the path as FSEvents reports it (symbolic links resolved) and
    /// what it means.
    struct Event: Sendable, Hashable {
        var path: String
        var flags: FSEventStreamEventFlags

        /// The path is a directory whose content changed in unknown ways (events were
        /// coalesced or dropped): anything below it may have changed.
        var mustScanSubdirectories: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0
        }

        /// The watched folder itself, or one of its ancestors, was created, removed or moved.
        var rootChanged: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }

        /// The item was created, removed, renamed or its content modified, or anything below it
        /// may have changed: more than its own metadata (dates, permissions, extended
        /// attributes).
        var changesMoreThanMetadata: Bool {
            mustScanSubdirectories || rootChanged
                || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCloned) != 0
        }

        /// Bookkeeping only: no item changed.
        var isBookkeeping: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagEventIdsWrapped) != 0
        }
    }

    /// The watched folder, as the owner named it.
    let path: String
    /// Latency of the stream; batching is done by the owner.
    static let latency: CFTimeInterval = 0.05

    private let queue: DispatchQueue
    private let handler: @Sendable ([Event]) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(path: String, handler: @escaping @Sendable ([Event]) -> Void) {
        self.path = path
        self.handler = handler
        self.queue = DispatchQueue(label: "HephaestusV2.FileWatcher")
    }

    deinit {
        stopStream()
    }

    /// Starts the stream. Returns false when FSEvents refuses it.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, FileWatcher.callback, &context, [path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Stops the stream; no event is delivered after this returns. Never call it from the
    /// handler.
    func stop() {
        stopStream()
    }

    /// Stops and starts the stream again, so that FSEvents watches the folder at its current
    /// location (after it was created, removed or moved).
    @discardableResult
    func restart() -> Bool {
        stopStream()
        return start()
    }

    private func stopStream() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        // Invalidating on the stream's own queue waits for a callback in progress to end.
        queue.sync {
            FSEventStreamStop(current)
            FSEventStreamInvalidate(current)
            FSEventStreamRelease(current)
        }
    }

    private func deliver(_ events: [Event]) {
        handler(events)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(paths, to: NSArray.self)
        var events: [Event] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = array[index] as? String else { continue }
            let event = Event(path: path, flags: flags[index])
            if !event.isBookkeeping {
                events.append(event)
            }
        }
        if !events.isEmpty {
            watcher.deliver(events)
        }
    }
}
