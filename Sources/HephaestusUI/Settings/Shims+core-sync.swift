// OWNER: ui-shell — temporary stand-ins for the device identity service of core-sync, used by
// Settings > Devices (docs/remote.md › Device identity; docs/ui.md › Devices).
import HephaestusCore

// SHIM(core-sync): delete at integration
// The device identity service (docs/architecture.md › Local-only services: `device.yml`: read,
// rename) has no seam in the skeleton ("device rename (local-only, no seam yet)"). core-sync
// provides these two members on `Engine` with the same names; until then the field shows the
// computer name as its placeholder and a rename fails.
extension Engine {
    /// The name stored in `device.yml`; nil when the Mac's computer name is used.
    func deviceNameSetting() async -> String? {
        nil
    }

    /// Settings > Devices: stores `name` in `device.yml` (nil: the computer name is used),
    /// renames the Bonjour advertisement and uses the name in later `hello` and `welcome`
    /// messages (docs/remote.md › Device identity).
    func renameDevice(to name: String?) async throws {
        throw EngineError.notImplemented("Renaming this device")
    }
}
