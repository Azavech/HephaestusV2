// OWNER: ui-shell — the Add Device sheet (docs/remote.md › Adding a device, › Entering a new code).
import HephaestusCore
import SwiftUI

/// Add Device: the Nearby list, the address field and the pairing code; Connect runs `RemoteEngineConnection.attempt`. It opens on a main window (Device menu, reconnect view) or on the Settings window (`window` nil).
// STUB: ui-shell
struct AddDeviceSheet: View {
    /// The device of Enter Pairing Code…, selected in the Nearby list or with its stored address.
    let preselectedDeviceID: String?
    let window: WindowState?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaceholderSheet(name: "AddDeviceSheet") { dismiss() }
    }
}
