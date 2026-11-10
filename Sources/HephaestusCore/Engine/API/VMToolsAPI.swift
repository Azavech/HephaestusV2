import Foundation

// docs/engine-api.md › VM tools: the methods of the VM tools of the MCP server, for the chat's own
// Claude only.

/// An image as `vm_list_images` gives it (docs/engine-api.md › VMToolImage).
public struct VMToolImage: Codable, Sendable, Hashable {
    public var id: UUID
    public var version: String
    public var build: String
    public var state: VMImageState
    /// True for the default image (docs/virtual-machines.md › Default image).
    public var isDefault: Bool
    /// The size of its disk in GB, the smallest disk of its virtual machines; 0 while it has none.
    public var diskGB: Int
    /// The failure of a failed image.
    public var failure: String?

    public init(id: UUID, version: String, build: String, state: VMImageState, isDefault: Bool, diskGB: Int,
                failure: String? = nil) {
        self.id = id
        self.version = version
        self.build = build
        self.state = state
        self.isDefault = isDefault
        self.diskGB = diskGB
        self.failure = failure
    }
}

/// A virtual machine as `vm_list` and `vm_start` give it (docs/engine-api.md › VMToolMachine).
public struct VMToolMachine: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var imageID: UUID
    public var version: String
    public var cores: Int
    public var memoryGB: Int
    /// The text of the Started by column: `You`, or `<project id> · <chat name>`.
    public var startedBy: String
    /// True for a virtual machine that Claude started.
    public var byClaude: Bool
    public var state: VirtualMachineState
    /// The running time of the State column, for example `12 min`; nil for a stopped one.
    public var runningTime: String?
    /// True while the agent is connected and has been given the Claude token.
    public var agentConnected: Bool

    public init(id: UUID, name: String, imageID: UUID, version: String, cores: Int, memoryGB: Int, startedBy: String, byClaude: Bool,
                state: VirtualMachineState, runningTime: String?, agentConnected: Bool) {
        self.id = id
        self.name = name
        self.imageID = imageID
        self.version = version
        self.cores = cores
        self.memoryGB = memoryGB
        self.startedBy = startedBy
        self.byClaude = byClaude
        self.state = state
        self.runningTime = runningTime
        self.agentConnected = agentConnected
    }
}

/// The PNG of `vm_screenshot` (docs/engine-api.md › VMScreenshot).
public struct VMScreenshot: Codable, Sendable, Hashable {
    /// The absolute path of the PNG on this Mac.
    public var path: String
    public var width: Int
    public var height: Int

    public init(path: String, width: Int, height: Int) {
        self.path = path
        self.width = width
        self.height = height
    }
}

/// The result of `vm_shell`, the agent's `exec` (docs/engine-api.md › VMShellResult).
public struct VMShellResult: Codable, Sendable, Hashable {
    public var exitStatus: Int
    public var timedOut: Bool
    public var stdout: String
    public var stderr: String
    public var truncated: Bool

    public init(exitStatus: Int, timedOut: Bool, stdout: String, stderr: String, truncated: Bool) {
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
    }
}

/// The params of the methods without other params than the calling chat.
public struct VMToolChatParams: Codable, Sendable, Hashable {
    public var chatID: ChatID

    public init(chatID: ChatID) {
        self.chatID = chatID
    }
}

/// The params of the methods that act on one virtual machine without other params.
public struct VMToolMachineParams: Codable, Sendable, Hashable {
    public var chatID: ChatID
    public var vmID: UUID

    public init(chatID: ChatID, vmID: UUID) {
        self.chatID = chatID
        self.vmID = vmID
    }
}

/// `vmTools.images`: the images, oldest first. Actors: claude.
public enum VMToolsImages: EngineMethod {
    public static let name = "vmTools.images"
    public typealias Params = VMToolChatParams
    public typealias Result = [VMToolImage]
}

/// `vmTools.list`: the virtual machines, oldest first. Actors: claude.
public enum VMToolsList: EngineMethod {
    public static let name = "vmTools.list"
    public typealias Params = VMToolChatParams
    public typealias Result = [VMToolMachine]
}

/// `vmTools.start`: joins the virtual machine that Claude runs from the image, or starts one for
/// the calling chat (docs/virtual-machines.md › Starting and joining). Actors: claude.
public enum VMToolsStart: EngineMethod {
    public static let name = "vmTools.start"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        /// A macOS version or the id of an image; the default image when nil.
        public var image: String?
        public var name: String
        /// `defaultVMCores` when nil.
        public var cores: Int?
        /// In GB; `defaultVMMemoryGB` when nil.
        public var memory: Int?

        public init(chatID: ChatID, image: String? = nil, name: String, cores: Int? = nil, memory: Int? = nil) {
            self.chatID = chatID
            self.image = image
            self.name = name
            self.cores = cores
            self.memory = memory
        }
    }
    public typealias Result = VMToolMachine
}

/// `vmTools.stop`: stops a virtual machine that Claude started, which is then deleted.
/// Actors: claude.
public enum VMToolsStop: EngineMethod {
    public static let name = "vmTools.stop"
    public typealias Params = VMToolMachineParams
    public typealias Result = Empty
}

/// `vmTools.screenshot`: a PNG of the guest's main display. Actors: claude.
public enum VMToolsScreenshot: EngineMethod {
    public static let name = "vmTools.screenshot"
    public typealias Params = VMToolMachineParams
    public typealias Result = VMScreenshot
}

/// `vmTools.click`. Actors: claude.
public enum VMToolsClick: EngineMethod {
    public static let name = "vmTools.click"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var vmID: UUID
        public var x: Int
        public var y: Int
        /// `left` or `right`; `left` when nil.
        public var button: String?
        /// 1 to 3; 1 when nil.
        public var count: Int?

        public init(chatID: ChatID, vmID: UUID, x: Int, y: Int, button: String? = nil, count: Int? = nil) {
            self.chatID = chatID
            self.vmID = vmID
            self.x = x
            self.y = y
            self.button = button
            self.count = count
        }
    }
    public typealias Result = Empty
}

/// `vmTools.drag`. Actors: claude.
public enum VMToolsDrag: EngineMethod {
    public static let name = "vmTools.drag"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var vmID: UUID
        public var fromX: Int
        public var fromY: Int
        public var toX: Int
        public var toY: Int

        public init(chatID: ChatID, vmID: UUID, fromX: Int, fromY: Int, toX: Int, toY: Int) {
            self.chatID = chatID
            self.vmID = vmID
            self.fromX = fromX
            self.fromY = fromY
            self.toX = toX
            self.toY = toY
        }
    }
    public typealias Result = Empty
}

/// `vmTools.scroll`. Actors: claude.
public enum VMToolsScroll: EngineMethod {
    public static let name = "vmTools.scroll"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var vmID: UUID
        public var x: Int
        public var y: Int
        public var deltaX: Int?
        public var deltaY: Int?

        public init(chatID: ChatID, vmID: UUID, x: Int, y: Int, deltaX: Int? = nil, deltaY: Int? = nil) {
            self.chatID = chatID
            self.vmID = vmID
            self.x = x
            self.y = y
            self.deltaX = deltaX
            self.deltaY = deltaY
        }
    }
    public typealias Result = Empty
}

/// `vmTools.type`. Actors: claude.
public enum VMToolsType: EngineMethod {
    public static let name = "vmTools.type"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var vmID: UUID
        public var text: String

        public init(chatID: ChatID, vmID: UUID, text: String) {
            self.chatID = chatID
            self.vmID = vmID
            self.text = text
        }
    }
    public typealias Result = Empty
}

/// `vmTools.key`: a key in the macOS menu notation. Actors: claude.
public enum VMToolsKey: EngineMethod {
    public static let name = "vmTools.key"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var vmID: UUID
        public var key: String

        public init(chatID: ChatID, vmID: UUID, key: String) {
            self.chatID = chatID
            self.vmID = vmID
            self.key = key
        }
    }
    public typealias Result = Empty
}

/// `vmTools.uiTree`: the agent's `uiTree` result, `{app, bundleID, pid, tree}`. Actors: claude.
public enum VMToolsUITree: EngineMethod {
    public static let name = "vmTools.uiTree"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var vmID: UUID
        public var app: String?
        /// 1 to 100; 40 when nil.
        public var maxDepth: Int?

        public init(chatID: ChatID, vmID: UUID, app: String? = nil, maxDepth: Int? = nil) {
            self.chatID = chatID
            self.vmID = vmID
            self.app = app
            self.maxDepth = maxDepth
        }
    }
    public typealias Result = JSONValue
}

/// `vmTools.shell`: a command run with `/bin/zsh -lc` in the guest. Actors: claude.
public enum VMToolsShell: EngineMethod {
    public static let name = "vmTools.shell"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var vmID: UUID
        public var command: String
        public var asRoot: Bool?
        /// Seconds, 1 to 1800; 60 when nil.
        public var timeout: Int?

        public init(chatID: ChatID, vmID: UUID, command: String, asRoot: Bool? = nil, timeout: Int? = nil) {
            self.chatID = chatID
            self.vmID = vmID
            self.command = command
            self.asRoot = asRoot
            self.timeout = timeout
        }
    }
    public typealias Result = VMShellResult
}

/// The params of `vmTools.copyIn` and `vmTools.copyOut`.
public struct VMToolCopyParams: Codable, Sendable, Hashable {
    public var chatID: ChatID
    public var vmID: UUID
    public var source: String
    public var destination: String

    public init(chatID: ChatID, vmID: UUID, source: String, destination: String) {
        self.chatID = chatID
        self.vmID = vmID
        self.source = source
        self.destination = destination
    }
}

/// `vmTools.copyIn`: a file or a folder of this Mac copied into the guest. Actors: claude.
public enum VMToolsCopyIn: EngineMethod {
    public static let name = "vmTools.copyIn"
    public typealias Params = VMToolCopyParams
    public typealias Result = Empty
}

/// `vmTools.copyOut`: a file or a folder of the guest copied to this Mac. Actors: claude.
public enum VMToolsCopyOut: EngineMethod {
    public static let name = "vmTools.copyOut"
    public typealias Params = VMToolCopyParams
    public typealias Result = Empty
}
