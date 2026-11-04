import Foundation

// Ticket links (docs/tickets.md › Ticket links, › Link rules; docs/engine-api.md › Tickets): a
// link is stored only in the declaring ticket's file, and every Ticket that leaves the engine
// carries the inverse links that the engine computes from the other tickets of its project.

extension Engine {
    /// The API form of a ticket: the `answer` of its comments, and its `inverseLinks`, from the
    /// `links` of the other loaded tickets of its project, in ascending ticket number of the
    /// declaring ticket.
    func apiTicket(_ ticket: Ticket) -> Ticket {
        var copy = ticket
        // The answer state of each comment (docs/engine-api.md › Tickets).
        for index in copy.comments.indices {
            copy.comments[index].answer = commentAnswers.states[copy.comments[index].id]
        }
        copy.inverseLinks = []
        guard let projectID = ticket.projectID else { return copy }
        for other in domain.tickets(of: projectID) where other.id != ticket.id {
            for link in other.links where link.ticketID == ticket.id {
                copy.inverseLinks.append(TicketInverseLink(kind: link.kind.inverse, ticketID: other.id))
            }
        }
        return copy
    }

    /// The API form of each ticket.
    func apiTickets(_ tickets: [Ticket]) -> [Ticket] {
        tickets.map(apiTicket)
    }

    /// Emits `ticket.updated` with the API form of a ticket.
    func emitTicketUpdated(_ ticket: Ticket, origin: Actor) {
        emit(TicketUpdatedEvent.self, apiTicket(ticket), origin: origin)
    }

    /// After the declared links of `ticketID` changed from `old` to `new`, emits `ticket.updated`
    /// for each other loaded ticket whose `inverseLinks` changed, in ascending ticket number. Their
    /// files are not written.
    func emitInverseLinkChanges(of ticketID: TicketID, old: [TicketLink], new: [TicketLink], origin: Actor) {
        let targets = Set(old.map(\.ticketID)).union(new.map(\.ticketID))
        let changed = targets.filter { target in
            target != ticketID
                && old.filter { $0.ticketID == target }.map(\.kind) != new.filter { $0.ticketID == target }.map(\.kind)
        }
        for target in changed.sorted(by: { DomainState.number(of: $0) < DomainState.number(of: $1) }) {
            guard let ticket = domain.ticket(target) else { continue }
            emitTicketUpdated(ticket, origin: origin)
        }
    }

    /// The `links` given to tickets.create or tickets.update, ids uppercased, checked by
    /// docs/tickets.md › Link rules. A link that the ticket already declares in `declared`, with
    /// the same kind, is kept without checks. `ticketID` is nil for a ticket being created, which
    /// has no id yet and to which no ticket links.
    func checkedLinks(_ given: [TicketLink], ticketID: TicketID?, projectID: ProjectID,
                      declared: [TicketLink]) throws -> [TicketLink] {
        var result: [TicketLink] = []
        for link in given {
            // 1. The ticket format.
            let other = try normalizedTicketID(link.ticketID)
            var checked = link
            checked.ticketID = other
            result.append(checked)
            if declared.contains(where: { $0.kind == link.kind && $0.ticketID == other }) {
                continue
            }
            // 2. The same project.
            guard Identifiers.projectID(of: other) == projectID else {
                throw EngineError(.invalid, "\(other) does not belong to project \(projectID).")
            }
            // 3. Not the ticket itself.
            if let ticketID, other == ticketID {
                throw EngineError(.invalid, "\(ticketID) cannot be linked to itself.")
            }
            // 4. Named once.
            guard given.filter({ $0.ticketID.uppercased() == other }).count == 1 else {
                throw EngineError(.invalid, "\(other) is listed more than once.")
            }
            // 5. An existing ticket.
            let target = try existingTicket(other)
            guard let ticketID else { continue }
            // 6. One link per pair of tickets.
            if target.links.contains(where: { $0.ticketID == ticketID }) {
                throw EngineError(.invalid, "\(ticketID) is already linked to \(other).")
            }
            // 7. No Depends on cycle.
            if link.kind == .dependsOn, dependsOn(other, reaching: ticketID) {
                throw EngineError(.invalid, "\(ticketID) cannot depend on \(other), which depends on \(ticketID).")
            }
        }
        return result
    }

    /// Whether `start` depends on `goal`, directly or through other tickets, by the Depends on
    /// links of the loaded tickets.
    private func dependsOn(_ start: TicketID, reaching goal: TicketID) -> Bool {
        var visited: Set<TicketID> = [start]
        var pending = [start]
        while let current = pending.popLast() {
            for link in domain.ticket(current)?.links ?? [] where link.kind == .dependsOn {
                if link.ticketID == goal { return true }
                if visited.insert(link.ticketID).inserted {
                    pending.append(link.ticketID)
                }
            }
        }
        return false
    }

    /// tickets.delete step 2: removes every link to `ticketID` from the other loaded tickets of
    /// its project, writing each file and emitting `ticket.updated`. A failed write stops the
    /// change and is thrown.
    func removeLinks(to ticketID: TicketID, projectID: ProjectID, origin: Actor) throws {
        for var ticket in domain.tickets(of: projectID) where ticket.id != ticketID && ticket.links.contains(where: { $0.ticketID == ticketID }) {
            ticket.links.removeAll { $0.ticketID == ticketID }
            ticket.updated = ISODate.now()
            try saveTicket(ticket)
            emitTicketUpdated(ticket, origin: origin)
        }
    }
}
