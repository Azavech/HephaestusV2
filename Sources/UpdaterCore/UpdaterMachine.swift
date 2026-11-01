import Foundation

/// The state machine of docs/updater.md › Updater states and the check schedule, with the
/// clock, feed, downloader, verifier and installer injected.
// STUB: release — only the current status is kept; the transitions, the schedule and the
// requests come with the Updater.
public actor UpdaterMachine {
    public private(set) var status: UpdaterStatus = .initial
    public let arguments: UpdaterArguments

    public init(arguments: UpdaterArguments) {
        self.arguments = arguments
    }
}
