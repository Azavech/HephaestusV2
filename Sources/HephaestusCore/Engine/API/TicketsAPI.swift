import Foundation

// docs/engine-api.md › Tickets.

/// `tickets.list`: the project's tickets sorted by number. Actors: user, claude.
public enum TicketsList: EngineMethod {
    public static let name = "tickets.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [Ticket]
}

/// `tickets.get`. Actors: user, claude.
public enum TicketsGet: EngineMethod {
    public static let name = "tickets.get"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID

        public init(ticketID: TicketID) {
            self.ticketID = ticketID
        }
    }
    public typealias Result = Ticket
}

/// `tickets.create`. Actors: user, claude.
public enum TicketsCreate: EngineMethod {
    public static let name = "tickets.create"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// When absent or empty after trimming, Haiku names the ticket. Must be absent for claude.
        public var title: String?
        /// Markdown description, not empty after trimming.
        public var description: String
        /// Ticket-level attachments.
        public var attachments: [AttachmentUpload]?

        public init(projectID: ProjectID, title: String? = nil, description: String, attachments: [AttachmentUpload]? = nil) {
            self.projectID = projectID
            self.title = title
            self.description = description
            self.attachments = attachments
        }
    }
    public typealias Result = Ticket
}

/// `tickets.update`. Actors: user, claude.
public enum TicketsUpdate: EngineMethod {
    public static let name = "tickets.update"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        public var title: String?
        public var description: String?

        public init(ticketID: TicketID, title: String? = nil, description: String? = nil) {
            self.ticketID = ticketID
            self.title = title
            self.description = description
        }
    }
    public typealias Result = Ticket
}

/// `tickets.setStatus`. Actors: user, claude.
public enum TicketsSetStatus: EngineMethod {
    public static let name = "tickets.setStatus"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        /// `todo`, `in_progress`, `review` or `done`, decoded as a string and checked by the handler.
        public var status: String

        public init(ticketID: TicketID, status: String) {
            self.ticketID = ticketID
            self.status = status
        }
    }
    public typealias Result = Ticket
}

/// `tickets.delete`. Actors: user, claude.
public enum TicketsDelete: EngineMethod {
    public static let name = "tickets.delete"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID

        public init(ticketID: TicketID) {
            self.ticketID = ticketID
        }
    }
    public typealias Result = Empty
}

/// `tickets.addComment`. Actors: user, claude.
public enum TicketsAddComment: EngineMethod {
    public static let name = "tickets.addComment"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        /// Markdown; may be empty after trimming only with at least one attachment.
        public var text: String
        public var attachments: [AttachmentUpload]?

        public init(ticketID: TicketID, text: String, attachments: [AttachmentUpload]? = nil) {
            self.ticketID = ticketID
            self.text = text
            self.attachments = attachments
        }
    }
    public typealias Result = Ticket
}

/// `tickets.updateComment`. Actors: user, claude.
public enum TicketsUpdateComment: EngineMethod {
    public static let name = "tickets.updateComment"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        public var commentID: UUID
        public var text: String

        public init(ticketID: TicketID, commentID: UUID, text: String) {
            self.ticketID = ticketID
            self.commentID = commentID
            self.text = text
        }
    }
    public typealias Result = Ticket
}

/// `tickets.deleteComment`. Actors: user, claude.
public enum TicketsDeleteComment: EngineMethod {
    public static let name = "tickets.deleteComment"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        public var commentID: UUID

        public init(ticketID: TicketID, commentID: UUID) {
            self.ticketID = ticketID
            self.commentID = commentID
        }
    }
    public typealias Result = Ticket
}

/// `tickets.addAttachments`. Actors: user.
public enum TicketsAddAttachments: EngineMethod {
    public static let name = "tickets.addAttachments"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        /// At least one file; appended to the ticket-level attachments.
        public var attachments: [AttachmentUpload]

        public init(ticketID: TicketID, attachments: [AttachmentUpload]) {
            self.ticketID = ticketID
            self.attachments = attachments
        }
    }
    public typealias Result = Ticket
}

/// `tickets.removeAttachment`. Actors: user, claude.
public enum TicketsRemoveAttachment: EngineMethod {
    public static let name = "tickets.removeAttachment"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        /// Id of a ticket-level attachment.
        public var attachmentID: UUID

        public init(ticketID: TicketID, attachmentID: UUID) {
            self.ticketID = ticketID
            self.attachmentID = attachmentID
        }
    }
    public typealias Result = Ticket
}
