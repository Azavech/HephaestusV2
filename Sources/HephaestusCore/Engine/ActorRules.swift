import Foundation

/// The parameter-level rules that depend on the actor (docs/engine-api.md › Rules for Claude),
/// with their messages. The dispatcher checks only the actor kind of each method; these rules are
/// checked by the handlers (docs/engine-api.md › Dispatcher), which call these functions. A
/// `system` actor passes every rule.
enum ActorRules {
    /// tickets.create: `title` must be absent for claude.
    static func requireNoTicketTitle(_ title: String?, _ actor: Actor) throws {
        guard actor.kind == .claude, title != nil else { return }
        throw EngineError(.forbidden, "Claude cannot set a ticket title; Haiku names the ticket.")
    }

    /// projects.update: `chatDefaults` must be absent for claude (`null` is present).
    static func requireNoChatDefaults(_ chatDefaults: Patch<ChatSettings>, _ actor: Actor) throws {
        guard actor.kind == .claude, chatDefaults.isPresent else { return }
        throw EngineError(.forbidden, "Claude cannot change chat defaults.")
    }

    /// chats.implementTicket, chats.implementBundle: `settings` must be absent for claude.
    static func requireNoChatSettings(_ settings: ChatSettings?, _ actor: Actor) throws {
        guard actor.kind == .claude, settings != nil else { return }
        throw EngineError(.forbidden, "Claude cannot choose chat settings.")
    }

    /// webTabs.update: `locked` false is refused for claude.
    static func requireNoUnlock(_ locked: Bool?, _ actor: Actor) throws {
        guard actor.kind == .claude, locked == false else { return }
        throw EngineError(.forbidden, "Only the user can unlock a tab.")
    }

    /// Every AttachmentUpload: `sourcePath` is accepted from claude and system only.
    static func requireNoSourcePath(_ uploads: [AttachmentUpload]?, _ actor: Actor) throws {
        guard actor.kind == .user, (uploads ?? []).contains(where: { $0.sourcePath != nil }) else { return }
        throw EngineError(.forbidden, "sourcePath is accepted from Claude only.")
    }

    /// chats.postQuestions and the other requests to the user: only the chat's own Claude; the
    /// external token is refused.
    static func requireOwnChat(_ chatID: ChatID, _ actor: Actor) throws {
        guard actor.kind != .system else { return }
        guard actor.chat == chatID else {
            throw ownChatOnly
        }
    }

    /// The message of chats.postQuestions and of `ask_questions` with the external token.
    static let ownChatOnly = EngineError(.forbidden, "Only the chat's own Claude can ask questions.")

    /// chats.postQuestions and the other requests to the user: refused while the chat's metadata
    /// holds `questionsBlocked`, in an implement chat the user has not written in yet
    /// (docs/workflow.md › Implement chats). Checked after `requireOwnChat`; a chat that does not
    /// exist passes, and fails later with `notFound`.
    static func requireQuestionsAllowed(_ chat: ChatMeta?, _ actor: Actor) throws {
        guard actor.kind != .system, chat?.questionsBlocked == true else { return }
        throw questionsBlocked
    }

    /// The message of chats.postQuestions and the other requests in an implement chat.
    static let questionsBlocked = EngineError(
        .forbidden, "This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.")

    /// The message of chats.close and of `close_chat` with the external token.
    static let ownChatCloseOnly = EngineError(.forbidden, "Only the chat's own Claude can close its chat.")

    /// chats.close: a chat other than the actor's own must belong to the project of the actor's
    /// chat (docs/engine-api.md › chats.close).
    static func otherProjectChat(_ chatID: ChatID) -> EngineError {
        EngineError(.forbidden, "Chat \(chatID.uuidString) belongs to another project.")
    }

    /// chats.close: a chat other than the actor's own must have no turn in progress
    /// (docs/engine-api.md › chats.close).
    static func turnInProgress(_ chatID: ChatID) -> EngineError {
        EngineError(.conflict, "Chat \(chatID.uuidString) has a turn in progress.")
    }

    /// tickets.setStatus: claude never changes the status of a `done` ticket.
    static func requireNotDoneTicket(_ ticket: Ticket, _ actor: Actor) throws {
        guard actor.kind == .claude, ticket.status == .done else { return }
        throw EngineError(.forbidden, "\(ticket.id) is done; only the user can change its status.")
    }

    /// bundles.setStatus: claude never changes the status of a `done` bundle and never sets
    /// `done` (docs/tickets.md › Bundle status rules).
    static func requireBundleStatusChange(_ bundle: TicketBundle, to status: BundleStatus, _ actor: Actor) throws {
        guard actor.kind == .claude else { return }
        if bundle.status == .done {
            throw EngineError(.forbidden, "\(bundle.id) is done; only the user can change its status.")
        }
        if status == .done {
            throw EngineError(.forbidden, "Only the user can set \(bundle.id) to done.")
        }
    }

    /// projects.remove: the project of the calling chat, or one of its ancestors, is refused.
    static let ownProjectRemoval = EngineError(.forbidden, "A chat cannot remove the project it belongs to.")
}
