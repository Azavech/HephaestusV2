import Foundation

extension Engine {
    /// The device identity service of the windows of this Mac (docs/architecture.md ›
    /// Local-only services): this device's DeviceInfo, with its current name.
    public func localDeviceInfo() -> DeviceInfo {
        deviceInfo
    }

    /// The device name shown in Settings > Devices (docs/remote.md › Device identity): the name
    /// set there, or the Mac's computer name when none is set.
    public func deviceNameSetting() -> String {
        deviceInfo.name
    }

    /// Settings > Devices › This device's name (docs/remote.md › Device identity): the name is
    /// trimmed; an empty name stores no name, and the Mac's computer name is used; a name that is
    /// not one line of 1 to 63 UTF-8 bytes fails with `invalid`. The name is written to
    /// device.yml, the Bonjour advertisement is registered again with the new instance name and
    /// TXT `name`, and every later `hello` and `welcome` carries it. Open sessions are not
    /// notified and no engine event is emitted. A storage failure throws `internal`.
    public func renameDevice(to name: String) async throws {
        let stored: String?
        do {
            stored = try ModelRules.deviceName(name)
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        guard stored != device.name else { return }
        var updated = device
        updated.name = stored
        do {
            try DeviceFileStore.write(updated, to: dataDirectory)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        device = updated
        let name = deviceInfo.name
        deviceBrowser.ownDeviceName = name
        await syncServer.deviceNameDidChange(name)
    }
}
