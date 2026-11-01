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
public final class DeviceBrowser: @unchecked Sendable {
    /// The Bonjour service type of the sync server.
    public static let serviceType = "_hephaestus2._tcp"
    /// `kDNSServiceErr_PolicyDenied`: the local network permission is denied.
    static let policyDenied: Int32 = -65570
    /// The delay before browsing again after the browser failed.
    static let restartDelay: TimeInterval = 5

    /// One browse result, in the order results were received.
    struct Result: Sendable, Hashable {
        /// The order of arrival.
        var sequence: Int
        var endpoint: NWEndpoint
        /// The service instance name.
        var instanceName: String
        var txt: [String: String]
    }

    private let ownDeviceID: String
    private let log: LogSink
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "HephaestusV2.sync.browser")
    private var browser: NWBrowser?
    private var isRunning = false
    private var results: [NWEndpoint: Result] = [:]
    private var nextSequence = 0
    private var currentDevices: [DiscoveredDevice] = []
    private var currentPermission = LocalNetworkPermission.unknown
    private var currentOwnName: String?
    private let deviceStreams = StreamFanOut<[DiscoveredDevice]>()
    private let permissionStreams = StreamFanOut<LocalNetworkPermission>()

    init(ownDeviceID: String, log: LogSink) {
        self.ownDeviceID = ownDeviceID.uppercased()
        self.log = log
    }

    /// The devices currently seen, This Mac excluded, sorted by name.
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
        lock.lock()
        defer { lock.unlock() }
        return deviceStreams.stream(initial: currentDevices)
    }

    /// A new stream on every access: the current permission, then every change.
    public var permissionUpdates: AsyncStream<LocalNetworkPermission> {
        lock.lock()
        defer { lock.unlock() }
        return permissionStreams.stream(initial: currentPermission)
    }

    /// The device of this id, when it is currently seen.
    public func device(id: String) -> DiscoveredDevice? {
        devices.first { $0.id == id.uppercased() }
    }

    /// This device's name, sent in the `hello` of every connection this app opens; set by the
    /// engine at launch and when the name changes (docs/remote.md › Device identity).
    // DOC-GAP: docs/remote.md › Device identity uses the new name in every later `hello`, but a
    // `RemoteEngineConnection` receives the local DeviceInfo once, at its creation; it reads the
    // current name here, next to the device id this browser already excludes.
    var ownDeviceName: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentOwnName
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            currentOwnName = newValue
        }
    }

    /// The name a `hello` carries for the local device `local`.
    func helloName(for local: DeviceInfo) -> String {
        guard local.id.uppercased() == ownDeviceID, let name = ownDeviceName, !name.isEmpty else { return local.name }
        return name
    }

    func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startBrowser()
        }
    }

    func stop() {
        queue.sync {
            self.isRunning = false
            self.browser?.cancel()
            self.browser = nil
        }
        deviceStreams.finish()
        permissionStreams.finish()
    }

    // MARK: Interpretation (docs/remote.md › Browsing)

    /// The devices of a set of browse results: results whose `id` is missing, not a UUID or this
    /// device's id are ignored; results with the same id are merged into the device of the first
    /// one received; a missing or empty `name` uses the instance name. Sorted by name, then id.
    static func devices(from results: [Result], ownDeviceID: String) -> [DiscoveredDevice] {
        var byID: [String: DiscoveredDevice] = [:]
        for result in results.sorted(by: { $0.sequence < $1.sequence }) {
            guard let rawID = result.txt["id"], Identifiers.isUUID(rawID) else { continue }
            let id = rawID.uppercased()
            guard id != ownDeviceID.uppercased(), byID[id] == nil else { continue }
            let name = result.txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? result.instanceName
            byID[id] = DiscoveredDevice(id: id, name: name, proto: result.txt["proto"], endpoint: result.endpoint)
        }
        return byID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: Browser

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: DeviceBrowser.serviceType, domain: "local.")
        let browser = NWBrowser(for: descriptor, using: NWParameters())
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser else { return }
            self.browserStateChanged(state, browser: browser)
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] _, changes in
            guard let self, let browser, browser === self.browser else { return }
            self.apply(changes)
        }
        browser.start(queue: queue)
    }

    /// What a browser state leads to (docs/remote.md › Browsing).
    enum StateOutcome: Equatable {
        case none
        /// The browser is ready: the local network permission is allowed.
        case allowed
        /// The browser failed, or waits with `kDNSServiceErr_PolicyDenied`: it is cancelled,
        /// logged and restarted; `denied` is true for `kDNSServiceErr_PolicyDenied`.
        case restart(NWError, denied: Bool)
    }

    static func outcome(of state: NWBrowser.State) -> StateOutcome {
        switch state {
        case .ready:
            return .allowed
        case .waiting(let error) where isPolicyDenied(error):
            return .restart(error, denied: true)
        case .failed(let error):
            return .restart(error, denied: isPolicyDenied(error))
        default:
            return .none
        }
    }

    private func browserStateChanged(_ state: NWBrowser.State, browser: NWBrowser) {
        guard browser === self.browser else { return }
        switch DeviceBrowser.outcome(of: state) {
        case .none:
            break
        case .allowed:
            setPermission(.allowed)
        case .restart(let error, let denied):
            if denied {
                setPermission(.denied)
            }
            log.warn(.sync, "browsing failed: \(SyncServer.describe(error))")
            // docs/remote.md › Browsing: results dropped, browsing again 5 s later.
            browser.cancel()
            self.browser = nil
            results.removeAll()
            publishDevices()
            queue.asyncAfter(deadline: .now() + DeviceBrowser.restartDelay) { [weak self] in
                guard let self, self.isRunning, self.browser == nil else { return }
                self.startBrowser()
            }
        }
    }

    private func apply(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                add(result)
            case .removed(let result):
                results[result.endpoint] = nil
            case .changed(old: let old, new: let new, flags: _):
                let sequence = results[old.endpoint]?.sequence
                results[old.endpoint] = nil
                add(new, sequence: sequence)
            case .identical:
                break
            @unknown default:
                break
            }
        }
        publishDevices()
    }

    private func add(_ result: NWBrowser.Result, sequence: Int? = nil) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            for key in ["id", "name", "proto"] {
                if case .string(let value)? = record.getEntry(for: key) {
                    txt[key] = value
                }
            }
        }
        let order: Int
        if let sequence {
            order = sequence
        } else {
            order = nextSequence
            nextSequence += 1
        }
        results[result.endpoint] = Result(sequence: order, endpoint: result.endpoint, instanceName: name, txt: txt)
    }

    private func publishDevices() {
        let devices = DeviceBrowser.devices(from: Array(results.values), ownDeviceID: ownDeviceID)
        lock.lock()
        defer { lock.unlock() }
        guard devices != currentDevices else { return }
        currentDevices = devices
        deviceStreams.yield(devices)
    }

    private func setPermission(_ permission: LocalNetworkPermission) {
        lock.lock()
        defer { lock.unlock() }
        guard permission != currentPermission else { return }
        currentPermission = permission
        permissionStreams.yield(permission)
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == policyDenied
        }
        return false
    }
}

extension Engine {
    /// Startup step 5: Bonjour browsing for nearby and paired devices.
    // DOC-GAP: docs/architecture.md › Startup always starts browsing, while docs/development.md ›
    // Test rules allow no network beyond 127.0.0.1 and `EngineConfiguration` has no field for
    // browsing; an engine browses only when it advertises (`advertisesBonjour`), so test engines
    // never browse.
    func startDeviceBrowsing() {
        deviceBrowser.ownDeviceName = deviceInfo.name
        guard configuration.advertisesBonjour else { return }
        deviceBrowser.start()
    }

    /// docs/architecture.md › Shutdown, step 3.
    func stopDeviceBrowsing() {
        deviceBrowser.stop()
    }
}
