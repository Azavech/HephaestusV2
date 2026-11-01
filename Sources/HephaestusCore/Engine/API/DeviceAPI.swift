import Foundation

// docs/engine-api.md › Device and snapshot.

/// `device.info`: the identity and version of the engine's device. Actors: user.
public enum DeviceInfoMethod: EngineMethod {
    public static let name = "device.info"
    public typealias Params = Empty
    public typealias Result = DeviceInfo
}

/// `snapshot.get`: the device-level state a client starts from. Actors: user.
public enum SnapshotGet: EngineMethod {
    public static let name = "snapshot.get"
    public typealias Params = Empty
    public typealias Result = Snapshot
}
