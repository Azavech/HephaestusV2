import Foundation

/// The detail of a chat notification when there is no summary (docs/chats.md › Title and detail).
enum NotificationDetail {
    /// The fallback detail is cut to this many characters.
    static let fallbackLimit = 200

    /// The first line of Claude's last reply of the turn that is not empty after trimming, trimmed
    /// and cut to 200 characters; without reply text, the status line text of the state, or
    /// `Claude finished replying` for a finished turn.
    static func fallback(reply: String?, kind: ChatNotificationEvent.Payload.Kind, state: ChatState) -> String {
        let line = reply?.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let line {
            return String(line.prefix(fallbackLimit)).trimmingCharacters(in: .whitespaces)
        }
        switch kind {
        case .finished: return "Claude finished replying"
        case .needsYou: return state == .waitingPermission ? "Waiting for your permission" : "Waiting for your answers"
        }
    }
}

extension Engine {
    /// The states of a chat that needs the user.
    static let needsYouStates: Set<ChatState> = [.waitingPermission, .waitingAnswers]

    /// docs/chats.md › Notifications: a chat whose reported state changes from `previous` to
    /// `waitingPermission` or `waitingAnswers` posts "needs you"; a turn that ends in `idle` posts
    /// "finished", except a stopped turn, a turn of an orchestrated ticket chat and a turn of a
    /// bundle chat while one of its ticket chats is working.
    func postChatNotification(_ meta: ChatMeta, previous: ChatState) {
        guard !hasStopped, !chats.stopped, !chats.deleting.contains(meta.id), meta.state != previous else { return }
        if Engine.needsYouStates.contains(meta.state) {
            emitChatNotification(.needsYou, meta)
        } else if meta.state == .idle, Engine.turnStates.contains(previous), postsFinished(meta) {
            emitChatNotification(.finished, meta)
        }
    }

    /// Whether the turn of the chat that just ended in `idle` posts "finished".
    private func postsFinished(_ meta: ChatMeta) -> Bool {
        if chats.runtimes[meta.id]?.turnReport.stopped == true { return false }
        if meta.orchestratorChatID != nil { return false }
        if meta.kind == .bundle {
            let working = domain.chats(of: meta.projectID).contains { chat in
                chat.orchestratorChatID == meta.id
                    && (Engine.turnStates.contains(chats.state(of: chat.id)) || chats.backgroundWork(of: chat.id))
            }
            if working { return false }
        }
        return true
    }

    /// What the summary call of the event summarizes; nil when there is nothing to summarize.
    private func notificationSubject(_ kind: ChatNotificationEvent.Payload.Kind, _ meta: ChatMeta,
                                     reply: String?) -> NotificationSubject? {
        switch kind {
        case .finished:
            guard let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .reply(reply)
        case .needsYou:
            if meta.state == .waitingPermission, let process = chats.runtimes[meta.id]?.process,
               let requestID = process.permissionOrder.first, let request = process.permissions[requestID] {
                return .permission(toolName: request.item.toolName, input: request.item.input)
            }
            if let set = chats.openQuestionSets[meta.id] { return .questions(set.questions) }
            if let symbol = chats.openSymbolRequests[meta.id] { return .symbol(question: symbol.question) }
            return nil
        }
    }

    /// docs/chats.md › Notification events: `chat.notification` at once with the fallback
    /// detail, then again when the summary call ends, unless a newer event of the chat was
    /// emitted, the chat was deleted, the engine stops, or a "needs you" chat no longer waits.
    private func emitChatNotification(_ kind: ChatNotificationEvent.Payload.Kind, _ meta: ChatMeta) {
        let reply = chats.runtimes[meta.id]?.turnReport.reply
        let fallback = NotificationDetail.fallback(reply: reply, kind: kind, state: meta.state)
        chats.notificationCount += 1
        let number = chats.notificationCount
        chats.latestNotifications[meta.id] = number
        emit(ChatNotificationEvent.self, .init(chatID: meta.id, projectID: meta.projectID, kind: kind, stage: .immediate, detail: fallback),
             origin: .system)
        guard let subject = notificationSubject(kind, meta, reply: reply) else {
            finishChatNotification(number, chatID: meta.id, kind: kind, detail: fallback)
            return
        }
        let summarizer = notificationSummarizer
        let chatID = meta.id
        Task {
            let summary = await summarizer.summary(for: subject)
            await self.finishChatNotification(number, chatID: chatID, kind: kind, detail: summary ?? fallback)
        }
    }

    /// The `summary` stage of the notification `number` of the chat.
    func finishChatNotification(_ number: Int, chatID: ChatID, kind: ChatNotificationEvent.Payload.Kind, detail: String) {
        guard !hasStopped, !chats.stopped, chats.latestNotifications[chatID] == number, !chats.deleting.contains(chatID),
              let meta = chatMeta(chatID)
        else { return }
        if kind == .needsYou, !Engine.needsYouStates.contains(meta.state) { return }
        emit(ChatNotificationEvent.self, .init(chatID: chatID, projectID: meta.projectID, kind: kind, stage: .summary, detail: detail),
             origin: .system)
    }
}
