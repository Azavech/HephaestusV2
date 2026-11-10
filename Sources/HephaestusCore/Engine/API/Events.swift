import Foundation

// One `EngineEvent` type per event of docs/engine-api.md › Event list, with the payload types of
// docs/engine-api.md › Event payloads. Payloads that are objects of the event list are nested
// `Payload` structs.

/// `projects.changed`: the complete `projects.list` result.
public enum ProjectsChangedEvent: EngineEvent {
    public static let name = "projects.changed"
    public typealias Payload = [ProjectSummary]
}

/// `project.updated`: a project's project.yml was written or reloaded.
public enum ProjectUpdatedEvent: EngineEvent {
    public static let name = "project.updated"
    public typealias Payload = ProjectDetail
}

/// `project.removed`: a project was unregistered or its project.yml disappeared.
public enum ProjectRemovedEvent: EngineEvent {
    public static let name = "project.removed"
    public struct Payload: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
}

/// `ticket.updated`: a ticket was created, changed or reloaded.
public enum TicketUpdatedEvent: EngineEvent {
    public static let name = "ticket.updated"
    public typealias Payload = Ticket
}

/// `ticket.deleted`: a ticket was deleted or its file disappeared.
public enum TicketDeletedEvent: EngineEvent {
    public static let name = "ticket.deleted"
    public struct Payload: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var ticketID: TicketID

        public init(projectID: ProjectID, ticketID: TicketID) {
            self.projectID = projectID
            self.ticketID = ticketID
        }
    }
}

/// `bundle.updated`: a bundle was created, changed or reloaded.
public enum BundleUpdatedEvent: EngineEvent {
    public static let name = "bundle.updated"
    public typealias Payload = TicketBundle
}

/// `bundle.deleted`: a bundle was deleted or its file disappeared.
public enum BundleDeletedEvent: EngineEvent {
    public static let name = "bundle.deleted"
    public struct Payload: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var bundleID: BundleID

        public init(projectID: ProjectID, bundleID: BundleID) {
            self.projectID = projectID
            self.bundleID = bundleID
        }
    }
}

/// `chat.updated`: a chat was created, or its metadata or state changed. The ChatMeta carries
/// `projectID` and `state`.
public enum ChatUpdatedEvent: EngineEvent {
    public static let name = "chat.updated"
    public typealias Payload = ChatMeta
}

/// `chat.deleted`: a chat was deleted.
public enum ChatDeletedEvent: EngineEvent {
    public static let name = "chat.deleted"
    public struct Payload: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        public var chatID: ChatID

        public init(projectID: ProjectID, chatID: ChatID) {
            self.projectID = projectID
            self.chatID = chatID
        }
    }
}

/// `chat.item`: a transcript item was added, or replaced (same `id`).
public enum ChatItemEvent: EngineEvent {
    public static let name = "chat.item"
    public struct Payload: Codable, Sendable, Hashable {
        public var chatID: ChatID
        /// The complete item; it replaces a received item with the same `id`, otherwise it is
        /// appended.
        public var item: ChatItem

        public init(chatID: ChatID, item: ChatItem) {
            self.chatID = chatID
            self.item = item
        }
    }
}

/// `chat.agents`: a chat's workflows or agents changed (docs/chats.md › Agents).
public enum ChatAgentsEvent: EngineEvent {
    public static let name = "chat.agents"
    public typealias Payload = ChatAgents
}

/// `chat.agentItem`: an item was added to the transcript of one of a chat's agents.
public enum ChatAgentItemEvent: EngineEvent {
    public static let name = "chat.agentItem"
    public struct Payload: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var agentID: String
        /// The complete item; it replaces a received item of the agent with the same `id`,
        /// otherwise it is appended.
        public var item: ChatItem

        public init(chatID: ChatID, agentID: String, item: ChatItem) {
            self.chatID = chatID
            self.agentID = agentID
            self.item = item
        }
    }
}

/// `chat.delta`: Claude streams text, thinking or tool input. Not persisted.
public enum ChatDeltaEvent: EngineEvent {
    public static let name = "chat.delta"
    public struct Payload: Codable, Sendable, Hashable {
        /// What the delta appends to.
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
            case text, thinking, toolInput

            public init(from decoder: Decoder) throws {
                self = try APIEnumCoding.decode(decoder)
            }
        }

        public var chatID: ChatID
        /// Id of the item being streamed; the chat.item that completes it carries the same id.
        public var itemID: String
        public var kind: Kind
        /// Text to append: to the item's text for `text` and `thinking`, to the raw JSON of the
        /// tool input for `toolInput`.
        public var append: String
        /// For kind `text`: the CLI model id of the streamed message; nil for the other kinds and
        /// for a message without model.
        public var model: String?
        /// For kind `text`: the chat's effort when the text was read; nil when `model` is nil or
        /// has no effort setting.
        public var effort: Effort?

        public init(chatID: ChatID, itemID: String, kind: Kind, append: String, model: String? = nil, effort: Effort? = nil) {
            self.chatID = chatID
            self.itemID = itemID
            self.kind = kind
            self.append = append
            self.model = model
            self.effort = effort
        }
    }
}

/// `files.changed`: files changed under a project root.
public enum FilesChangedEvent: EngineEvent {
    public static let name = "files.changed"
    public struct Payload: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// Project paths that changed; a directory path means anything below it; `[""]` means
        /// the whole project.
        public var paths: [String]

        public init(projectID: ProjectID, paths: [String]) {
            self.projectID = projectID
            self.paths = paths
        }
    }
}

/// `webTabs.updated`: a project's web tabs changed.
public enum WebTabsUpdatedEvent: EngineEvent {
    public static let name = "webTabs.updated"
    public struct Payload: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// All tabs of the project in tab order.
        public var tabs: [WebTab]

        public init(projectID: ProjectID, tabs: [WebTab]) {
            self.projectID = projectID
            self.tabs = tabs
        }
    }
}

/// `skills.changed`: the complete `skills.list` result.
public enum SkillsChangedEvent: EngineEvent {
    public static let name = "skills.changed"
    public typealias Payload = [SkillSummary]
}

/// `memories.changed`: the complete `memories.list` result of one project, whose memory folder
/// changed (docs/memories.md › Live updates).
public enum MemoriesChangedEvent: EngineEvent {
    public static let name = "memories.changed"
    public typealias Payload = MemoryFolder
}

/// `vmImages.changed`: the complete `vmImages.list` result (docs/virtual-machines.md › Image states).
public enum VMImagesChangedEvent: EngineEvent {
    public static let name = "vmImages.changed"
    public typealias Payload = [VMImage]
}

/// `vms.changed`: the complete `vms.list` result (docs/virtual-machines.md › Lifecycle, › Running
/// virtual machines).
public enum VMsChangedEvent: EngineEvent {
    public static let name = "vms.changed"
    public typealias Payload = VMList
}

/// `settings.updated`: host settings changed.
public enum SettingsUpdatedEvent: EngineEvent {
    public static let name = "settings.updated"
    public typealias Payload = HostSettings
}

/// `claude.updated`: the Claude CLI status or the model list changed.
public enum ClaudeUpdatedEvent: EngineEvent {
    public static let name = "claude.updated"
    public struct Payload: Codable, Sendable, Hashable {
        public var status: ClaudeStatus
        /// Current `claude.models` result.
        public var models: [ClaudeModel]

        public init(status: ClaudeStatus, models: [ClaudeModel]) {
            self.status = status
            self.models = models
        }
    }
}

/// `planUsage.updated`: the engine's plan usage was replaced (docs/engine-api.md › Plan usage).
public enum PlanUsageUpdatedEvent: EngineEvent {
    public static let name = "planUsage.updated"
    public typealias Payload = PlanUsage
}

/// `ui.open`: `ui.open` was called.
public enum UIOpenEvent: EngineEvent {
    public static let name = "ui.open"
    public struct Payload: Codable, Sendable, Hashable {
        public var target: NavigationTarget
        /// Device that shows it; absent for every client.
        public var deviceID: String?

        public init(target: NavigationTarget, deviceID: String? = nil) {
            self.target = target
            self.deviceID = deviceID
        }
    }
}

/// `chat.notification`: a chat needs the user or a turn finished (docs/chats.md › Notifications).
/// Emitted once at once (`immediate`, the fallback detail), then once after the summary call
/// (`summary`, Haiku's summary or the fallback detail).
public enum ChatNotificationEvent: EngineEvent {
    public static let name = "chat.notification"
    public struct Payload: Codable, Sendable, Hashable {
        /// The event of the chat.
        public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
            /// The chat entered `waitingPermission` or `waitingAnswers`.
            case needsYou
            /// A turn ended in `idle`.
            case finished

            public init(from decoder: Decoder) throws {
                self = try APIEnumCoding.decode(decoder)
            }
        }

        /// When the event is emitted.
        public enum Stage: String, Codable, Sendable, Hashable, CaseIterable {
            /// At the event, with the fallback detail.
            case immediate
            /// When the summary call ends, with Haiku's summary or the fallback detail.
            case summary

            public init(from decoder: Decoder) throws {
                self = try APIEnumCoding.decode(decoder)
            }
        }

        public var chatID: ChatID
        public var projectID: ProjectID
        public var kind: Kind
        public var stage: Stage
        /// The notification's body.
        public var detail: String

        public init(chatID: ChatID, projectID: ProjectID, kind: Kind, stage: Stage, detail: String) {
            self.chatID = chatID
            self.projectID = projectID
            self.kind = kind
            self.stage = stage
            self.detail = detail
        }
    }
}

/// Every event type of docs/engine-api.md › Event list, in the order of the list.
public enum EngineEvents {
    public static let all: [any EngineEvent.Type] = [
        ProjectsChangedEvent.self, ProjectUpdatedEvent.self, ProjectRemovedEvent.self,
        TicketUpdatedEvent.self, TicketDeletedEvent.self, BundleUpdatedEvent.self, BundleDeletedEvent.self,
        ChatUpdatedEvent.self, ChatDeletedEvent.self, ChatItemEvent.self, ChatDeltaEvent.self,
        ChatAgentsEvent.self, ChatAgentItemEvent.self, FilesChangedEvent.self, WebTabsUpdatedEvent.self, SkillsChangedEvent.self,
        MemoriesChangedEvent.self, VMImagesChangedEvent.self, VMsChangedEvent.self,
        SettingsUpdatedEvent.self, ClaudeUpdatedEvent.self, PlanUsageUpdatedEvent.self, UIOpenEvent.self,
        ChatNotificationEvent.self,
    ]
}

/// An event envelope decoded by its name, for clients that switch over the events they receive.
/// An event with an unknown name is `unknown`: clients ignore it (docs/remote.md › Unknown
/// messages).
public enum DecodedEngineEvent: Sendable, Hashable {
    case projectsChanged([ProjectSummary])
    case projectUpdated(ProjectDetail)
    case projectRemoved(ProjectRemovedEvent.Payload)
    case ticketUpdated(Ticket)
    case ticketDeleted(TicketDeletedEvent.Payload)
    case bundleUpdated(TicketBundle)
    case bundleDeleted(BundleDeletedEvent.Payload)
    case chatUpdated(ChatMeta)
    case chatDeleted(ChatDeletedEvent.Payload)
    case chatItem(ChatItemEvent.Payload)
    case chatDelta(ChatDeltaEvent.Payload)
    case chatAgents(ChatAgents)
    case chatAgentItem(ChatAgentItemEvent.Payload)
    case filesChanged(FilesChangedEvent.Payload)
    case webTabsUpdated(WebTabsUpdatedEvent.Payload)
    case skillsChanged([SkillSummary])
    case memoriesChanged(MemoryFolder)
    case vmImagesChanged([VMImage])
    case vmsChanged(VMList)
    case settingsUpdated(HostSettings)
    case claudeUpdated(ClaudeUpdatedEvent.Payload)
    case planUsageUpdated(PlanUsage)
    case uiOpen(UIOpenEvent.Payload)
    case chatNotification(ChatNotificationEvent.Payload)
    case unknown(name: String)
}

extension EngineEventEnvelope {
    /// The payload decoded by the event's name. Throws EngineError `invalid` when the payload does
    /// not decode as the payload of its event.
    public func decoded() throws -> DecodedEngineEvent {
        switch name {
        case ProjectsChangedEvent.name: return .projectsChanged(try payload(ProjectsChangedEvent.self))
        case ProjectUpdatedEvent.name: return .projectUpdated(try payload(ProjectUpdatedEvent.self))
        case ProjectRemovedEvent.name: return .projectRemoved(try payload(ProjectRemovedEvent.self))
        case TicketUpdatedEvent.name: return .ticketUpdated(try payload(TicketUpdatedEvent.self))
        case TicketDeletedEvent.name: return .ticketDeleted(try payload(TicketDeletedEvent.self))
        case BundleUpdatedEvent.name: return .bundleUpdated(try payload(BundleUpdatedEvent.self))
        case BundleDeletedEvent.name: return .bundleDeleted(try payload(BundleDeletedEvent.self))
        case ChatUpdatedEvent.name: return .chatUpdated(try payload(ChatUpdatedEvent.self))
        case ChatDeletedEvent.name: return .chatDeleted(try payload(ChatDeletedEvent.self))
        case ChatItemEvent.name: return .chatItem(try payload(ChatItemEvent.self))
        case ChatDeltaEvent.name: return .chatDelta(try payload(ChatDeltaEvent.self))
        case ChatAgentsEvent.name: return .chatAgents(try payload(ChatAgentsEvent.self))
        case ChatAgentItemEvent.name: return .chatAgentItem(try payload(ChatAgentItemEvent.self))
        case FilesChangedEvent.name: return .filesChanged(try payload(FilesChangedEvent.self))
        case WebTabsUpdatedEvent.name: return .webTabsUpdated(try payload(WebTabsUpdatedEvent.self))
        case SkillsChangedEvent.name: return .skillsChanged(try payload(SkillsChangedEvent.self))
        case MemoriesChangedEvent.name: return .memoriesChanged(try payload(MemoriesChangedEvent.self))
        case VMImagesChangedEvent.name: return .vmImagesChanged(try payload(VMImagesChangedEvent.self))
        case VMsChangedEvent.name: return .vmsChanged(try payload(VMsChangedEvent.self))
        case SettingsUpdatedEvent.name: return .settingsUpdated(try payload(SettingsUpdatedEvent.self))
        case ClaudeUpdatedEvent.name: return .claudeUpdated(try payload(ClaudeUpdatedEvent.self))
        case PlanUsageUpdatedEvent.name: return .planUsageUpdated(try payload(PlanUsageUpdatedEvent.self))
        case UIOpenEvent.name: return .uiOpen(try payload(UIOpenEvent.self))
        case ChatNotificationEvent.name: return .chatNotification(try payload(ChatNotificationEvent.self))
        default: return .unknown(name: name)
        }
    }
}
