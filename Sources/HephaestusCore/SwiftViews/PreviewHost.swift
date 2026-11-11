import Darwin
import Foundation

/// A running preview host (docs/views.md › Preview host): its process, the commands written on its
/// standard input and the messages read on its standard output, one JSON object per line.
final class PreviewHost: @unchecked Sendable {
    /// A command of the host.
    struct Command: Encodable {
        var type: String
        /// `<session id>/<preview index>`.
        var window: String
        var preview: String?
        var width: Int?
        var height: Int?
        var appearance: String?
        var dynamicTypeSize: String?
        var kind: String?
        var x: Double?
        var y: Double?
        var button: String?
        var clickCount: Int?
        var deltaX: Double?
        var deltaY: Double?
        var characters: String?
        var charactersIgnoringModifiers: String?
        var keyCode: Int?
        var modifiers: [String]?
        /// For a device preview: its size classes, `compact` or `regular`, its idiom, `phone` or
        /// `pad`, and its scale.
        var horizontalSizeClass: String?
        var verticalSizeClass: String?
        var idiom: String?
        var scale: Int?
        /// `select`: the number of the request, which the answer repeats.
        var request: Int?
        /// `track`: the id of the element to outline; nil for none.
        var element: String?

        static func open(window: String, preview: String, settings: PreviewSettings, device: PreviewDevice? = nil) -> Command {
            var command = Command(type: "open", window: window, preview: preview)
            command.apply(settings, device: device)
            return command
        }

        static func update(window: String, settings: PreviewSettings, device: PreviewDevice? = nil) -> Command {
            var command = Command(type: "update", window: window)
            command.apply(settings, device: device)
            return command
        }

        static func input(window: String, event: PreviewInputEvent) -> Command {
            let type: String
            switch event.kind {
            case .mouseDown, .mouseUp, .mouseDragged, .mouseMoved: type = "mouse"
            case .scroll: type = "scroll"
            case .keyDown, .keyUp: type = "key"
            }
            return Command(type: type, window: window, kind: event.kind.rawValue, x: event.x, y: event.y, button: event.button,
                           clickCount: event.clickCount, deltaX: event.deltaX, deltaY: event.deltaY, characters: event.characters,
                           charactersIgnoringModifiers: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                           modifiers: event.modifiers)
        }

        /// The settings of a Mac preview, or of a device preview: the device's size and size
        /// classes in the orientation of the settings (docs/views.md › Device rows).
        mutating func apply(_ settings: PreviewSettings, device: PreviewDevice? = nil) {
            width = settings.width
            height = settings.height
            appearance = settings.appearance.rawValue
            dynamicTypeSize = settings.dynamicTypeSize.rawValue
            guard let device else { return }
            let size = device.size(in: settings.orientation)
            let classes = device.sizeClasses(in: settings.orientation)
            width = size.width
            height = size.height
            horizontalSizeClass = classes.horizontal.rawValue
            verticalSizeClass = classes.vertical.rawValue
            idiom = device.family == .iPad ? "pad" : "phone"
            scale = device.scale
        }
    }

    /// A message of the host.
    struct Message: Decodable {
        var type: String
        var window: String?
        var width: Int?
        var height: Int?
        var png: String?
        /// A line of the standard error of the iOS host.
        var line: String?
        /// `selected`: the request answered and the ids of the elements at the place.
        var request: Int?
        var elements: [String]?
        /// `outlines`: the places of the tracked element, `[x, y, width, height]` each.
        var outlines: [[Double]]?
    }

    let process: ChildProcess
    private let buffers = Buffers()
    private let readers: [PreviewPipeReader]

    /// The lines of standard error kept for the message of a host that stopped.
    static let stderrLines = 40

    /// Starts the host. `onMessage` receives each message; `onExit` its end, unless it was
    /// stopped, with the last lines of its standard error.
    init(executable: URL, directory: URL, environment: [String: String], onMessage: @escaping @Sendable (Message) -> Void,
         onExit: @escaping @Sendable (ProcessTermination, [String]) -> Void) throws {
        let request = ChildProcessRequest(executable: executable.path, arguments: [], environment: environment,
                                          currentDirectory: directory.path, standardInput: .pipe, standardOutput: .pipe,
                                          standardError: .pipe)
        let process = try ChildProcess.spawn(request)
        self.process = process
        let buffers = self.buffers
        var readers: [PreviewPipeReader] = []
        if let output = process.standardOutput {
            readers.append(PreviewPipeReader(output) { chunk in
                for line in buffers.outputLines(chunk) {
                    if let message = try? JSONDecoder().decode(Message.self, from: line) {
                        onMessage(message)
                    }
                }
            })
        }
        if let error = process.standardError {
            readers.append(PreviewPipeReader(error) { buffers.receiveError($0) })
        }
        self.readers = readers
        Task.detached {
            let termination = await process.waitForExit()
            for reader in readers { await reader.end() }
            let (stopped, tail) = buffers.end
            if !stopped { onExit(termination, tail) }
        }
    }

    /// The lines read and the stop, shared with the readers.
    private final class Buffers: @unchecked Sendable {
        private let lock = NSLock()
        private var outputPending = Data()
        private var errorPending = Data()
        private var errorTail: [String] = []
        private var stopping = false

        func outputLines(_ chunk: Data) -> [Data] {
            lock.withLock {
                outputPending.append(chunk)
                var lines: [Data] = []
                while let newline = outputPending.firstIndex(of: 0x0A) {
                    lines.append(outputPending.subdata(in: outputPending.startIndex..<newline))
                    outputPending.removeSubrange(outputPending.startIndex...newline)
                }
                return lines
            }
        }

        func receiveError(_ chunk: Data) {
            lock.withLock {
                errorPending.append(chunk)
                while let newline = errorPending.firstIndex(of: 0x0A) {
                    errorTail.append(String(decoding: errorPending[errorPending.startIndex..<newline], as: UTF8.self))
                    errorPending.removeSubrange(errorPending.startIndex...newline)
                }
                if errorTail.count > PreviewHost.stderrLines { errorTail.removeFirst(errorTail.count - PreviewHost.stderrLines) }
            }
        }

        func stop() {
            lock.withLock { stopping = true }
        }

        var end: (stopped: Bool, tail: [String]) {
            lock.withLock { (stopping, errorTail) }
        }
    }

    /// Writes a command; a host that ended drops it.
    func send(_ command: Command) {
        guard var data = try? JSONEncoder().encode(command) else { return }
        data.append(0x0A)
        try? process.standardInput?.write(contentsOf: data)
    }

    /// Ends the host: its standard input closes, which makes it exit, then `SIGTERM` and `SIGKILL`
    /// when it does not.
    func stop() {
        buffers.stop()
        try? process.standardInput?.close()
        let process = self.process
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            guard !process.hasExited else { return }
            process.signalGroup(SIGTERM)
            try? await Task.sleep(for: .seconds(3))
            if !process.hasExited { process.signalGroup(SIGKILL) }
        }
    }

    /// `exit code <n>` or `signal <n>`.
    static func reason(_ termination: ProcessTermination) -> String {
        switch termination {
        case .exited(let code): return "exit code \(code)"
        case .signaled(let signal): return "signal \(signal)"
        }
    }
}
