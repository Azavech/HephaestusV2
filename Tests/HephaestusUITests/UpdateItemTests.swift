import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/updater.md › Update item: the status bar of main windows shows the item while the Updater
/// runs, the state is `ready`, Install is not chosen and the restart sequence has not started.
@MainActor
@Suite("The Update item")
struct UpdateItemTests {
    static func visible(updaterRunning: Bool = true, state: UpdaterState = .ready, installChosen: Bool = false,
                        restartInProgress: Bool = false) -> Bool {
        UpdateController.updateItemVisible(updaterRunning: updaterRunning, state: state, installChosen: installChosen,
                                           restartInProgress: restartInProgress)
    }

    @Test("It shows while an update is ready, Install is not chosen and the restart has not started")
    func shownWhileReady() {
        #expect(Self.visible())
    }

    @Test("It is hidden in every state other than ready")
    func hiddenOutsideReady() {
        for state in [UpdaterState.idle, .checking, .upToDate, .available, .downloading, .installing, .error] {
            #expect(!Self.visible(state: state), "state \(state.rawValue)")
        }
    }

    @Test("It is hidden while the Updater is not running, after Install was chosen and once the restart sequence started")
    func hiddenOtherwise() {
        #expect(!Self.visible(updaterRunning: false))
        #expect(!Self.visible(installChosen: true))
        #expect(!Self.visible(restartInProgress: true))
    }
}
