import Foundation
import Network

/// A device found by Bonjour browsing (docs/remote.md › Browsing): results with the same TXT
/// `id` are merged, and connections use the endpoint of the first result received.
public struct DiscoveredDevice: Sendable, Hashable, Identifiable {
    /// TXT `id`, the device id, uppercase.
    public var id: String
    /// TXT `name`, or the instance name when it is missing or empty.
    public var name: String
    /// TXT `proto`; nil when missing.
    public var proto: String?
    /// The Bonjour service endpoint of the first result received.
    public var endpoint: NWEndpoint

    public init(id: String, name: String, proto: String?, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.proto = proto
        self.endpoint = endpoint
    }

    /// False when `proto` is missing or not `1`: the device is listed with "Incompatible version"
    /// and cannot be selected.
    public var isCompatible: Bool {
        proto == String(DeviceInfo.currentProtocolVersion)
    }
}

/// The local network permission as browsing reports it (docs/remote.md › Local network
/// permission).
public enum LocalNetworkPermission: Sendable, Hashable {
    case unknown
    case allowed
    /// The browser failed with `kDNSServiceErr_PolicyDenied` (-65570).
    case denied
}

/// Bonjour browsing of `_hephaestus2._tcp` in `local.` with TXT records, from launch until the
/// app quits, without this device's own id (docs/remote.md › Browsing). Used by the Add Device
/// sheet, the online status of paired devices and the endpoints of `RemoteEngineConnection`.
// STUB: core-sync — the NWBrowser and the interpretation rules of docs/remote.md › Browsing.
// `start` browses nothing yet, so `devices` stays empty.
public final class DeviceBrowser: @unchecked Sendable {
    /// The Bonjour service type of the sync server.
    public static let serviceType = "_hephaestus2._tcp"

    private let ownDeviceID: String
    private let log: LogSink
    private let lock = NSLock()
    private var currentDevices: [DiscoveredDevice] = []
    private var currentPermission = LocalNetworkPermission.unknown
    private let deviceStreams = StreamFanOut<[DiscoveredDevice]>()

    init(ownDeviceID: String, log: LogSink) {
        self.ownDeviceID = ownDeviceID
        self.log = log
    }

    /// The devices currently seen, This Mac excluded.
    public var devices: [DiscoveredDevice] {
        lock.lock()
        defer { lock.unlock() }
        return currentDevices
    }

    /// The local network permission.
    public var permission: LocalNetworkPermission {
        lock.lock()
        defer { lock.unlock() }
        return currentPermission
    }

    /// A new stream on every access: the current devices, then every change.
    public var deviceUpdates: AsyncStream<[DiscoveredDevice]> {
        deviceStreams.stream(initial: devices)
    }

    /// The device of this id, when it is currently seen.
    public func device(id: String) -> DiscoveredDevice? {
        devices.first { $0.id == id.uppercased() }
    }

    func start() {
        // STUB: core-sync — start the NWBrowser.
    }

    func stop() {
        // STUB: core-sync — cancel the NWBrowser.
        deviceStreams.finish()
    }
}

extension Engine {
    /// Startup step 5: Bonjour browsing for nearby and paired devices.
    // DOC-GAP: docs/architecture.md › Startup always starts browsing, while docs/development.md ›
    // Test rules allow no network beyond 127.0.0.1 and `EngineConfiguration` has no field for
    // browsing; an engine browses only when it advertises (`advertisesBonjour`), so test engines
    // never browse.
    func startDeviceBrowsing() {
        guard configuration.advertisesBonjour else { return }
        deviceBrowser.start()
    }

    /// docs/architecture.md › Shutdown, step 3.
    func stopDeviceBrowsing() {
        deviceBrowser.stop()
    }
}
