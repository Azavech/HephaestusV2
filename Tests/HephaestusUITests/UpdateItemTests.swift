import Testing
import UpdaterCore
@testable import HephaestusUI

/// docs/updater.md › Update item, › Settings: while the Updater runs, the status bar of main windows
/// shows `Installing…` while the install is chosen, and `Update available…` in `available`,
/// `downloading` or `ready` while the restart sequence has not started; Update Now shows exactly
/// when the item offers the update.
@MainActor
@Suite("The Update item")
struct UpdateItemTests {
    static func status(_ state: UpdaterState) -> UpdaterStatus {
        UpdaterStatus(state: state, version: "0.5.0", build: 61)
    }

    static func item(updaterRunning: Bool = true, state: UpdaterState = .ready, autoUpdate: Bool = true,
                     installChosen: Bool = false, restartInProgress: Bool = false) -> UpdateController.UpdateItem? {
        UpdateController.updateItem(updaterRunning: updaterRunning, status: status(state), autoUpdate: autoUpdate,
                                    installChosen: installChosen, restartInProgress: restartInProgress)
    }

    static func updateNow(updaterRunning: Bool = true, state: UpdaterState = .ready, installChosen: Bool = false,
                          restartInProgress: Bool = false) -> Bool {
        UpdateController.updateNowVisible(updaterRunning: updaterRunning, status: status(state), installChosen: installChosen,
                                          restartInProgress: restartInProgress)
    }

    @Test("It offers the update in available, downloading and ready, with the tooltip of the state", arguments: [true, false])
    func shownWhileOffered(_ autoUpdate: Bool) {
        #expect(Self.item(state: .available, autoUpdate: autoUpdate)
            == .available(tooltip: "Update v0.5.0(61) available — click to install"))
        #expect(Self.item(state: .downloading, autoUpdate: autoUpdate) == .available(tooltip: "Downloading update v0.5.0(61)…"))
        #expect(Self.item(state: .ready, autoUpdate: autoUpdate)
            == .available(tooltip: autoUpdate ? "Update v0.5.0(61) ready — restarts when idle" : "Update v0.5.0(61) ready"))
    }

    @Test("It is hidden in every other state", arguments: [true, false])
    func hiddenOtherwise(_ autoUpdate: Bool) {
        for state in [UpdaterState.idle, .checking, .upToDate, .installing, .error] {
            #expect(Self.item(state: state, autoUpdate: autoUpdate) == nil, "state \(state.rawValue)")
        }
    }

    @Test("It shows Installing… while the install is chosen, until the app quits")
    func installingWhileChosen() {
        for state in [UpdaterState.available, .downloading, .ready, .installing] {
            #expect(Self.item(state: state, installChosen: true) == .installing, "state \(state.rawValue)")
        }
        #expect(Self.item(state: .ready, installChosen: true, restartInProgress: true) == .installing)
    }

    @Test("It is hidden while the Updater is not running and once an automatic restart started")
    func hiddenWithoutUpdater() {
        #expect(Self.item(updaterRunning: false) == nil)
        #expect(Self.item(updaterRunning: false, installChosen: true) == nil)
        #expect(Self.item(restartInProgress: true) == nil)
        #expect(Self.item(state: .installing, restartInProgress: true) == nil)
    }

    @Test("Update Now shows exactly when the item offers the update")
    func updateNow() {
        for state in [UpdaterState.available, .downloading, .ready] {
            #expect(Self.updateNow(state: state), "state \(state.rawValue)")
            #expect(!Self.updateNow(state: state, installChosen: true), "state \(state.rawValue)")
            #expect(!Self.updateNow(state: state, restartInProgress: true), "state \(state.rawValue)")
            #expect(!Self.updateNow(updaterRunning: false, state: state), "state \(state.rawValue)")
        }
        for state in [UpdaterState.idle, .checking, .upToDate, .installing, .error] {
            #expect(!Self.updateNow(state: state), "state \(state.rawValue)")
        }
    }
}
