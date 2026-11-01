import Foundation

/// Runs a tool with standard input, output and error on `/dev/null` and returns its exit status;
/// -1 when it cannot be started.
public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // The termination handler is never called for a process that did not start.
                continuation.resume(returning: -1)
            }
        }
    }
}
