import Foundation

// The `chats` lists of tickets and bundles (parallel-rules › Cross-key contracts; docs/data-model.md
// › Chat kinds, › Changes that touch several files). core-claude writes the chat metadata file
// first, then calls these.

extension Engine {
    /// Appends a chat to the `chats` of a ticket, without duplicates, writes the ticket file and
    /// emits `ticket.updated`. Fails with `notFound` when the ticket is not loaded.
    func linkChat(_ chatID: ChatID, toTicket ticketID: TicketID, origin: Actor = .system) throws {
        var ticket = try existingTicket(ticketID)
        guard !ticket.chatIDs.contains(chatID) else { return }
        ticket.chatIDs.append(chatID)
        ticket.updated = ISODate.now()
        try saveTicket(ticket)
        emit(TicketUpdatedEvent.self, ticket, origin: origin)
    }

    /// Appends a chat to the `chats` of a bundle, without duplicates, writes the bundle file and
    /// emits `bundle.updated`. Fails with `notFound` when the bundle is not loaded.
    func linkChat(_ chatID: ChatID, toBundle bundleID: BundleID, origin: Actor = .system) throws {
        var bundle = try existingBundle(bundleID)
        guard !bundle.chatIDs.contains(chatID) else { return }
        bundle.chatIDs.append(chatID)
        bundle.updated = ISODate.now()
        try saveBundle(bundle)
        emit(BundleUpdatedEvent.self, bundle, origin: origin)
    }

    /// Removes a chat from the `chats` of every loaded ticket and bundle that lists it (its
    /// ticket or bundle, and the ticket a feedback chat created), writing each file and emitting
    /// `ticket.updated` or `bundle.updated`. A write that fails is logged.
    // DOC-GAP: the cross-key contract declares `unlinkChat` without `throws`; a failed write is
    // therefore logged instead of failing the calling `chats.delete`.
    func unlinkChat(_ chatID: ChatID, origin: Actor = .system) {
        for projectID in domain.loadedProjectIDs() {
            for var ticket in domain.tickets(of: projectID) where ticket.chatIDs.contains(chatID) {
                ticket.chatIDs.removeAll { $0 == chatID }
                ticket.updated = ISODate.now()
                do {
                    try saveTicket(ticket)
                    emit(TicketUpdatedEvent.self, ticket, origin: origin)
                } catch {
                    log.error(.storage, "the chat \(chatID.uuidString) cannot be unlinked from \(ticket.id): \(error)")
                }
            }
            for var bundle in domain.bundles(of: projectID) where bundle.chatIDs.contains(chatID) {
                bundle.chatIDs.removeAll { $0 == chatID }
                bundle.updated = ISODate.now()
                do {
                    try saveBundle(bundle)
                    emit(BundleUpdatedEvent.self, bundle, origin: origin)
                } catch {
                    log.error(.storage, "the chat \(chatID.uuidString) cannot be unlinked from \(bundle.id): \(error)")
                }
            }
        }
    }
}
