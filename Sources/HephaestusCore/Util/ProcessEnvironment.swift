import Foundation

/// Environment rules of docs/architecture.md › Child processes and docs/chats.md › Environment.
public enum ProcessEnvironment {
    /// Prefix of the variables that never reach a child process.
    public static let hephaestusPrefix = "HEPHAESTUS_"

    /// Variable added to the environment of every Claude process.
    public static let mcpToolTimeout = (name: "MCP_TOOL_TIMEOUT", value: "1800000")

    /// The environment without any `HEPHAESTUS_*` variable.
    public static func withoutHephaestusVariables(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix(hephaestusPrefix) }
    }

    /// The environment of a Claude process: the captured environment without any
    /// `HEPHAESTUS_*` variable, plus `MCP_TOOL_TIMEOUT=1800000`.
    public static func claudeEnvironment(from captured: [String: String]) -> [String: String] {
        var environment = withoutHephaestusVariables(captured)
        environment[mcpToolTimeout.name] = mcpToolTimeout.value
        return environment
    }

    /// Splits the output of `env -0` on NUL characters; every part of the form `NAME=VALUE`
    /// becomes a variable and other parts are skipped.
    public static func parseNULSeparated(_ data: Data) -> [String: String] {
        var environment: [String: String] = [:]
        for part in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let text = String(data: Data(part), encoding: .utf8),
                  let equals = text.firstIndex(of: "="),
                  equals != text.startIndex
            else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }
}
