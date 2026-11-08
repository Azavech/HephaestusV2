---
name: implement-bundle
description: Implements a bundle of HephaestusV2 tickets as its orchestrator, which starts a ticket chat per ticket, merges their branches, pushes once, follows CI and sets the tickets. Use it whenever you implement a bundle, in any chat. Its argument is the bundle id.
---

# Implement a bundle

Argument: $ARGUMENTS, the id of the bundle to implement.

A bundle groups tickets that are implemented together, in the order of its tickets. The bundle chat that implements a bundle is its orchestrator: it starts the ticket chats of its tickets, which run at the same time, each on its own branch in its own git worktree, and it merges their branches into the project root's current branch, called main below.

HephaestusV2 gives a ticket chat its own branch and worktree only when the chat of the ticket's bundle starts it. In any other chat, call implement_bundle, which starts the bundle chat, or, when the user asks you to implement the bundle in that chat, implement its tickets one after the other with the skill hephaestus-skills:implement-ticket.

When you implement a bundle in its bundle chat, you are the orchestrator, not an implement chat: ask the user where the points below say so. The bundle and its tickets are in your system prompt; call get_bundle and get_ticket for their current state.

- Skip the tickets whose status is done. A ticket waits for the tickets of this bundle that it declares a Depends on link to and that are not done; Related links and tickets outside the bundle never make it wait. Do not implement the tickets yourself, except the fix of a failed CI run after Fix and check again ("Waiting for CI" of hephaestus-skills:finish-implementation) and the fixes of its "When the project is a Go service" in a Go service project.
- Call implement_ticket for every ticket that waits for nothing, all in the same turn, then end your turn. For each one, HephaestusV2 creates the branch <bundle id>/<ticket id> from main, checked out in its own git worktree (git worktree list shows it), and starts a ticket chat linked to this chat, whose first message calls hephaestus-skills:implement-ticket with the ticket id and the bundle id: it implements the ticket there and commits on its branch without pushing. When implement_ticket fails, ask the user with ask_questions whether to retry the ticket, skip it or stop the bundle.
- When a ticket chat's turn ends, HephaestusV2 sends you one of these messages: "Chat of <TICKET-ID> finished its turn:" followed by that chat's final reply, "Chat of <TICKET-ID> ended in error: <error message>", or "Chat of <TICKET-ID> was stopped.". A ticket chat is an implement chat: it asks no questions until the user writes in it, and it asks its permission prompts in its own chat, where the user answers them; you receive nothing while it waits for answers.
- Merge a branch into main by rebasing it onto main in its worktree (git -C <worktree> rebase <main>), then fast-forwarding main to it in the project root (git merge --ff-only <branch>), so that main holds one commit per ticket. When the rebase conflicts, resolve the conflict yourself, then build and test.
- When every ticket that a waiting ticket depends on has reported back, merge their branches into main, then call implement_ticket for the waiting ticket: its branch starts from main.
- When a ticket chat ended in error or was stopped, ask the user with ask_questions whether to retry the ticket, skip it or stop the bundle; the other ticket chats keep running.
- To retry, call implement_ticket again: the new chat starts on a fresh branch from main.
- When the user decides to skip a ticket, set it back to todo and say why in a comment on it. Skip every ticket of the bundle that depends on it too: set it back to todo with a comment that names the skipped ticket.
- When the user decides to stop, start no other ticket chat and let the running ones finish; merge nothing, do not push, keep every branch and worktree, and close none of the chats you started: a stopped bundle is not done.
- Never set a ticket to done, except after CI as "Waiting for CI" of hephaestus-skills:finish-implementation describes, and in step 6 of its "When the project is a Go service" in a Go service project.
- After every ticket has reported back or been skipped, merge the branches not merged yet, in bundle order. Then build and test main once, as step 5 of hephaestus-skills:implement-ticket describes. When the build or the tests fail, do not push and ask the user with ask_questions how to proceed. Otherwise push once, as "Pushing" describes, so that the bundle starts a single CI run; when the project has no remote, do not push. Then remove the worktree and the branch of each merged ticket (git worktree remove <worktree>, then git branch -d <branch>), and keep those of skipped tickets.
- The rebase changes the commit hashes: with update_comment, change the first line of each ticket's completion comment so that it names the hash of the ticket's commit on main.
- In a project with a GitHub page, then follow "Waiting for CI" of hephaestus-skills:finish-implementation for the merged tickets; in a Go service project, then follow its "When the project is a Go service" for them.
- Your task is then done: close the ticket chats and CI chats you started, then your own chat, as "Closing chats" describes.
- Your final reply lists each ticket with the hash of its commit on main, or with skipped and the reason, and names the conflicts you resolved and the chats that close_chat did not close.
