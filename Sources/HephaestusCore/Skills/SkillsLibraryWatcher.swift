import CoreServices
import Foundation

/// Watches the skills library folder recursively with FSEvents and calls `onChange` 300 ms after
/// the last change it sees, unless the library is then the same as at the last call or at the
/// start (docs/skills.md › Library). Changes inside the target of a symbolically linked skill
/// folder are not seen. `stop()` ends the stream; no call follows it.
final class SkillsLibraryWatcher: @unchecked Sendable {
    /// Quiet time after the last change before `onChange` runs.
    static let debounce: DispatchTimeInterval = .milliseconds(300)

    /// Each file and folder of the library, the library folder included, by path, with its kind,
    /// size and modification date. Symbolic links are listed, not followed.
    struct Snapshot: Equatable {
        struct Item: Equatable {
            var isDirectory: Bool
            var size: Int?
            var modified: Date?
        }

        var items: [String: Item]

        private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        /// The library at `folder` as it is now; empty when it cannot be read.
        static func of(_ folder: URL) -> Snapshot {
            var items: [String: Item] = [:]
            let manager = FileManager.default
            guard manager.fileExists(atPath: folder.path),
                  let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true })
            else { return Snapshot(items: [:]) }
            items[""] = item(folder)
            for case let url as URL in enumerator {
                items[url.path] = item(url)
            }
            return Snapshot(items: items)
        }

        private static func item(_ url: URL) -> Item {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Item(isDirectory: values?.isDirectory ?? false, size: values?.fileSize, modified: values?.contentModificationDate)
        }
    }

    private let queue = DispatchQueue(label: "HephaestusCore.SkillsLibraryWatcher")
    private let onChange: @Sendable () -> Void
    private let folder: URL
    // The stream, the pending call and the snapshot are used on `queue` only.
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var snapshot: Snapshot

    /// Starts watching `folder`; logs and watches nothing when the stream cannot start. The library
    /// as it is before the stream starts is the first snapshot, so the writes made just before,
    /// which FSEvents can still report, call nothing.
    init(folder: URL, log: LogSink?, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let path = folder.resolvingSymlinksInPath().path
        self.folder = URL(fileURLWithPath: path, isDirectory: true)
        snapshot = Snapshot.of(self.folder)
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
        let item = DispatchWorkItem { [weak self] in self?.settled() }
        pending = item
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }

    /// Runs on `queue` 300 ms after the last change: calls `onChange` when the library differs from
    /// the snapshot, which it then replaces.
    private func settled() {
        let current = Snapshot.of(folder)
        guard current != snapshot else { return }
        snapshot = current
        onChange()
    }
}
