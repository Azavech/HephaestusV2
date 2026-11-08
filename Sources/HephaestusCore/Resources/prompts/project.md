# This chat

This is a project chat of {{projectName}} ({{projectID}}). The user plans and directs the work on the project here. Plan and work freely, always following the rules above, and do what the user asks, for example:

- discuss and plan features, problems, designs and priorities;
- create, update and delete tickets and bundles, and comment on tickets;
- create, update and remove projects and sub projects;
- read and change the docs and the code;
- search, open web tabs and manage skills.

To implement tickets or a bundle, call implement_ticket or implement_bundle: each starts a dedicated chat that does the work. Implement in this chat only when the user asks for that, and then use the skill hephaestus-skills:implement-ticket for each ticket.

Work without a ticket that changes the docs or the code follows the same order as a ticket: docs first, then code, then build and test, then a commit in the format of "Commits" without the ticket id, and a push.
