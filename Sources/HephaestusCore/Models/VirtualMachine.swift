import Foundation

/// The state of a virtual machine (docs/virtual-machines.md › Virtual machine states).
public enum VirtualMachineState: String, Codable, Sendable, Hashable, CaseIterable {
    /// The virtual machine has started and has not stopped yet.
    case running
    /// The virtual machine does not run.
    case stopped
}

/// Who started a virtual machine, which decides what becomes of it when it stops
/// (docs/virtual-machines.md › Lifecycle).
public enum VMStarter: Sendable, Hashable {
    /// The user: the virtual machine keeps its disk when it stops.
    case user
    /// Claude, in a chat of a project: the virtual machine is deleted when it stops.
    case claude(projectID: ProjectID, chatID: ChatID)

    /// The value of the key `startedBy`.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case user, claude
    }

    public var kind: Kind {
        switch self {
        case .user: return .user
        case .claude: return .claude
        }
    }
}

/// `<data dir>/VirtualMachines/Machines/<VM-ID>/vm.yml`: one virtual machine (docs/data-model.md ›
/// VM metadata file). The engine API sends the same object with two keys that are never stored,
/// `state` and `startedAt` (docs/engine-api.md › VirtualMachine in the API).
public struct VirtualMachine: Codable, Sendable, Hashable, Identifiable {
    public var schema: Int
    /// The virtual machine's id; it equals the name of its folder.
    public var id: UUID
    /// The name the user gave it.
    public var name: String
    /// The image it was created from.
    public var imageID: UUID
    /// The macOS version of that image, for example `27.2.1`.
    public var version: String
    /// The macOS build of that image, for example `26B131`.
    public var build: String
    public var cores: Int
    /// Its memory in GB, 1024³ bytes each.
    public var memoryGB: Int
    /// The size of its disk in GB, chosen when it was created; nil for a virtual machine of an
    /// earlier version, whose disk has the size of its image's.
    public var diskGB: Int?
    /// True while the guest's APFS container has not yet grown over the disk grown at the creation
    /// (docs/virtual-machines.md › Starting).
    public var growContainer: Bool
    /// The keys `startedBy`, `projectID` and `chatID`.
    public var startedBy: VMStarter
    /// When the virtual machine was created.
    public var created: Date
    /// Never stored: a virtual machine read from its file is stopped.
    public var state: VirtualMachineState
    /// Never stored: when the running virtual machine started; nil for a stopped one.
    public var startedAt: Date?
    public var unknownKeys: [String: JSONValue]

    public init(schema: Int = 1, id: UUID, name: String, imageID: UUID, version: String, build: String, cores: Int, memoryGB: Int,
                diskGB: Int? = nil, growContainer: Bool = false, startedBy: VMStarter = .user, created: Date, state: VirtualMachineState = .stopped, startedAt: Date? = nil,
                unknownKeys: [String: JSONValue] = [:]) {
        self.schema = schema
        self.id = id
        self.name = name
        self.imageID = imageID
        self.version = version
        self.build = build
        self.cores = cores
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.growContainer = growContainer
        self.startedBy = startedBy
        self.created = created
        self.state = state
        self.startedAt = startedAt
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "id", "name", "imageID", "version", "build", "cores", "memoryGB", "diskGB", "growContainer", "startedBy",
                                         "projectID", "chatID", "created", "state", "startedAt"]

    public init(from decoder: Decoder) throws {
        let c = try ModelDecodingContainer(decoder)
        schema = try c.schema()
        id = try c.required("id")
        name = try c.required("name")
        imageID = try c.required("imageID")
        version = try c.required("version")
        build = try c.required("build")
        cores = try c.required("cores")
        memoryGB = try c.required("memoryGB")
        diskGB = try c.optional("diskGB")
        growContainer = try c.value("growContainer", default: false)
        let rawStarter: String = try c.required("startedBy")
        switch VMStarter.Kind(rawValue: rawStarter) {
        case .user:
            startedBy = .user
        case .claude:
            // Required for a virtual machine that Claude started.
            startedBy = .claude(projectID: try c.required("projectID"), chatID: try c.required("chatID"))
        case nil:
            throw c.invalid("startedBy", "\"\(rawStarter)\" is not one of \(VMStarter.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        created = try c.requiredDate("created")
        // The runtime-only keys are ignored in a file (docs/data-model.md › VM metadata file).
        if c.isYAML {
            state = .stopped
            startedAt = nil
        } else {
            let rawState = try c.value("state", default: VirtualMachineState.stopped.rawValue)
            guard let state = VirtualMachineState(rawValue: rawState) else {
                throw c.invalid("state", "\"\(rawState)\" is not one of \(VirtualMachineState.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            self.state = state
            startedAt = try c.optionalDate("startedAt")
        }
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = ModelEncodingContainer(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encode(imageID, "imageID")
        try c.encode(version, "version")
        try c.encode(build, "build")
        try c.encode(cores, "cores")
        try c.encode(memoryGB, "memoryGB")
        try c.encodeOptional(diskGB, "diskGB")
        try c.encode(growContainer, "growContainer")
        try c.encode(startedBy.kind.rawValue, "startedBy")
        switch startedBy {
        case .user:
            try c.encodeOptional(String?.none, "projectID")
            try c.encodeOptional(String?.none, "chatID")
        case .claude(let projectID, let chatID):
            try c.encode(projectID, "projectID")
            try c.encode(chatID, "chatID")
        }
        try c.encodeDate(created, "created")
        if !c.isYAML {
            try c.encode(state.rawValue, "state")
            if let startedAt {
                try c.encodeDate(startedAt, "startedAt")
            }
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The virtual machine as its file holds it: without the keys that are never stored.
    public var stored: VirtualMachine {
        var machine = self
        machine.state = .stopped
        machine.startedAt = nil
        return machine
    }

    /// Whether the virtual machine is deleted when it stops: one that Claude started.
    public var isDeletedWhenStopped: Bool {
        startedBy.kind == .claude
    }

    /// The rule of `name`: one line of 1 to 100 characters, trimmed
    /// (docs/virtual-machines.md › Creating).
    public static func checkedName(_ value: String) throws -> String {
        try ModelRules.singleLine(value, field: "name", length: 1...100, error: .invalid("name", "use 1 to 100 characters on one line"))
    }
}

/// The text of a running time (docs/virtual-machines.md › Virtual machine states): whole minutes,
/// rounded down, `<m> min` under an hour and `<h> h <mm> min` from an hour on.
public enum VMRunningTime {
    /// `0 min`, `12 min`, `59 min`, `1 h 00 min`, `1 h 05 min`, `26 h 40 min`.
    public static func text(seconds: TimeInterval) -> String {
        let minutes = seconds.isFinite ? Int(max(0, seconds) / 60) : 0
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return "\(minutes / 60) h \(rest < 10 ? "0" : "")\(rest) min"
    }

    /// The running time of a virtual machine that started at `start`, at `now`.
    public static func text(since start: Date, now: Date) -> String {
        text(seconds: now.timeIntervalSince(start))
    }
}
