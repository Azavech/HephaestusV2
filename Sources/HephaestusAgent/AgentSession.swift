import Darwin
import Foundation

/// One connection of the agent (docs/virtual-machines.md › Messages): it sends the hello, then
/// answers the requests one at a time, in the order they arrive, until the stream ends.
final class AgentSession {
    typealias Handler = (AgentParams, Data) throws -> AgentResult

    private let input: Int32
    private let output: Int32
    private let handlers: [String: Handler]

    init(input: Int32, output: Int32, handlers: [String: Handler] = AgentSession.systemHandlers) {
        self.input = input
        self.output = output
        self.handlers = handlers
        // A write to a host that went away fails with `EPIPE` and raises no `SIGPIPE`.
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
    }

    /// The methods of docs/virtual-machines.md › Methods.
    static let systemHandlers: [String: Handler] = [
        "status": { _, _ in AgentResult(json: AgentStatus.current()) },
        "screenshot": { _, _ in try AgentScreen.screenshot() },
        "click": { params, _ in try AgentInput.click(params) },
        "drag": { params, _ in try AgentInput.drag(params) },
        "scroll": { params, _ in try AgentInput.scroll(params) },
        "type": { params, _ in try AgentInput.type(params) },
        "key": { params, _ in try AgentInput.key(params) },
        "uiTree": { params, _ in try AgentAccessibility.tree(params) },
        "exec": { params, _ in try AgentCommands.exec(params) },
        "stat": { params, _ in try AgentFiles.status(params) },
        "list": { params, _ in try AgentFiles.list(params) },
        "makeDirectory": { params, _ in try AgentFiles.makeDirectory(params) },
        "readFile": { params, _ in try AgentFiles.readFile(params) },
        "writeFile": { params, data in try AgentFiles.writeFile(params, data) },
        "setEnv": { params, _ in try AgentEnvironment.set(params) },
    ]

    /// Serves the connection; returns when the stream ends or a frame breaks the protocol. The
    /// hello and each request have an autorelease pool of their own: the thread of the connection
    /// never ends, so nothing else frees what Foundation autoreleases on it, the pipes of a
    /// `status` included.
    func run() {
        do {
            try autoreleasepool {
                try AgentFrame(json: ["type": "hello", "protocol": AgentInfo.protocolVersion, "status": AgentStatus.current()])
                    .write(to: output)
            }
            while try autoreleasepool(invoking: serveOne) {}
        } catch {
            // The stream ended: the connector connects again.
        }
    }

    /// Reads one frame and answers the request it holds; false at the end of the stream.
    private func serveOne() throws -> Bool {
        guard let frame = try AgentFrame.read(from: input) else { return false }
        guard frame.json["type"] as? String == "request", let id = frame.json["id"] as? NSNumber,
              let method = frame.json["method"] as? String else { return true }
        let params = AgentParams(values: frame.json["params"] as? [String: Any] ?? [:])
        var response = AgentFrame(json: ["type": "response", "id": id])
        do {
            guard let handler = handlers[method] else { throw AgentError("Unknown method \(method).") }
            let result = try handler(params, frame.data)
            response.json["result"] = result.json
            response.data = result.data
        } catch let error as AgentError {
            response.json["error"] = error.message
        } catch {
            response.json["error"] = AgentError(error.localizedDescription).message
        }
        do {
            try response.write(to: output)
        } catch is AgentFrame.TooLarge {
            try AgentFrame(json: ["type": "response", "id": id, "error": "The answer is over the limits of the protocol."])
                .write(to: output)
        } catch is AgentFrame.Unencodable {
            try AgentFrame(json: ["type": "response", "id": id, "error": "The answer cannot be written as JSON."])
                .write(to: output)
        }
        return true
    }
}
