import Foundation

// docs/engine-api.md › Virtual machines.

/// The result of `vms.list` and the data of `vms.changed` (docs/engine-api.md › VMList).
public struct VMList: Codable, Sendable, Hashable {
    /// The virtual machines, oldest first: by `created`, then by `id`.
    public var machines: [VirtualMachine]
    /// The number of virtual machines the engine runs, 0 to 2: the running ones of `machines`,
    /// the setup virtual machines of the images and their installs.
    public var runningCount: Int

    public init(machines: [VirtualMachine] = [], runningCount: Int = 0) {
        self.machines = machines
        self.runningCount = runningCount
    }

    /// The Virtualization framework runs at most this many macOS virtual machines at once.
    public static let maximumRunning = 2

    /// False while 2 virtual machines run: `New VM…` and `Start` are disabled then
    /// (docs/virtual-machines.md › Running virtual machines).
    public var canStartOne: Bool {
        runningCount < Self.maximumRunning
    }
}

/// `vms.list`: the virtual machines and the number that run. Actors: user.
public enum VMsList: EngineMethod {
    public static let name = "vms.list"
    public typealias Params = Empty
    public typealias Result = VMList
}

/// `vms.create`: creates a virtual machine of the user from a Ready image, with a clone of the
/// image's disk, and starts it. Actors: user.
public enum VMsCreate: EngineMethod {
    public static let name = "vms.create"
    public struct Params: Codable, Sendable, Hashable {
        /// One line of 1 to 100 characters, trimmed.
        public var name: String
        /// Id of a Ready image.
        public var imageID: UUID
        public var cores: Int
        /// Its memory in GB.
        public var memoryGB: Int

        public init(name: String, imageID: UUID, cores: Int, memoryGB: Int) {
            self.name = name
            self.imageID = imageID
            self.cores = cores
            self.memoryGB = memoryGB
        }
    }
    public typealias Result = VirtualMachine
}

/// The param of the methods that act on one virtual machine.
public struct VMParams: Codable, Sendable, Hashable {
    public var vmID: UUID

    public init(vmID: UUID) {
        self.vmID = vmID
    }
}

/// `vms.start`: boots a stopped virtual machine from its disk. Actors: user.
public enum VMsStart: EngineMethod {
    public static let name = "vms.start"
    public typealias Params = VMParams
    public typealias Result = VirtualMachine
}

/// `vms.stop`: shuts a virtual machine down and returns once it has stopped; one that Claude
/// started is then deleted. Actors: user.
public enum VMsStop: EngineMethod {
    public static let name = "vms.stop"
    public typealias Params = VMParams
    public typealias Result = Empty
}

/// `vms.delete`: stops the virtual machine at once when it runs and deletes its folder.
/// Actors: user.
public enum VMsDelete: EngineMethod {
    public static let name = "vms.delete"
    public typealias Params = VMParams
    public typealias Result = Empty
}
