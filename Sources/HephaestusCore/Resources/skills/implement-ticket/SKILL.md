---
name: implement-ticket
description: Implements a ticket of HephaestusV2 from start to end, with the docs first, then the code, the build and the tests, the commit, the push, the completion comment, CI and the status. Use it whenever you implement a ticket, in any chat. Its arguments are the ticket id, then the bundle id when a bundle chat started this chat.
---

# Implement a ticket

Arguments: $ARGUMENTS

The first argument is the id of the ticket to implement. A second argument, when there is one, is the id of the bundle whose bundle chat started this chat: then also follow "Ticket chat started by a bundle chat" below.

When this chat is an implement chat, as "Never invent" defines it, ask no question until the user writes in it, except the question about a failed CI that "Waiting for CI" of hephaestus-skills:finish-implementation describes. When something the ticket needs is unknown, make the choice yourself, mark it with the sentence "Default chosen at design time." in the docs you change, and list each choice under Notes of the completion comment; at the other points where the rules tell you to ask, decide yourself and state the decision under Notes too.

## Steps

Follow these steps in this order. Steps 7 and 8 follow the skill hephaestus-skills:finish-implementation: call it when you reach step 7.

1. Set the ticket to in_progress with set_ticket_status.
2. Read the ticket with get_ticket: its description, comments and attachments; view image attachments by reading the absolute paths that get_ticket gives. Read every docs section listed under Docs, the docs index (the README.md of the docs folder, when there is one) and the code involved. When anything is unknown, ask with ask_questions, end your turn, and continue when the answers arrive; in an implement chat, until the user writes in it, make the choice yourself instead, as "Never invent" says.
3. Change the docs first. Change every affected docs section so that it describes the behaviour after the change completely, following the conventions of that docs folder. When the docs already describe the expected behaviour (a defect where the code differs from the docs), leave them unchanged and say so in the completion comment. When the project has no docs folder, ask whether to create one, recommending <docs folder>/<topic>.md; in an implement chat, until the user writes in it, decide yourself and state the decision under Notes of the completion comment.
4. Then change the code until it does what the docs say. Where the project has tests, add or update tests for the changed behaviour.
5. Build and test. Run the repository's own commands with your shell tool: the Makefile targets build and test when they exist, otherwise swift build and swift test for a Swift package, or go build ./... and go test ./... for a Go module. When a command fails, fix the cause and run it again. Never commit while the build or the tests fail; when a failure also happens without your change, ask whether to commit anyway; in an implement chat, until the user writes in it, decide yourself and state the decision under Notes of the completion comment. When no build or test command exists, skip this step and say so in the completion comment. Do not run the project itself (the Makefile target run, swift run or go run) unless the user asks for it.
6. Commit with a message of the form "<type>: <summary> (<TICKET-ID>)", then push, as "Commits" and "Pushing" describe.
7. Post the completion comment that "Completion comment" of hephaestus-skills:finish-implementation describes, with add_comment. In a project with a GitHub page, in a ticket or bundle chat, then call watch_ci and wait for CI, as its "Waiting for CI" describes.
8. Set the ticket to done or review with set_ticket_status, as "Ticket status" describes. In a project with a GitHub page, in a ticket or bundle chat, do it only once "Waiting for CI" lets you finish. Then close the CI chats you started, as "Closing chats" describes.
9. End with a short final reply: what changed, the commit, the checks, the result of each test, and, for a ticket in review, that it waits for the user to set it to Done.

In a project whose type is Go service, the implement chat of a single ticket (started by Implement, or by implement_ticket from a chat that is not a bundle chat) gives each Claude line of its completion comment the result waiting for the test service in step 7, then follows "When the project is a Go service" of hephaestus-skills:finish-implementation, whose step 6 replaces step 8, before its final reply.

## Ticket chat started by a bundle chat

With a bundle id as second argument, the chat of that bundle started this chat: you implement this ticket for that bundle chat, its orchestrator, while the chats of its other tickets work at the same time, each on its own branch in its own git worktree.

- Work in the git worktree and on the branch that the first paragraph of your system prompt names. Follow the steps above completely, except that you commit on your branch without pushing: the bundle chat merges your branch and pushes once at the end. The first line of your completion comment ends with " (not pushed: the bundle chat pushes at the end)".
- A ticket that needs no change, because a commit of the bundle already on your branch covers it, gets no commit; its completion comment names that commit.
- In a Go service project, do not run the Claude tests of your ticket: each Claude line of your completion comment reads waiting for the test service, and you set the ticket to review. The bundle chat runs them on the test service after its push.
- In a project with a GitHub page, set your ticket to review even when every test has passed: the bundle chat sets it after CI.
- HephaestusV2 sends your final reply to the bundle chat.
