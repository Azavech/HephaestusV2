import Foundation
import Testing
@testable import HephaestusUI

/// docs/ui.md › Unsaved changes and quitting and docs/updater.md › Restart rules: the message of
/// the quit alert and of the restart alert counts the working chats of This Mac.
@MainActor
@Suite("Quit and restart alerts")
struct QuitAlertTests {
    @Test("The message reads 1 chat or <n> chats on This Mac will be stopped")
    func message() {
        #expect(AppModel.runningWorkMessage(chats: 1) == "1 chat on This Mac will be stopped.")
        #expect(AppModel.runningWorkMessage(chats: 3) == "3 chats on This Mac will be stopped.")
    }
}
