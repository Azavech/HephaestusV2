import Foundation
import IOKit.pwr_mgt

/// Keeps the guest's display awake while the agent runs (docs/virtual-machines.md › Guest
/// agent). A guest left without input turns its display off and then locks its screen: the
/// screenshots are black, and nothing the agent posts wakes or unlocks the guest.
enum AgentPower {
    /// Takes the power assertion that keeps the display, and with it the guest, from sleeping.
    /// The assertion lasts as long as the process. Returns false when the system refuses it.
    @discardableResult
    static func keepAwake() -> Bool {
        var assertion = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "HephaestusV2 guest agent" as CFString, &assertion)
        return result == kIOReturnSuccess
    }
}
