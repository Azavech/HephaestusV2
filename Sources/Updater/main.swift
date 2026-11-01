import Foundation
import UpdaterCore

// The Updater helper process (docs/updater.md). It parses its command line, then exits.
// STUB: release — creating the UpdaterMachine, connecting it to UpdaterIPC and running the main
// run loop come with the Updater.

do {
    _ = try UpdaterArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as UpdaterArguments.UsageError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(UpdaterArguments.usageExitStatus)
} catch {
    FileHandle.standardError.write(Data("Updater: \(error)\n".utf8))
    exit(UpdaterArguments.usageExitStatus)
}
exit(0)
