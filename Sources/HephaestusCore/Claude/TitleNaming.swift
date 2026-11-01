import Foundation

/// What a naming call names, with its input (docs/chats.md › Haiku naming › Inputs).
public enum NamingSubject: Sendable, Hashable {
    /// A ticket created without a title: its description. Titles of at most 70 characters.
    case ticket(description: String)
    /// A bundle created without a title: its tickets in bundle order. Titles of at most 60
    /// characters.
    case bundle(tickets: [TicketTitle])
    /// A chat after its first user message with text. Titles of at most 60 characters.
    case chat(firstMessage: String)

    /// One line `<ticket id>: <ticket title>` of a bundle's input.
    public struct TicketTitle: Sendable, Hashable {
        public var id: TicketID
        public var title: String

        public init(id: TicketID, title: String) {
            self.id = id
            self.title = title
        }
    }
}

/// Names tickets, bundles and chats (docs/chats.md › Haiku naming). The engine applies a title
/// only while the subject still has its provisional title; a nil answer keeps the provisional
/// title. The engine calls it, so that tests can provide another implementation
/// (docs/architecture.md › HephaestusCore folders).
public protocol TitleNamer: Sendable {
    /// The cleaned title for `subject` (docs/chats.md › Output cleanup), or nil after a failure,
    /// a timeout or an empty answer.
    func title(for subject: NamingSubject) async -> String?
}

/// The naming of the app: one `claude -p --model haiku` call per subject, at most 2 at once,
/// 30 s timeout (docs/chats.md › Haiku naming › Command).
public struct HaikuTitleNamer: TitleNamer {
    let runtime: HaikuNamingRuntime

    public init() {
        runtime = HaikuNamingRuntime()
    }

    /// Connects the namer to the engine whose CLI, environment and data directory it uses.
    func attach(to engine: Engine) {
        runtime.attach(engine)
    }

    public func title(for subject: NamingSubject) async -> String? {
        await runtime.title(for: subject)
    }

    // MARK: Inputs (docs/chats.md › Haiku naming › Inputs)

    /// The part after the label of an input is cut at 4,000 characters.
    static let inputLimit = 4_000

    /// The `<input>` argument: the label line, then the subject's text cut at 4,000 characters.
    static func input(for subject: NamingSubject) -> String {
        let label: String
        let body: String
        switch subject {
        case .ticket(let description):
            label = "Ticket description:"
            body = description
        case .bundle(let tickets):
            label = "Tickets:"
            body = tickets.map { "\($0.id): \($0.title)" }.joined(separator: "\n")
        case .chat(let firstMessage):
            label = "First message:"
            body = firstMessage
        }
        return label + "\n" + String(body.prefix(inputLimit))
    }

    /// The maximum title length: 70 for a ticket, 60 for a bundle or a chat.
    static func maximumLength(for subject: NamingSubject) -> Int {
        if case .ticket = subject { return 70 }
        return 60
    }

    static func prompt(for subject: NamingSubject) -> Prompts.Name {
        switch subject {
        case .ticket: return .namingTicket
        case .bundle: return .namingBundle
        case .chat: return .namingChat
        }
    }

    static func kind(of subject: NamingSubject) -> String {
        switch subject {
        case .ticket: return "ticket"
        case .bundle: return "bundle"
        case .chat: return "chat"
        }
    }

    // MARK: Output cleanup (docs/chats.md › Haiku naming › Output cleanup)

    /// Step 1: stdout parsed as one JSON object whose `is_error` is not true; its `result`
    /// cleaned by steps 2 to 7. Returns the title, or why the provisional title stays.
    static func title(fromOutput output: Data, maximumLength: Int) -> (title: String?, failure: String?) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: output), let object = value.objectValue else {
            return (nil, "the output is not a JSON object")
        }
        if object["is_error"]?.claudeBool == true { return (nil, "is_error is true") }
        guard let result = object["result"]?.stringValue else { return (nil, "the output has no result") }
        guard let title = cleanTitle(result, maximumLength: maximumLength) else { return (nil, "the title is empty") }
        return (title, nil)
    }

    /// The quote characters removed around a title.
    static let quoteCharacters: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "«", "»", "`"]

    /// The leading labels removed by step 3, compared in any letter case.
    static let titlePrefixes = ["title:", "ticket title:", "bundle title:", "chat title:"]

    /// Steps 2 to 7: first line of the trimmed result, a leading `Title:`, `Ticket title:`,
    /// `Bundle title:` or `Chat title:` removed, surrounding quote characters and trailing periods
    /// removed until neither changes the text, cut at the last space at or before the maximum;
    /// nil when nothing is left.
    static func cleanTitle(_ result: String, maximumLength: Int) -> String? {
        var text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = titlePrefixes.first(where: { String(text.prefix($0.count)).lowercased() == $0 }) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var previous: String
        repeat {
            previous = text
            // Step 4.
            var changed = true
            while changed {
                changed = false
                if let first = text.first, quoteCharacters.contains(first) {
                    text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
                if let last = text.last, quoteCharacters.contains(last) {
                    text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
            // Step 5.
            while text.hasSuffix(".") {
                text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } while text != previous
        if text.count > maximumLength {
            let characters = Array(text)
            let cut = (0...maximumLength).last { characters[$0] == " " } ?? maximumLength
            text = String(characters[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}

/// The state of the app's namer: the engine it uses, the queue of calls and the shutdown.
final class HaikuNamingRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private weak var engine: Engine?
    private var stopped = false
    /// At most 2 naming calls run at once; the others wait in first-in first-out order.
    let queue = NamingQueue(limit: 2)
    /// The timeout of a call, and the SIGKILL that follows its SIGTERM (docs/chats.md › Signals).
    var timeout: Duration = .seconds(30)
    var killGrace: Duration = .seconds(2)

    func attach(_ engine: Engine) {
        lock.withLock { self.engine = engine }
    }

    /// The engine stops: later calls keep the provisional title.
    func stop() {
        lock.withLock { stopped = true }
    }

    private var activeEngine: Engine? {
        lock.withLock { stopped ? nil : engine }
    }

    func title(for subject: NamingSubject) async -> String? {
        guard let engine = activeEngine, let context = await engine.namingContext() else { return nil }
        let kind = HaikuTitleNamer.kind(of: subject)
        let argv = ClaudeCommandLine.naming(cliPath: context.path, prompt: Prompts.text(HaikuTitleNamer.prompt(for: subject)),
                                            input: HaikuTitleNamer.input(for: subject))
        let request = ChildProcessRequest(executable: argv[0], arguments: Array(argv.dropFirst()), environment: context.environment,
                                          currentDirectory: context.workingDirectory)
        await queue.acquire()
        guard activeEngine != nil else {
            await queue.release()
            return nil
        }
        let result = await ClaudeHelperRun.run(request, launcher: context.launcher, registry: context.registry, timeout: timeout,
                                               killGrace: killGrace)
        await queue.release()
        if result.timedOut {
            context.log.warn(.claude, "naming of a \(kind) timed out")
            return nil
        }
        if let spawnError = result.spawnError {
            context.log.warn(.claude, "naming of a \(kind) could not start: \(spawnError)")
            return nil
        }
        guard result.termination == .exited(0) else {
            context.log.warn(.claude, "naming of a \(kind) failed: \(result.termination.map { "\($0)" } ?? "no exit status")")
            return nil
        }
        let outcome = HaikuTitleNamer.title(fromOutput: result.standardOutput, maximumLength: HaikuTitleNamer.maximumLength(for: subject))
        if let failure = outcome.failure {
            context.log.warn(.claude, "naming of a \(kind) failed: \(failure)")
        }
        return outcome.title
    }
}

/// A first-in first-out limit on the naming calls running at once.
actor NamingQueue {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the first waiting call, or frees it.
    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// What a naming call needs from the engine.
struct NamingContext: Sendable {
    var path: String
    var environment: [String: String]
    var workingDirectory: String
    var launcher: any ClaudeProcessLauncher
    var registry: HelperProcessRegistry
    var log: LogSink
}

extension Engine {
    /// The CLI path, the Claude environment and `Runtime/claude-cwd/` for a naming call; nil
    /// while the CLI is unavailable (after waiting up to 20 s while it is being checked), so that
    /// the provisional title stays (docs/chats.md › Version and status).
    func namingContext() async -> NamingContext? {
        guard !claudeCLI.stopped else { return nil }
        do {
            let context = try await requireClaudeCLI()
            return NamingContext(path: context.path, environment: context.environment, workingDirectory: claudeWorkingDirectory().path,
                                 launcher: configuration.claudeLauncher, registry: claudeCLI.helpers, log: log)
        } catch {
            log.info(.claude, "naming skipped: the Claude CLI is not available")
            return nil
        }
    }
}
