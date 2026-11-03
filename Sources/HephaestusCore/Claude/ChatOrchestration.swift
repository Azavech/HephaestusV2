import Foundation

/// What a turn of a chat tells its orchestrator chat when it ends (docs/chats.md › Orchestrated
/// ticket chats).
struct TurnReport {
    /// The text of the turn's last assistant item without `parentToolUseID`.
    var reply: String?
    /// The user stopped the turn with Stop.
    var stopped = false
    /// The text of the turn's last error item, else the summary of its last error result.
    var errorText: String?
    var resultError: String?

    mutating func record(_ item: ChatItem) {
        switch item {
        case .assistant(let assistant) where assistant.parentToolUseID == nil:
            reply = assistant.text
        case .system(let system) where system.level == .error:
            errorText = system.text
        case .result(let result):
            if result.isError, result.summary == Engine.stoppedSummary {
                stopped = true
            } else if result.isError {
                resultError = result.summary ?? ""
            } else {
                resultError = nil
            }
        default:
            break
        }
    }

    /// The message to the orchestrator for a turn of the chat of `ticketID` that ended in
    /// `state` (`idle` or `error`).
    func message(ticketID: TicketID, state: ChatState) -> String {
        if stopped { return "Chat of \(ticketID) was stopped." }
        if state == .error || resultError != nil {
            return "Chat of \(ticketID) ended in error: \(errorText ?? resultError ?? "")"
        }
        return "Chat of \(ticketID) finished its turn:\n\n\(reply ?? "")"
    }
}

extension Engine {
    /// The chat states of a turn.
    static let turnStates: Set<ChatState> = [.starting, .running, .waitingPermission]

    /// Records the state reported by `chat.updated`. A turn that starts clears the turn's report;
    /// a change from a state already reported can post a notification (docs/chats.md ›
    /// Notifications); a turn of a chat with an orchestrator that ends in `idle` or `error` sends
    /// the report to the orchestrator chat (docs/chats.md › Orchestrated ticket chats).
    func recordReportedState(_ meta: ChatMeta) {
        let previous = chats.reportedStates[meta.id]
        chats.reportedStates[meta.id] = meta.state
        chats.reportedBackgroundWork[meta.id] = meta.backgroundWork
        let wasInTurn = previous.map { Engine.turnStates.contains($0) } ?? false
        let startsTurn = !wasInTurn && Engine.turnStates.contains(meta.state)
        if startsTurn {
            chats.runtimes[meta.id]?.turnReport = TurnReport()
        }
        if let previous {
            postChatNotification(meta, previous: previous)
        }
        if startsTurn { return }
        guard wasInTurn, meta.state == .idle || meta.state == .error, let orchestratorID = meta.orchestratorChatID,
              let ticketID = meta.ticketID
        else { return }
        let report = chats.runtimes[meta.id]?.turnReport ?? TurnReport()
        let text = report.message(ticketID: ticketID, state: meta.state)
        Task { self.sendOrchestratorReport(text, to: orchestratorID, from: meta.id) }
    }

    /// Sends a ticket chat's report to its orchestrator as the `system` actor; skipped while the
    /// engine stops or when the orchestrator chat is gone.
    func sendOrchestratorReport(_ text: String, to orchestratorID: ChatID, from chatID: ChatID) {
        guard !chats.stopped, !domain.isStopped, !chats.deleting.contains(orchestratorID), domain.chat(orchestratorID) != nil else {
            log.info(.claude, "chat \(chatID.uuidString): the report to the orchestrator chat \(orchestratorID.uuidString) was not sent")
            return
        }
        do {
            try sendChatMessage(orchestratorID, text: text, attachments: [], sender: senderName(.system), origin: .system)
        } catch {
            log.error(.claude, "chat \(chatID.uuidString): the report to the orchestrator chat \(orchestratorID.uuidString) failed: \(error)")
        }
    }
}
