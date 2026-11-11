// OWNER: ui-views — the devices of the device previews, from `devices.json` of this Mac
// (docs/views.md › Devices file, Custom size).
import Foundation
import HephaestusCore
import Observation

/// The devices of `<data dir>/devices.json` of this Mac, for every window, those of remote devices
/// included: written with the built-in devices when the file is missing, read again 300 ms after
/// each change of the file, and given the custom sizes the user adds (docs/views.md › Devices
/// file).
@MainActor @Observable
final class PreviewDevicesModel {
    /// The devices of the file; none when it is missing or invalid.
    private(set) var devices: [PreviewDevice] = []
    /// Why the file cannot be read; nil when it can.
    private(set) var readError: String?

    @ObservationIgnored let file: URL
    @ObservationIgnored private var watcher: PreviewDevicesWatcher?

    /// Writes the file when it is missing, reads it and follows its changes.
    init(file: URL) {
        self.file = file
        reload()
        watcher = PreviewDevicesWatcher(file: file) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    convenience init(dataDirectory: DataDirectory) {
        self.init(file: PreviewDeviceCatalog.file(in: dataDirectory))
    }

    /// Reads the file; a missing file is written with the built-in devices first.
    func reload() {
        var contents = PreviewDeviceCatalog.read(file)
        if case .missing = contents {
            _ = try? PreviewDeviceCatalog.writeBuiltInIfMissing(file)
            contents = PreviewDeviceCatalog.read(file)
        }
        switch contents {
        case .missing:
            readError = nil
            if !devices.isEmpty { devices = [] }
        case .devices(let list):
            readError = nil
            if devices != list { devices = list }
        case .invalid(let reason):
            readError = reason
            if !devices.isEmpty { devices = [] }
        }
    }

    /// Adds a custom size to the file; the device added, with its name.
    func addCustomSize(family: PreviewDeviceFamily, width: Int, height: Int, horizontal: PreviewSizeClass,
                       vertical: PreviewSizeClass) throws -> PreviewDevice {
        let device = try PreviewDeviceCatalog.add(family: family, width: width, height: height, horizontal: horizontal,
                                                  vertical: vertical, to: file)
        reload()
        return device
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }
}
