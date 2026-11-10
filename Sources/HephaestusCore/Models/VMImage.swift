import Foundation

/// The state of a macOS image of virtual machines (docs/virtual-machines.md › Image states).
public enum VMImageState: String, Codable, Sendable, Hashable, CaseIterable {
    /// The IPSW of the version is being downloaded.
    case downloading
    /// macOS is being installed into the image's disk, or the install waits for a free virtual
    /// machine.
    case installing
    /// macOS is installed; the setup is not finished.
    case needsSetup
    /// The setup is finished: virtual machines can start from the image.
    case ready
    /// The download or the install failed.
    case failed
}

/// `<data dir>/VirtualMachines/Images/<IMAGE-ID>/image.yml`: one macOS image of virtual machines
/// (docs/data-model.md › Image metadata file). The engine API sends the same object with two keys
/// that are never stored, `progress` and `diskBytes` (docs/engine-api.md › VMImage in the API).
public struct VMImage: Codable, Sendable, Hashable, Identifiable {
    public var schema: Int
    /// The image's id; it equals the name of the image's folder.
    public var id: UUID
    /// The macOS version, for example `27.2.1`.
    public var version: String
    /// The macOS build, for example `26B131`.
    public var build: String
    /// Processor cores of the image's virtual machines.
    public var cores: Int
    /// Their memory in GB, 1024³ bytes each.
    public var memoryGB: Int
    /// The size of the image's disk in GB.
    public var diskGB: Int
    public var state: VMImageState
    /// The message of a failed image; nil in the other states.
    public var failure: String?
    /// When `vmImages.add` created the image.
    public var created: Date
    /// Never stored: the fraction done, 0 to 1, of the download or of the install; nil in the other
    /// states.
    public var progress: Double?
    /// Never stored: the space the files of the image's folder take on disk, in bytes.
    public var diskBytes: Int
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: UUID, version: String, build: String, cores: Int, memoryGB: Int, diskGB: Int,
                state: VMImageState, failure: String? = nil, created: Date, progress: Double? = nil, diskBytes: Int = 0,
                unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.version = version
        self.build = build
        self.cores = cores
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.state = state
        self.failure = failure
        self.created = created
        self.progress = progress
        self.diskBytes = diskBytes
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "id", "version", "build", "cores", "memoryGB", "diskGB", "state", "failure",
                                         "created", "progress", "diskBytes"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        version = try c.required("version")
        build = try c.required("build")
        cores = try c.required("cores")
        memoryGB = try c.required("memoryGB")
        diskGB = try c.required("diskGB")
        let rawState: String = try c.required("state")
        guard let state = VMImageState(rawValue: rawState) else {
            throw c.invalid("state", "\"\(rawState)\" is not one of \(VMImageState.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self.state = state
        failure = try c.optional("failure")
        created = try c.requiredDate("created")
        // The runtime-only keys are ignored in a file (docs/data-model.md › Image metadata file).
        progress = c.isYAML ? nil : try c.optional("progress")
        diskBytes = c.isYAML ? 0 : try c.value("diskBytes", default: 0)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(version, "version")
        try c.encode(build, "build")
        try c.encode(cores, "cores")
        try c.encode(memoryGB, "memoryGB")
        try c.encode(diskGB, "diskGB")
        try c.encode(state.rawValue, "state")
        try c.encodeOptional(failure, "failure")
        try c.encodeDate(created, "created")
        if !c.isYAML {
            if let progress {
                try c.encode(progress, "progress")
            }
            try c.encode(diskBytes, "diskBytes")
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The percentage of the download or of the install, rounded down, 0 to 100; 0 without
    /// `progress` (docs/virtual-machines.md › Image states).
    public var percentage: Int {
        guard let progress, progress.isFinite else { return 0 }
        return min(100, max(0, Int((progress * 100).rounded(.down))))
    }

    /// The image as its file holds it: without the keys that are never stored.
    public var stored: VMImage {
        var image = self
        image.progress = nil
        image.diskBytes = 0
        return image
    }
}

/// The ranges that `vmImages.add` accepts for the values of an image on a Mac
/// (docs/virtual-machines.md › Adding an image).
public struct VMImageLimits: Sendable, Hashable {
    public var cores: ClosedRange<Int>
    public var memoryGB: ClosedRange<Int>
    public var diskGB: ClosedRange<Int>

    /// The values of the Add Image sheet when it opens.
    public static let defaultCores = 2
    public static let defaultMemoryGB = 4
    public static let defaultDiskGB = 64
    /// The bytes of one GB of `memoryGB` and `diskGB`.
    public static let bytesPerGB: UInt64 = 1024 * 1024 * 1024

    public init(cores: ClosedRange<Int>, memoryGB: ClosedRange<Int>, diskGB: ClosedRange<Int>) {
        self.cores = cores
        self.memoryGB = memoryGB
        self.diskGB = diskGB
    }

    /// The ranges of a Mac with `processorCount` cores and `physicalMemory` bytes of memory: 2 to
    /// its cores, 4 to its memory in GB, rounded down, 32 to 2048 GB of disk.
    public init(processorCount: Int, physicalMemory: UInt64) {
        cores = 2...max(2, processorCount)
        memoryGB = 4...max(4, Int(physicalMemory / Self.bytesPerGB))
        diskGB = 32...2048
    }

    /// The ranges of this Mac.
    public static var host: VMImageLimits {
        VMImageLimits(processorCount: ProcessInfo.processInfo.processorCount, physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// The message of a value outside the range of its param: `<param>: use a number from <min> to <max>.`
    public static func message(_ param: String, _ range: ClosedRange<Int>) -> String {
        ValidationError.invalid(param, "use a number from \(range.lowerBound) to \(range.upperBound)").message
    }

    /// Throws the `invalid` of the first value outside its range, in the order cores, memoryGB,
    /// diskGB; a virtual machine, whose disk is its image's, gives no `diskGB`.
    public func check(cores: Int, memoryGB: Int, diskGB: Int? = nil) throws {
        var values = [("cores", cores, self.cores), ("memoryGB", memoryGB, self.memoryGB)]
        if let diskGB {
            values.append(("diskGB", diskGB, self.diskGB))
        }
        for (param, value, range) in values where !range.contains(value) {
            throw ValidationError.invalid(param, "use a number from \(range.lowerBound) to \(range.upperBound)")
        }
    }
}
