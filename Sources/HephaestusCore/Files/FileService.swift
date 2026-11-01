import Foundation

/// The files of the projects: `files.*`, `docs.list`, `fs.browse`, the FSEvents streams of the
/// project roots and of the data directory, `files.changed` batching, and moving items to the
/// Trash (docs/architecture.md › HephaestusCore folders, docs/engine-api.md › Files). Used only
/// on the engine actor.
final class FileService {
    // MARK: Tools and Trash

    /// `git`, `gofmt` and `swift-format`, set by `lookUpFileTools(environment:)`.
    var tools = FileTools.notLookedUp
    /// True once a test set the tools: the lookup of the engine start does not replace them.
    var toolsSetByTest = false
    /// Where `files.trash` and `moveItemToTrash` move items.
    var trash = FileTrash.system
    /// docs/engine-api.md › files.write, step 2: a formatter running longer writes the text
    /// unformatted.
    var formatTimeout: Duration = .seconds(10)

    // MARK: Watching (docs/data-model.md › Watching)

    /// True between `startFileWatching()` and `stopFileWatching()`.
    var isWatching = false
    /// One stream per registered top-level project root, keyed by the root path of the registry.
    var projectWatchers: [String: FileWatcher] = [:]
    /// The stream on the data directory, for `settings.yml` and `registry.yml`.
    var dataDirectoryWatcher: FileWatcher?
    /// Where the streams deliver their events, consumed in order on the engine actor.
    var eventInput: AsyncStream<WatchedEvents>.Continuation?
    var eventConsumer: Task<Void, Never>?

    // MARK: Batching (docs/data-model.md › Processing a change)

    /// 300 ms without a new event closes a batch.
    static let quietDelay: Duration = .milliseconds(300)
    /// A batch with project root events closes at most 2 s after its first one.
    static let maximumDelay: Duration = .seconds(2)

    /// The events collected since the last batch closed.
    var pending: [WatchedEvents] = []
    /// When the first project root event of the pending batch arrived.
    var pendingFirstProjectEvent: ContinuousClock.Instant?
    var flushTimer: Task<Void, Never>?
    var flushGeneration = 0
    /// Closed batches waiting while an earlier one is processed.
    var closedBatches: [[WatchedEvents]] = []
    var isProcessing = false

    /// Called with every `projectDataFilesChanged` call before it is made, for tests.
    var dataChangeObserver: (@Sendable (ProjectID, [String]) -> Void)?

    init() {}
}

/// Events of one stream.
struct WatchedEvents: Sendable {
    enum Source: Sendable, Hashable {
        /// The stream of a registered top-level project root (the registry's path).
        case projectRoot(String)
        case dataDirectory
    }

    var source: Source
    var events: [FileWatcher.Event]
}

extension Engine {
    /// Startup step 4: starts watching every registered top-level project root and the data
    /// directory (docs/architecture.md › File system changes, docs/data-model.md › Watching).
    func startFileWatching() async {
        guard !files.isWatching else { return }
        files.isWatching = true
        let (stream, continuation) = AsyncStream<WatchedEvents>.makeStream(bufferingPolicy: .unbounded)
        files.eventInput = continuation
        files.eventConsumer = Task { [weak self] in
            for await events in stream {
                await self?.receiveFileEvents(events)
            }
        }
        // Only events that may concern registry.yml or settings.yml reach the batches: the logs,
        // runtime files and the default skills library change far more often.
        let folders = dataDirectoryFolders
        files.dataDirectoryWatcher = makeFileWatcher(path: dataDirectory.url.path, source: .dataDirectory) { event in
            !Engine.dataDirectoryFileNames(of: event, folders: folders).isEmpty
        }
        updateFileWatching()
    }

    /// docs/architecture.md › Shutdown, step 3: closes the FSEvents streams. Changes not yet
    /// processed are dropped.
    func stopFileWatching() async {
        guard files.isWatching else { return }
        files.isWatching = false
        for watcher in files.projectWatchers.values {
            watcher.stop()
        }
        files.projectWatchers.removeAll()
        files.dataDirectoryWatcher?.stop()
        files.dataDirectoryWatcher = nil
        files.eventInput?.finish()
        files.eventInput = nil
        files.eventConsumer?.cancel()
        files.eventConsumer = nil
        files.flushTimer?.cancel()
        files.flushTimer = nil
        files.pending.removeAll()
        files.pendingFirstProjectEvent = nil
        files.closedBatches.removeAll()
    }

    /// Watches exactly the top-level project roots of the registry in memory: a stream starts
    /// for each new root and stops for each root no longer registered. The engine calls it
    /// after every batch that touched the data directory, so a registry write is followed
    /// within one batch; project registration may call it at once.
    func updateFileWatching() {
        guard files.isWatching else { return }
        let wanted = domain.registry.loadableEntries
        let wantedSet = Set(wanted)
        for (root, watcher) in files.projectWatchers where !wantedSet.contains(root) {
            watcher.stop()
            files.projectWatchers[root] = nil
        }
        for root in wanted where files.projectWatchers[root] == nil {
            if let watcher = makeFileWatcher(path: root, source: .projectRoot(root)) {
                files.projectWatchers[root] = watcher
            }
        }
    }

    /// Looks up `git`, `gofmt` and `swift-format` in the captured login-shell environment
    /// (docs/architecture.md › Startup step 7 and › Child processes, rule 5). Runs once, after
    /// the environment capture.
    func lookUpFileTools(environment: [String: String]) async {
        let tools = await FileTools.lookUp(environment: environment, log: log)
        guard !files.toolsSetByTest else { return }
        files.tools = tools
    }

    /// Sets the tools directly, for tests; the lookup of the engine start does not replace them.
    func useFileTools(_ tools: FileTools) {
        files.tools = tools
        files.toolsSetByTest = true
    }

    /// Sets the formatter timeout, for tests.
    func useFormatTimeout(_ timeout: Duration) {
        files.formatTimeout = timeout
    }

    /// The folders watched now: the data directory, then the project roots, sorted.
    func watchedFolders() -> [String] {
        (files.dataDirectoryWatcher.map { [$0.path] } ?? []) + files.projectWatchers.keys.sorted()
    }

    /// Observes the `projectDataFilesChanged` calls of the file watcher, for tests.
    func observeProjectDataChanges(_ observer: (@Sendable (ProjectID, [String]) -> Void)?) {
        files.dataChangeObserver = observer
    }

    private func makeFileWatcher(path: String, source: WatchedEvents.Source,
                                 keep: (@Sendable (FileWatcher.Event) -> Bool)? = nil) -> FileWatcher? {
        guard let input = files.eventInput else { return nil }
        let watcher = FileWatcher(path: path) { events in
            let kept = keep.map { events.filter($0) } ?? events
            if !kept.isEmpty {
                input.yield(WatchedEvents(source: source, events: kept))
            }
        }
        guard watcher.start() else {
            log.error(.files, "cannot watch \(path) with FSEvents")
            return nil
        }
        return watcher
    }

    // MARK: Batching

    /// Collects the events of a stream into the pending batch and schedules its end: 300 ms
    /// after the last event, or 2 s after the first project root event of the batch, whichever
    /// comes first (docs/engine-api.md › Limits, files.changed events).
    func receiveFileEvents(_ events: WatchedEvents) {
        guard files.isWatching else { return }
        let now = ContinuousClock.now
        files.pending.append(events)
        if case .projectRoot = events.source, files.pendingFirstProjectEvent == nil {
            files.pendingFirstProjectEvent = now
        }
        var delay = FileService.quietDelay
        if let first = files.pendingFirstProjectEvent {
            let remaining = first + FileService.maximumDelay - now
            if remaining < delay {
                delay = max(remaining, .zero)
            }
        }
        files.flushTimer?.cancel()
        files.flushGeneration += 1
        let generation = files.flushGeneration
        files.flushTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.closeFileBatch(generation: generation)
        }
    }

    /// Closes the pending batch and processes the closed batches one after the other.
    private func closeFileBatch(generation: Int) async {
        guard files.isWatching, generation == files.flushGeneration, !files.pending.isEmpty else { return }
        files.closedBatches.append(files.pending)
        files.pending.removeAll()
        files.pendingFirstProjectEvent = nil
        files.flushTimer = nil
        guard !files.isProcessing else { return }
        files.isProcessing = true
        while files.isWatching, !files.closedBatches.isEmpty {
            let batch = files.closedBatches.removeFirst()
            await processFileChanges(batch)
        }
        files.isProcessing = false
    }
}
