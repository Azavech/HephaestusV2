import Foundation

/// The login-shell environment, captured once after the engine starts
/// (docs/chats.md › Environment, docs/architecture.md › Child processes).
public enum LoginShellEnvironment {
    /// The capture command: `/bin/zsh -lic 'env -0'`.
    public static let shell = "/bin/zsh"
    public static let arguments = ["-lic", "env -0"]
    /// Timeout of the capture.
    public static let timeout: Duration = .seconds(10)

    /// Runs the capture shell, which starts from `processEnvironment` without any
    /// `HEPHAESTUS_*` variable, and splits its output on NUL characters; every part of the form
    /// `NAME=VALUE` becomes a variable. When the command fails or times out, the result is
    /// `processEnvironment` itself. Callers remove the `HEPHAESTUS_*` variables before passing
    /// the result to a child process.
    public static func capture(processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                               shell: String = LoginShellEnvironment.shell,
                               arguments: [String] = LoginShellEnvironment.arguments,
                               timeout: Duration = LoginShellEnvironment.timeout,
                               log: LogSink? = nil) async -> [String: String] {
        let request = ChildProcessRequest(
            executable: shell,
            arguments: arguments,
            environment: ProcessEnvironment.withoutHephaestusVariables(processEnvironment)
        )
        do {
            let result = try await ChildProcessRunner.run(request, timeout: timeout)
            guard !result.timedOut else {
                log?.warn(.claude, "the login-shell environment capture timed out; using the app's environment")
                return processEnvironment
            }
            guard result.termination.isSuccess else {
                log?.warn(.claude, "the login-shell environment capture failed (\(result.termination)); using the app's environment")
                return processEnvironment
            }
            let captured = ProcessEnvironment.parseNULSeparated(result.standardOutput)
            // An output without any variable counts as a failure, so that no child starts without
            // PATH (docs/chats.md › Environment).
            guard !captured.isEmpty else {
                log?.warn(.claude, "the login-shell environment capture returned nothing; using the app's environment")
                return processEnvironment
            }
            log?.info(.claude, "captured the login-shell environment (\(captured.count) variables)")
            return captured
        } catch {
            log?.warn(.claude, "the login-shell environment capture could not start (\(error)); using the app's environment")
            return processEnvironment
        }
    }
}
