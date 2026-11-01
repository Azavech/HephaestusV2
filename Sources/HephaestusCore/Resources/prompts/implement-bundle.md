Implement bundle {{bundleID}}: {{bundleTitle}}

Its tickets, in this order: {{bundleTicketIDs}}.

Follow "Implementing a bundle" as its orchestrator: take the tickets in this order, skip those that are done, and start one ticket chat per ticket with implement_ticket, one at a time, waiting for each chat to report back before you start the next. The ticket chats commit without pushing. When a ticket chat ends in error or is stopped, ask whether to retry, skip or stop. After the last ticket, push once. End with a reply that lists each ticket with its commit hash, or with skipped and the reason.
