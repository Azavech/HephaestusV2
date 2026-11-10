---
name: finish-implementation
description: Ends the implementation of a HephaestusV2 ticket or bundle after its push, with the completion comment, the wait for CI in a project with a GitHub page and the checks of a Go service on its test service. Use it when the skills implement-ticket and implement-bundle tell you to.
---

# Finish an implementation

These parts end the implementation of a ticket or a bundle, after its commit and its push. The skills hephaestus-skills:implement-ticket and hephaestus-skills:implement-bundle tell you when to follow each of them. "Ticket status", "Commits", "Pushing" and "Closing chats" are rules of your system prompt.

## Completion comment

After the push, or after the step that ended the run, post one comment on the ticket with add_comment, in this form:

<comment>
Implemented in `<short hash>`: <commit subject>

Docs
- <link to each changed docs section>: <what changed>

Code
- <path>: <what changed>

Checks
- <command>: passed

Testing
- Claude: <test>: <result>
- User: <test>: <result>

Notes
- <what is left open, or None>
</comment>

- <short hash> is the output of git rev-parse --short HEAD after the commit.
- Without a commit, the first line is "Not committed: <reason>.", for example "Not committed: the project is not a git repository.". When the commit was not pushed, the first line ends with " (not pushed: <reason>)".
- When the docs already described the behaviour, the Docs part is "- No change: <link> already describes the expected behaviour.".
- When no build or test command exists, the Checks part is "- None: no build or test command found.".
- The Testing part has one line per bullet of the ticket's Testing section, in the same order, with its result: passed, failed, waiting for the user, or waiting for the release for a code-test bullet while no release built by CI contains the commit. You run the check of each Claude line yourself, in a virtual machine when an isolated instance cannot do it, as step 5 of hephaestus-skills:implement-ticket describes. When the ticket has no Testing section, the Testing part is "- None: the ticket has no Testing section.".
- In an implement chat, Notes lists each choice you made yourself because something the ticket needed was unknown, and each decision you took where these rules tell the other chats to ask.
- In a project whose type is Go service, the result of a Claude line is waiting for the test service until the checks on the test service have run; step 5 of "When the project is a Go service" then updates the comment.
- In a project with a GitHub page, post the comment before you call watch_ci. With update_comment, add to its Notes each fix commit of a failed CI run, with its short hash and subject, and, after Finish without green CI, the failed runs.
- Post the comment before you end your turn.

## Waiting for CI

When the project has a GitHub page (get_project gives it as githubPage), the ticket or bundle chat that pushes an implementation is its orchestrator and follows its CI: the implement chat of a single ticket, a ticket chat in which the user asked for the implementation, and the bundle chat after its single push. A ticket chat that a bundle chat started neither pushes nor waits for CI. A project or feedback chat that implements a ticket starts no CI chat, and neither does a chat that pushed no commit (no remote, a push that failed, a folder that is not a git repository) or whose watch_ci call failed: such a chat sets the status as in a project without a GitHub page, and says in the Notes of its completion comment and in its final reply that CI was not followed, and why. In a project without a GitHub page, skip this section.

1. After the push and the completion comment, call watch_ci with the full hash of the pushed commit (git rev-parse HEAD), then end your turn. HephaestusV2 starts a CI chat, which waits with the gh CLI for every workflow run of the commit and ends with a final reply whose first line is "CI passed.", "CI failed." or "CI not checked.". When its turn ends, HephaestusV2 sends you "CI chat finished its turn:" followed by that final reply, "CI chat ended in error: <error message>", or "CI chat was stopped.".
2. Until then your task is not done: set no ticket to done or review and do not close your chat until the CI chat has reported "CI passed." or "CI not checked.", or the user has chosen Finish without green CI.
3. After "CI passed." or "CI not checked.", finish your task. In a ticket chat, set the ticket to done or review as "Ticket status" describes. In a bundle chat, set each merged ticket to done when "Ticket status" allows it, from the test results its ticket chat reported, and leave the others in review. In a Go service project, go on with step 2 of "When the project is a Go service" instead. After "CI not checked.", say in your final reply that CI was not checked.
4. After "CI failed.", an error or a stop, ask the user with ask_questions how to proceed, with the options Fix and check again, Re-run the failed runs and Finish without green CI, recommending the one that fits the cause of the failure. HephaestusV2 accepts this question also in an implement chat in which the user has not written. Then do what the answer says:
   - Fix and check again: fix the cause yourself, also in a bundle chat, build and test, commit the fix as fix: <summary> (<TICKET-ID>) with the id of the ticket whose change caused the failure, push, add the fix commit with its short hash and subject to Notes of that ticket's completion comment with update_comment, and call watch_ci with the new commit.
   - Re-run the failed runs: run gh run rerun <run id> --repo <owner>/<name> --failed for each failed run, <owner>/<name> being the project's GitHub page without https://github.com/, then call watch_ci with the same commit.
   - Finish without green CI: name the failed runs under Notes of each ticket's completion comment with update_comment, set the tickets to review, and end with your final reply. In a Go service project, skip steps 2 to 6 of "When the project is a Go service": the Claude lines keep waiting for the test service.

## When the project is a Go service

When the project's type is Go service, these rules apply too. A Go service has no user interface: its tickets are tested on a test service, a container of the service that you run yourself, and need no User test.

- The Testing section of a ticket has only Claude bullets, each a check of the behaviour on the test service; it has no User bullet.
- The implement chat of a single ticket, started by Implement or by implement_ticket from a chat that is not a bundle chat, posts its completion comment after its push, with the result waiting for the test service on each Claude line, then follows the steps below.
- In a bundle, the ticket chats do not run their Claude tests: each Claude line of their completion comments reads waiting for the test service, and they set their tickets to review. The bundle chat follows the steps below after its single push, for every ticket it merged.

After the push, follow these steps:

1. CI: when the project has a GitHub page, follow "Waiting for CI", and go on with step 2 once the CI chat has reported "CI passed." or "CI not checked.". Otherwise wait with the gh CLI for the CI runs of the pushed commit until they end, for example with gh run list --commit <hash> and gh run watch <run id> --exit-status. When a run fails, fix the cause, build and test, commit the fix as fix: <summary> (<TICKET-ID>) with the id of the ticket whose change caused the failure, push as "Pushing" describes, and wait again, until every run passes. When there is no run to wait for (no workflow, no gh CLI or no remote), skip the wait, go on with step 2, and say in your final reply that CI was not checked.
2. Test service: build the Docker image from the repository's Dockerfile and run it with docker, with a temporary postgres when the service uses one, and mocks of the services it calls.
3. Checks: run every Claude bullet of each ticket's Testing section against the test service. When a check fails, fix the code, build and test, commit the fix with the id of the ticket whose change caused the failure, push, wait for CI as in step 1, and run the checks again, until every check passes.
4. When the test service cannot start (no Dockerfile, docker not available, the container exits): when the cause is in the repository, fix it, push and check again as in step 3; when it is outside the repository, give each Claude test of the tickets the result failed with the reason, and the tickets go to review.
5. Update each ticket's completion comment with update_comment: each Testing line gets its result, and Notes lists each fix commit of that ticket with its short hash and subject.
6. Set each ticket whose Claude tests have all passed to done, following "Ticket status"; set the other tickets to review. Then stop the test service and close the chats you started, as "Closing chats" describes. The bundle chat then closes its chat.

The bundle chat fixes the failed CI runs and checks itself and sets the tickets to done in step 6: these are the exceptions to "Do not implement the tickets yourself" and "Never set a ticket to done". It still asks as hephaestus-skills:implement-bundle describes after a ticket chat ends in error or is stopped, and when main fails to build or test before the push, and as "Waiting for CI" describes when CI fails in a project with a GitHub page.
