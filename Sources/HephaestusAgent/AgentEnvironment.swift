import Darwin
import Foundation

/// The method `setEnv`: an environment variable for the commands of `exec` and for the apps of
/// the account's session (docs/virtual-machines.md › Methods, › Claude token).
enum AgentEnvironment {
    /// The command that sets a variable of the account's launchd environment; the name and the
    /// value follow.
    static let launchctl = ["/bin/launchctl", "setenv"]

    /// Sets the variable in the agent's own environment, which the commands that `exec` starts
    /// afterwards inherit, then with `launchctl` when given; a `launchctl` that fails fails the
    /// request with its standard error.
    static func set(_ params: AgentParams, launchctl: [String]? = AgentEnvironment.launchctl) throws -> AgentResult {
        let name = try params.string("name")
        let value = try params.string("value")
        guard isName(name) else { throw AgentError("name: use letters, digits and _, not starting with a digit.") }
        guard setenv(name, value, 1) == 0 else {
            throw AgentError("The variable could not be set: \(String(cString: strerror(errno))).")
        }
        if let launchctl {
            try run(launchctl + [name, value])
        }
        return AgentResult()
    }

    /// Letters, digits and `_`, not starting with a digit.
    static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw AgentError("\(arguments[0]) could not be started: \(error.localizedDescription)")
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentError(message.isEmpty ? "\(arguments[0]) exited with code \(process.terminationStatus)." : message)
        }
    }
}
