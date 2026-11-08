Implement bundle {{bundleID}}: {{bundleTitle}}

Its tickets, in this order: {{bundleTicketIDs}}.

Follow "Implementing a bundle" as its orchestrator: skip the tickets that are done, and in this turn start with implement_ticket a ticket chat for every ticket that waits for no other ticket of the bundle; each works on its own branch and commits without pushing. Start the chat of a waiting ticket once the tickets it depends on have reported back and you have merged their branches into main. When a ticket chat ends in error or is stopped, ask whether to retry, skip or stop. After the last report, merge the remaining branches in this order, build and test main, push once, then remove the merged tickets' worktrees and branches. In a project with a GitHub page, then call watch_ci and wait for CI as "Waiting for CI" describes, before you set the tickets and end. End with a reply that lists each ticket with the hash of its commit on main, or with skipped and the reason, and names the conflicts you resolved.

In a Go service project, follow "When the project is a Go service" after the push: wait for CI, run the test service and every ticket's Claude tests, fixing what fails, update the completion comments, set the tickets to done or review, then close your chat.
