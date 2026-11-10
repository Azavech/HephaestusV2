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
/// (docs/data-model.md › Image metadata file). The engine API sends the same object with three keys
/// that are never stored, `progress`, `diskBytes` and `diskGB` (docs/engine-api.md › VMImage in the
/// API). An image has no values of its virtual machines: the `cores` and `memoryGB` of earlier
/// versions are kept as unknown keys, and their `diskGB` is ignored.
public struct VMImage: Codable, Sendable, Hashable, Identifiable {
    public var schema: Int
    /// The image's id; it equals the name of the image's folder.
    public var id: UUID
    /// The macOS version, for example `27.2.1`.
    public var version: String
    /// The macOS build, for example `26B131`.
    public var build: String
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
    /// Never stored: the size of the image's disk in GB, rounded up; 0 while it has none
    /// (docs/virtual-machines.md › Images).
    public var diskGB: Int
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: UUID, version: String, build: String, state: VMImageState, failure: String? = nil,
                created: Date, progress: Double? = nil, diskBytes: Int = 0, diskGB: Int = 0, unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.version = version
        self.build = build
        self.state = state
        self.failure = failure
        self.created = created
        self.progress = progress
        self.diskBytes = diskBytes
        self.diskGB = diskGB
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "id", "version", "build", "state", "failure", "created", "progress",
                                         "diskBytes", "diskGB"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        version = try c.required("version")
        build = try c.required("build")
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
        diskGB = c.isYAML ? 0 : try c.value("diskGB", default: 0)
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(version, "version")
        try c.encode(build, "build")
        try c.encode(state.rawValue, "state")
        try c.encodeOptional(failure, "failure")
        try c.encodeDate(created, "created")
        if !c.isYAML {
            if let progress {
                try c.encode(progress, "progress")
            }
            try c.encode(diskBytes, "diskBytes")
            try c.encode(diskGB, "diskGB")
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
        image.diskGB = 0
        return image
    }
}

/// The ranges of the values of a virtual machine on a Mac: its cores, its memory and its disk size,
/// and those of the default values of Settings (docs/virtual-machines.md › Default values,
/// › Creating).
public struct VMImageLimits: Sendable, Hashable {
    public var cores: ClosedRange<Int>
    public var memoryGB: ClosedRange<Int>
    /// The range of `defaultVMDiskGB`; a virtual machine's disk goes from its image's disk size to
    /// the same end (`diskGB(imageDiskGB:)`).
    public var diskGB: ClosedRange<Int>

    /// The size of the disk of a new image, in GB (docs/virtual-machines.md › Images).
    public static let imageDiskGB = 32
    /// The largest disk of a virtual machine, in GB.
    public static let maximumDiskGB = 2048
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
        diskGB = Self.imageDiskGB...Self.maximumDiskGB
    }

    /// The ranges of this Mac.
    public static var host: VMImageLimits {
        VMImageLimits(processorCount: ProcessInfo.processInfo.processorCount, physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// The message of a value outside the range of its param: `<param>: use a number from <min> to <max>.`
    public static func message(_ param: String, _ range: ClosedRange<Int>) -> String {
        ValidationError.invalid(param, "use a number from \(range.lowerBound) to \(range.upperBound)").message
    }

    /// The range of the disk of a virtual machine of an image whose disk has `imageDiskGB` GB:
    /// from that size to 2048.
    public func diskGB(imageDiskGB: Int) -> ClosedRange<Int> {
        let lower = max(1, imageDiskGB)
        return lower...max(lower, diskGB.upperBound)
    }

    /// Throws the `invalid` of the first value outside its range, in the order cores, memoryGB,
    /// diskGB; the disk goes from `imageDiskGB` to 2048.
    public func check(cores: Int, memoryGB: Int, diskGB: Int, imageDiskGB: Int) throws {
        let values = [("cores", cores, self.cores), ("memoryGB", memoryGB, self.memoryGB),
                      ("diskGB", diskGB, self.diskGB(imageDiskGB: imageDiskGB))]
        for (param, value, range) in values where !range.contains(value) {
            throw ValidationError.invalid(param, "use a number from \(range.lowerBound) to \(range.upperBound)")
        }
    }

    /// `value` brought to the nearest end of `range`.
    public static func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// The size in GB of a disk of `bytes` bytes, rounded up.
    public static func gigabytes(ofBytes bytes: UInt64) -> Int {
        Int((bytes + bytesPerGB - 1) / bytesPerGB)
    }
}
