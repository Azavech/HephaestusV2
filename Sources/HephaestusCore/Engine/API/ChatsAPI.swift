import Foundation

// docs/engine-api.md › Chats. Every ChatMeta in a result carries `projectID` and `state`
// (docs/engine-api.md › Chat metadata in the API).

/// `chats.list`: every chat of the project, sorted by `updated` descending. Actors: user, claude.
public enum ChatsList: EngineMethod {
    public static let name = "chats.list"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [ChatMeta]
}

/// `chats.get`: the metadata and every transcript item. Actors: user, claude.
public enum ChatsGet: EngineMethod {
    public static let name = "chats.get"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID

        public init(chatID: ChatID) {
            self.chatID = chatID
        }
    }
    public typealias Result = ChatTranscript
}

/// `chats.create`. Actors: user.
public enum ChatsCreate: EngineMethod {
    public static let name = "chats.create"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// `project`, `ticket` or `bundle`; feedback chats come from `chats.createFeedback`.
        public var kind: ChatKind
        /// Required for kind ticket and refused for another kind.
        public var ticketID: TicketID?
        /// Required for kind bundle and refused for another kind.
        public var bundleID: BundleID?
        /// Default: the project's `chatDefaults`, else the host `defaultChatSettings`.
        public var settings: ChatSettings?
        /// First message, sent as by `chats.send`.
        public var message: ChatMessageInput?

        public init(projectID: ProjectID, kind: ChatKind, ticketID: TicketID? = nil, bundleID: BundleID? = nil,
                    settings: ChatSettings? = nil, message: ChatMessageInput? = nil) {
            self.projectID = projectID
            self.kind = kind
            self.ticketID = ticketID
            self.bundleID = bundleID
            self.settings = settings
            self.message = message
        }
    }
    public typealias Result = ChatMeta
}

/// `chats.send`. Actors: user. Removes `questionsBlocked` from an implement chat
/// (docs/engine-api.md › chats.send).
public enum ChatsSend: EngineMethod {
    public static let name = "chats.send"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var message: ChatMessageInput

        public init(chatID: ChatID, message: ChatMessageInput) {
            self.chatID = chatID
            self.message = message
        }
    }
    public typealias Result = Empty
}

/// `chats.interrupt`: the stop sequence of a running turn. Actors: user.
public enum ChatsInterrupt: EngineMethod {
    public static let name = "chats.interrupt"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID

        public init(chatID: ChatID) {
            self.chatID = chatID
        }
    }
    public typealias Result = Empty
}

/// `chats.updateSettings`. Actors: user.
public enum ChatsUpdateSettings: EngineMethod {
    public static let name = "chats.updateSettings"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        /// Complete settings replacing the chat's.
        public var settings: ChatSettings

        public init(chatID: ChatID, settings: ChatSettings) {
            self.chatID = chatID
            self.settings = settings
        }
    }
    public typealias Result = ChatMeta
}

/// `chats.rename`. Actors: user, claude.
public enum ChatsRename: EngineMethod {
    public static let name = "chats.rename"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        /// New title, trimmed, 1 to 100 characters on one line.
        public var title: String

        public init(chatID: ChatID, title: String) {
            self.chatID = chatID
            self.title = title
        }
    }
    public typealias Result = ChatMeta
}

/// `chats.delete`. Actors: user.
public enum ChatsDelete: EngineMethod {
    public static let name = "chats.delete"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID

        public init(chatID: ChatID) {
            self.chatID = chatID
        }
    }
    public typealias Result = Empty
}

/// `chats.close`: closes a chat when its turn ends, or at once without a turn in progress; Claude
/// closes another chat of its project at once (docs/chats.md › Closing a chat). Actors: user, any
/// chat; claude with a chat token, its own chat or another chat of its project.
public enum ChatsClose: EngineMethod {
    public static let name = "chats.close"
    public struct Params: Codable, Sendable, Hashable {
        /// For a claude actor, the actor's chat or another chat of its project.
        public var chatID: ChatID

        public init(chatID: ChatID) {
            self.chatID = chatID
        }
    }
    public typealias Result = Empty
}

/// `chats.reopen`: clears the closed state of a chat. Actors: user.
public enum ChatsReopen: EngineMethod {
    public static let name = "chats.reopen"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID

        public init(chatID: ChatID) {
            self.chatID = chatID
        }
    }
    public typealias Result = ChatMeta
}

/// `chats.answerPermission`. Actors: user.
public enum ChatsAnswerPermission: EngineMethod {
    public static let name = "chats.answerPermission"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        /// `requestID` of a `permissionRequest` item of the chat.
        public var requestID: String
        public var decision: PermissionDecision
        /// Sent to Claude with a `deny`; ignored with `allow` and `allowAlways`.
        public var message: String?

        public init(chatID: ChatID, requestID: String, decision: PermissionDecision, message: String? = nil) {
            self.chatID = chatID
            self.requestID = requestID
            self.decision = decision
            self.message = message
        }
    }
    public typealias Result = Empty
}

/// `chats.postQuestions`: called by the MCP tool `ask_questions`. Actors: claude (the chat's own
/// Claude only), refused while the chat's metadata holds `questionsBlocked`.
public enum ChatsPostQuestions: EngineMethod {
    public static let name = "chats.postQuestions"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// 1–26 questions labelled `A`, `B`, `C` and so on, in order.
        public var questions: [Question]

        public init(chatID: ChatID, questions: [Question]) {
            self.chatID = chatID
            self.questions = questions
        }
    }
    public typealias Result = QuestionSet
}

/// `chats.answerQuestion`. Actors: user.
public enum ChatsAnswerQuestion: EngineMethod {
    public static let name = "chats.answerQuestion"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var questionSetID: UUID
        /// Label of the first unanswered question of the set.
        public var label: String
        /// The chosen option's label or free text; trimmed; not empty.
        public var answer: String

        public init(chatID: ChatID, questionSetID: UUID, label: String, answer: String) {
            self.chatID = chatID
            self.questionSetID = questionSetID
            self.label = label
            self.answer = answer
        }
    }
    public typealias Result = Empty
}

/// `chats.postSymbol`: called by the MCP tool `ask_symbol`. Actors: claude (the chat's own Claude
/// only), refused while the chat's metadata holds `questionsBlocked`.
public enum ChatsPostSymbol: EngineMethod {
    public static let name = "chats.postSymbol"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Markdown text, not empty after trimming.
        public var question: String
        /// 2 to 10 distinct SF Symbol names of the main device's catalogue.
        public var suggestions: [String]
        /// One of the suggestions.
        public var recommended: String

        public init(chatID: ChatID, question: String, suggestions: [String], recommended: String) {
            self.chatID = chatID
            self.question = question
            self.suggestions = suggestions
            self.recommended = recommended
        }
    }
    public typealias Result = SymbolRequest
}

/// `chats.answerSymbol`. Actors: user.
public enum ChatsAnswerSymbol: EngineMethod {
    public static let name = "chats.answerSymbol"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var requestID: UUID
        /// `![](sf:<name>)` for a chosen symbol, free text, or `Skipped`; trimmed; not empty.
        public var answer: String

        public init(chatID: ChatID, requestID: UUID, answer: String) {
            self.chatID = chatID
            self.requestID = requestID
            self.answer = answer
        }
    }
    public typealias Result = Empty
}

/// `chats.postColor`: called by the MCP tool `ask_color`. Actors: claude (the chat's own Claude
/// only).
public enum ChatsPostColor: EngineMethod {
    public static let name = "chats.postColor"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Markdown text, not empty after trimming.
        public var question: String
        /// 2 to 10 distinct suggestions: colors without `lightAndDark`, pairs with it.
        public var suggestions: [ColorValue]
        /// One of the suggestions.
        public var recommended: ColorValue
        /// true asks for a light and dark pair; absent counts as false.
        public var lightAndDark: Bool?

        public init(chatID: ChatID, question: String, suggestions: [ColorValue], recommended: ColorValue,
                    lightAndDark: Bool? = nil) {
            self.chatID = chatID
            self.question = question
            self.suggestions = suggestions
            self.recommended = recommended
            self.lightAndDark = lightAndDark
        }
    }
    public typealias Result = ColorRequest
}

/// `chats.answerColor`. Actors: user.
public enum ChatsAnswerColor: EngineMethod {
    public static let name = "chats.answerColor"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var requestID: UUID
        /// `![](color:<color>)`, `Light ![](color:<color>), Dark ![](color:<color>)`, free text, or
        /// `Skipped`; trimmed; not empty.
        public var answer: String

        public init(chatID: ChatID, requestID: UUID, answer: String) {
            self.chatID = chatID
            self.requestID = requestID
            self.answer = answer
        }
    }
    public typealias Result = Empty
}

/// `chats.postSound`: called by the MCP tool `ask_sound`. Actors: claude (the chat's own Claude
/// only), in a project of type Swift application.
public enum ChatsPostSound: EngineMethod {
    public static let name = "chats.postSound"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Markdown text, not empty after trimming.
        public var question: String
        /// 2 to 10 distinct names of the sound catalogue of the main device for the chat's project.
        public var suggestions: [String]
        /// One of the suggestions.
        public var recommended: String

        public init(chatID: ChatID, question: String, suggestions: [String], recommended: String) {
            self.chatID = chatID
            self.question = question
            self.suggestions = suggestions
            self.recommended = recommended
        }
    }
    public typealias Result = SoundRequest
}

/// `chats.answerSound`. Actors: user.
public enum ChatsAnswerSound: EngineMethod {
    public static let name = "chats.answerSound"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var requestID: UUID
        /// `![](sound:<name>)` for a chosen sound, free text, or `Skipped`; trimmed; not empty.
        public var answer: String

        public init(chatID: ChatID, requestID: UUID, answer: String) {
            self.chatID = chatID
            self.requestID = requestID
            self.answer = answer
        }
    }
    public typealias Result = Empty
}

/// `chats.postShortcut`: called by the MCP tool `ask_shortcut`. Actors: claude (the chat's own
/// Claude only).
public enum ChatsPostShortcut: EngineMethod {
    public static let name = "chats.postShortcut"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID; the chat's project has the type `swiftApplication`.
        public var chatID: ChatID
        /// Markdown text, not empty after trimming.
        public var question: String
        /// 2 to 10 distinct shortcuts of the shortcut notation.
        public var suggestions: [String]
        /// One of the suggestions.
        public var recommended: String
        /// The app's own shortcuts with their commands; may be empty.
        public var inUse: [ShortcutInUse]

        public init(chatID: ChatID, question: String, suggestions: [String], recommended: String, inUse: [ShortcutInUse]) {
            self.chatID = chatID
            self.question = question
            self.suggestions = suggestions
            self.recommended = recommended
            self.inUse = inUse
        }
    }
    public typealias Result = ShortcutRequest
}

/// `chats.answerShortcut`. Actors: user.
public enum ChatsAnswerShortcut: EngineMethod {
    public static let name = "chats.answerShortcut"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var requestID: UUID
        /// `![](shortcut:<shortcut>)` for a chosen or recorded shortcut, free text, or `Skipped`;
        /// trimmed; not empty.
        public var answer: String

        public init(chatID: ChatID, requestID: UUID, answer: String) {
            self.chatID = chatID
            self.requestID = requestID
            self.answer = answer
        }
    }
    public typealias Result = Empty
}

/// `chats.postFont`: called by the MCP tool `ask_font`. Actors: claude (the chat's own Claude
/// only).
public enum ChatsPostFont: EngineMethod {
    public static let name = "chats.postFont"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Markdown text, not empty after trimming.
        public var question: String
        /// Plain text drawn in the selected font, not empty after trimming.
        public var sample: String
        /// 2 to 10 distinct fonts of the font notation and of the main device's font catalogue.
        public var suggestions: [String]
        /// One of the suggestions.
        public var recommended: String

        public init(chatID: ChatID, question: String, sample: String, suggestions: [String], recommended: String) {
            self.chatID = chatID
            self.question = question
            self.sample = sample
            self.suggestions = suggestions
            self.recommended = recommended
        }
    }
    public typealias Result = FontRequest
}

/// `chats.answerFont`. Actors: user.
public enum ChatsAnswerFont: EngineMethod {
    public static let name = "chats.answerFont"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var requestID: UUID
        /// `![](font:<font>)` for a chosen font, free text, or `Skipped`; trimmed; not empty.
        public var answer: String

        public init(chatID: ChatID, requestID: UUID, answer: String) {
            self.chatID = chatID
            self.requestID = requestID
            self.answer = answer
        }
    }
    public typealias Result = Empty
}

/// `chats.postAnimation`: called by the MCP tool `ask_animation`. Actors: claude (the chat's own
/// Claude only), in a Swift application project.
public enum ChatsPostAnimation: EngineMethod {
    public static let name = "chats.postAnimation"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Markdown text, not empty after trimming.
        public var question: String
        /// 2 to 10 distinct SwiftUI animation expressions.
        public var suggestions: [String]
        /// One of the suggestions.
        public var recommended: String

        public init(chatID: ChatID, question: String, suggestions: [String], recommended: String) {
            self.chatID = chatID
            self.question = question
            self.suggestions = suggestions
            self.recommended = recommended
        }
    }
    public typealias Result = AnimationRequest
}

/// `chats.answerAnimation`. Actors: user.
public enum ChatsAnswerAnimation: EngineMethod {
    public static let name = "chats.answerAnimation"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var requestID: UUID
        /// `![](animation:<expression>)` for a chosen animation, free text, or `Skipped`; trimmed;
        /// not empty.
        public var answer: String

        public init(chatID: ChatID, requestID: UUID, answer: String) {
            self.chatID = chatID
            self.requestID = requestID
            self.answer = answer
        }
    }
    public typealias Result = Empty
}

/// `chats.implementTicket`. Actors: user, claude. The chat it creates has `questionsBlocked` true
/// (docs/engine-api.md › chats.implementTicket).
public enum ChatsImplementTicket: EngineMethod {
    public static let name = "chats.implementTicket"
    public struct Params: Codable, Sendable, Hashable {
        public var ticketID: TicketID
        /// Default: the project's `chatDefaults`, else the host `defaultChatSettings`. Must be
        /// absent for claude.
        public var settings: ChatSettings?

        public init(ticketID: TicketID, settings: ChatSettings? = nil) {
            self.ticketID = ticketID
            self.settings = settings
        }
    }
    public typealias Result = ChatMeta
}

/// `chats.implementBundle`. Actors: user, claude.
public enum ChatsImplementBundle: EngineMethod {
    public static let name = "chats.implementBundle"
    public struct Params: Codable, Sendable, Hashable {
        public var bundleID: BundleID
        /// Default: the project's `chatDefaults`, else the host `defaultChatSettings`. Must be
        /// absent for claude.
        public var settings: ChatSettings?

        public init(bundleID: BundleID, settings: ChatSettings? = nil) {
            self.bundleID = bundleID
            self.settings = settings
        }
    }
    public typealias Result = ChatMeta
}

/// `chats.createFeedback`: called by the feedback sheet. Actors: user.
public enum ChatsCreateFeedback: EngineMethod {
    public static let name = "chats.createFeedback"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID
        /// The user's comment; may be empty.
        public var comment: String
        /// The captured window: contentType `image/png`, content in `dataBase64`.
        public var screenshot: AttachmentUpload
        public var context: FeedbackContext
        public var settings: ChatSettings?

        public init(projectID: ProjectID, comment: String, screenshot: AttachmentUpload, context: FeedbackContext,
                    settings: ChatSettings? = nil) {
            self.projectID = projectID
            self.comment = comment
            self.screenshot = screenshot
            self.context = context
            self.settings = settings
        }
    }
    public typealias Result = ChatMeta
}

/// `chats.listAgents`: the workflows and agents of the project's chats, one entry per chat that
/// has at least one, sorted by chat id (docs/chats.md › Agents). Actors: user.
public enum ChatsListAgents: EngineMethod {
    public static let name = "chats.listAgents"
    public struct Params: Codable, Sendable, Hashable {
        public var projectID: ProjectID

        public init(projectID: ProjectID) {
            self.projectID = projectID
        }
    }
    public typealias Result = [ChatAgents]
}

/// `chats.agentTranscript`: the transcript of one agent of a chat (docs/chats.md › Agent transcript
/// lines, › Sub-agent transcripts). Actors: user.
public enum ChatsAgentTranscript: EngineMethod {
    public static let name = "chats.agentTranscript"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var agentID: String

        public init(chatID: ChatID, agentID: String) {
            self.chatID = chatID
            self.agentID = agentID
        }
    }
    public typealias Result = [ChatItem]
}

/// `chats.stopWorkflow`: writes the `stop_task` request for a running workflow (docs/chats.md ›
/// Stopping a workflow). Actors: user.
public enum ChatsStopWorkflow: EngineMethod {
    public static let name = "chats.stopWorkflow"
    public struct Params: Codable, Sendable, Hashable {
        public var chatID: ChatID
        public var workflowID: String

        public init(chatID: ChatID, workflowID: String) {
            self.chatID = chatID
            self.workflowID = workflowID
        }
    }
    public typealias Result = Empty
}
