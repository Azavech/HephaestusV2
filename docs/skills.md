# Skills

HephaestusV2 keeps its own library of Claude skills: one folder per skill, holding a `SKILL.md` file and optional extra files, stored in the app's skills library folder, `<data dir>/Skills` unless Settings ▸ Skills names another folder, and never in `~/.claude`. The user creates, views, edits, renames and deletes skills in the Skills section, and Claude does the same through MCP tools. Each project enables the skills its chats may use. Four [internal skills](#internal-skills), which hold the steps of feedback and implementation, are always active in every project and are shown and edited only in the HephaestusV2 project. The engine generates, per project, a Claude Code plugin named `hephaestus-skills` that links the project's enabled skills and the internal skills and passes it to the CLI with `--plugin-dir`, so Claude sees each of them as `hephaestus-skills:<name>`.

## Library

| Property   | Value                                                                                                                                                                                                                                                                                                             |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Location   | host setting `skillsLibraryPath`; when absent, `<data dir>/Skills`, which is `~/Library/Application Support/HephaestusV2/Skills` by default ([Data model](data-model.md#skill-file)); a folder inside `~/.claude` is refused: `settings.update` fails with `invalid` ([Engine API](engine-api.md#settingsupdate)) |
| Scope      | one library per device; every project of the device sees the same skills; enablement is per project                                                                                                                                                                                                               |
| Creation   | the engine creates the folder, with missing parent folders, and writes the missing [internal skills](#internal-skills), at start and when the setting changes                                                                                                                                                     |
| Separation | the skills feature never reads or writes `~/.claude/skills` or a project's `.claude/skills` folder                                                                                                                                                                                                                |

A skill is an entry directly inside the library folder that is a folder or a symbolic link to a folder, has a valid name ([Skill names](#skill-names)) and holds a readable `SKILL.md` ([SKILL.md format](#skillmd-format)). A symbolic link to a folder counts as a folder. Default chosen at design time. Hidden entries (names starting with `.`) and every other entry are skipped. The engine logs a warning in `engine.log` for each skipped folder that is not hidden, `<folder path> skipped: <reason>`, the reason naming the invalid name, the unreadable `SKILL.md` or the [SKILL.md format](#skillmd-format) error; hidden entries and entries that are not folders are skipped without a log line. Default chosen at design time.

Example library:

```
Skills/
  .internal-skills.json
  feedback/
    SKILL.md
  finish-implementation/
    SKILL.md
  implement-bundle/
    SKILL.md
  implement-ticket/
    SKILL.md
  release-notes/
    SKILL.md
    templates/
      changelog.md
  swift-testing/
    SKILL.md
```

- Reading: `skills.list` and `skills.get` read the library from disk at every call.
- Watching: the engine watches the library folder recursively with FSEvents and emits `skills.changed` 300 ms after the last change it sees. It emits nothing when the library's files and folders, with their sizes and modification dates, are then the same as when it last emitted or started watching, as after the engine's writes made just before it started watching, which FSEvents can still report. Default chosen at design time. Changes inside the target of a symbolically linked skill folder are not watched; the next read sees them.

## Skill names

| Rule       | Value                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------- |
| Characters | lowercase ASCII letters `a` to `z` and digits `0` to `9`, in groups joined by single hyphens |
| Pattern    | `^[a-z0-9]+(-[a-z0-9]+)*$` ([Data model](data-model.md#ids))                                 |
| Length     | 1 to 64 characters                                                                           |
| Uniqueness | unique in the library                                                                        |
| Identity   | the folder name is the skill name                                                            |

| Name             | Valid | Reason               |
| ---------------- | ----- | -------------------- |
| `release-notes`  | yes   |                      |
| `swift6-testing` | yes   |                      |
| `a`              | yes   |                      |
| `Release-Notes`  | no    | uppercase letters    |
| `release_notes`  | no    | underscore           |
| `-release`       | no    | leading hyphen       |
| `release--notes` | no    | two hyphens in a row |
| 65 letters `a`   | no    | longer than 64       |

Creating or renaming fails with `conflict` when an entry with that name already exists in the library folder, as compared by the file system (on a case-insensitive volume, a folder `Release-Notes` blocks `release-notes`).

## SKILL.md format

`SKILL.md` is a YAML frontmatter between two `---` lines, followed by a Markdown body. The exact reading and writing rules are in [Data model](data-model.md#skill-file); the keys are:

| Key           | Rules                                                                                                                                                                          |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `name`        | the folder name is the skill's name; a missing or different `name` is ignored on reading, and the engine writes the folder name at its next write of the file                  |
| `description` | says what the skill does and when Claude should use it; reads as `""` when missing; the engine writes it with 1 to 1024 characters                                             |
| any other key | kept in `extraFrontmatter`, for example `allowed-tools`, and written back after `name` and `description`, sorted by key; Claude Code reads these keys from the file as written |

- The body is everything after the closing `---` line, verbatim. A file whose first line is not `---` has no frontmatter: the whole file is the body.
- A skill folder is skipped when its `SKILL.md` is not valid UTF-8, when the frontmatter has no closing line, or when the frontmatter is not a YAML mapping.
- The engine writes `SKILL.md` atomically and only through `skills.create` and `skills.update`.

Example, `Skills/release-notes/SKILL.md`, the example of [Data model](data-model.md#skill-file-example):

```markdown
---
name: release-notes
description: Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.
allowed-tools: Bash(git log:*), Read
---

# Release notes

1. Find the previous tag with `git describe --tags --abbrev=0`.
2. List the commit subjects since that tag with `git log <tag>..HEAD --format=%s`.
3. Group them by conventional commit type (feat, fix, others) and write one bullet per commit.
```

With the extra file `templates/changelog.md` of the example library, `skills.get` returns this [Skill](engine-api.md#skill):

```json
{
  "body": "\n# Release notes\n\n1. Find the previous tag with `git describe --tags --abbrev=0`.\n2. List the commit subjects since that tag with `git log <tag>..HEAD --format=%s`.\n3. Group them by conventional commit type (feat, fix, others) and write one bullet per commit.\n",
  "description": "Writes release notes from the commits since the last tag. Use when the user asks for release notes or a changelog.",
  "extraFrontmatter": {"allowed-tools": "Bash(git log:*), Read"},
  "files": ["templates/changelog.md"],
  "name": "release-notes"
}
```

## Skill files

Every file of a skill folder other than its `SKILL.md` is an extra file: templates, scripts, reference documents.

- `files` lists the skill paths of every regular file in the skill folder except `SKILL.md`, recursively, skipping names that start with `.`, sorted by path ([Data model](data-model.md#skill-file)).
- Skill paths are relative to the skill folder and follow the path rules of [Engine API](engine-api.md#paths).
- `skills.readFile` reads any file of the skill, `SKILL.md` included, with the content rules of `files.read`.
- `skills.writeFile` writes a text file, creating missing folders; `skills.deleteFile` moves a file or a folder to the Trash. Both refuse `SKILL.md` with `invalid`, and on a case-insensitive volume every case variant of it, such as `skill.md`, which names the same file: the name, description and body change through `skills.update`, and a whole skill goes to the Trash through `skills.delete`.
- Sizes are limited as in [Engine API](engine-api.md#limits).
- The API writes text files only. A binary file enters a skill when it is copied into the skill folder outside the app, for example in Finder.

## Internal skills

HephaestusV2 has four internal skills, which hold the steps Claude follows to turn feedback into a ticket and to implement tickets and bundles. They are skills of the device's library, always active in every project, and shown and edited only in the [HephaestusV2 project](projects.md#hephaestusv2-project), so that the user changes what Claude does for these tasks.

| Skill                   | Holds                                                                                                                                                                                        | Called by                                                                                                         |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `feedback`              | the steps that turn feedback into a ticket ([Project and feedback chats](workflow.md#project-and-feedback-chats))                                                                            | the first message of a feedback chat                                                                              |
| `implement-ticket`      | the steps of implementing a ticket ([Implementation workflow](workflow.md#implementation-workflow)) and the rules of a ticket chat started by a bundle chat ([Bundles](workflow.md#bundles)) | the first message of Implement and of `implement_ticket`; Claude whenever it implements a ticket, in any chat     |
| `implement-bundle`      | the steps of the orchestrator of a bundle ([Bundles](workflow.md#bundles))                                                                                                                   | the first message of Implement All and of `implement_bundle`; Claude whenever it implements a bundle, in any chat |
| `finish-implementation` | the [completion comment](workflow.md#completion-comment), [Waiting for CI](workflow.md#waiting-for-ci) and the checks of [Go service projects](workflow.md#go-service-projects)              | `implement-ticket` and `implement-bundle`, which tell Claude to call it                                           |

The common prompt keeps the other rules of [Claude workflow](workflow.md) and tells Claude to use `implement-ticket` whenever it implements a ticket and `implement-bundle` whenever it implements a bundle ([Prompt: common](chats.md#prompt-common)).

### Calls

The first message of a chat that runs an internal skill calls it as a Claude Code plugin skill, `/hephaestus-skills:<name>` followed by its arguments ([Implement and feedback chats](chats.md#implement-and-feedback-chats)):

| Chat                                   | First message                                                                                                                     |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Implement and `implement_ticket`       | `/hephaestus-skills:implement-ticket <ticket id>`, for example `/hephaestus-skills:implement-ticket HEPH-12`                      |
| a ticket chat started by a bundle chat | `/hephaestus-skills:implement-ticket <ticket id> <bundle id>`, for example `/hephaestus-skills:implement-ticket HEPH-12 HEPH-B2`  |
| Implement All and `implement_bundle`   | `/hephaestus-skills:implement-bundle <bundle id>`, for example `/hephaestus-skills:implement-bundle HEPH-B2`                      |
| feedback                               | `/hephaestus-skills:feedback`, a line break, then the [feedback message](chats.md#feedback-message), with the screenshot attached |

- Claude Code 2.1.309 runs a user message of a stream-json session as a skill call when its last content block is a text that starts with `/<plugin>:<skill>`: the skill's body follows the message, with `$ARGUMENTS` replaced by the rest of the text, line breaks included, and the message's image blocks stay visible to Claude. A message whose image block comes after its text is passed on as plain text, so the engine writes the image blocks before the text block ([User messages](chats.md#user-messages)). The CLI reports the message with `command_lifecycle` lines as any other ([Turn tracking](chats.md#turn-tracking)).
- The default skills read their arguments with `$ARGUMENTS` only: with Claude Code 2.1.309, a positional `$1` stays as written when the call has no second argument.
- Implement chats keep `questionsBlocked` and every other rule the engine enforces ([Implement chats](workflow.md#implement-chats)).

### Availability

- They are always active: the generated plugin of every project links them, whatever the project's `skills` list ([Generation](#generation)), so every chat of every project can use them.
- They are shown and edited only in the Skills section of the HephaestusV2 project, the window's device's project `HEPH` ([Recognition](projects.md#recognition)). The Skills section of every other project does not list them, and a skill selected there that is internal shows `Skill <name> was not found.`
- In the Skills section of the HephaestusV2 project, the `Enabled in <project name>` toggle shows them enabled and cannot be turned off ([Editor](#editor)).
- A search result or a `skill` target for one of them shows it in the Skills section of the HephaestusV2 project ([Search and navigation](#search-and-navigation)).
- While a device has no HephaestusV2 project loaded, or hides it ([Hiding the HephaestusV2 project](projects.md#hiding-the-hephaestusv2-project)), they stay active there but cannot be edited: no Skills section lists them and no chat's skill tools find them.

### Protection

- They cannot be renamed or moved to the Trash: the editor's Name field is disabled and Move to Trash is not available for them ([Editor](#editor), [Move to Trash](#move-to-trash)). The engine refuses a rename, a delete and disabling them with `forbidden` ([Engine API](#engine-api)), and `skills.create` refuses their names with `conflict`, `A skill named <name> already exists.`, also while their folder is missing. Their extra files are added, changed and moved to the Trash as those of any skill.
- Each has a default `SKILL.md`, a resource of the app, `Sources/HephaestusCore/Resources/skills/<name>/SKILL.md`, whose exact content is in [Default SKILL.md files](#default-skillmd-files); a docs conformance test compares them byte for byte.
- The engine writes a skill's default `SKILL.md`, creating its folder, when the library has no entry with its name or its folder has no `SKILL.md`: at engine start, when the library location changes ([Settings](#settings)), and before it generates a project's plugin ([Generation](#generation)). An entry with its name that is not a folder, or a write that fails, is logged in `engine.log` as `the internal skill <name> cannot be written: <reason>`, and the work goes on.
- The engine records the SHA-256 of each default `SKILL.md` it writes in `.internal-skills.json`, a hidden file of the library folder that the library skips: a JSON object whose keys are the skill names and whose values are the lowercase hexadecimal digests, for example `{"feedback":"9f2c…"}`. Default chosen at design time.
- When an app update changes a skill's default content, a copy the user never edited takes the new default: at the same moments, when the SHA-256 of the skill's `SKILL.md` equals the recorded digest and differs from that of the app's current default, the engine writes the current default and records it. A copy the user edited, whose digest differs from the recorded one or that has no recorded digest, is kept until Restore Default. A copy equal to the current default gets its digest recorded.
- The editor of each has a `Restore Default` button, which calls `skills.restoreDefault`: the engine writes the app's current default `SKILL.md`, its name, description and body, records its digest and keeps the extra files ([Engine API](engine-api.md#skillsrestoredefault)).

### Claude's skill tools

- `list_skills`, `get_skill` and `update_skill` list, read and change them only from chats of the HephaestusV2 project. From chats of other projects, from the external token and from comment answers, `list_skills` leaves them out, and `get_skill`, `update_skill` and `delete_skill` fail with `notFound` as for a skill that does not exist (`Skill <name> not found.`).
- `delete_skill`, a rename with `update_skill` and `set_skill_enabled` with `enabled` false fail for them with `forbidden`; `set_skill_enabled` with `enabled` true changes nothing and returns the project ([MCP](mcp.md#list_skills)).

The internal skills, their calls, their availability, their protection and the rules of Claude's skill tools come from the user. The record file, the log line, the errors, the disabled Name field and the defaults' text: Default chosen at design time.

### Default SKILL.md files

#### Default: feedback

`Sources/HephaestusCore/Resources/skills/feedback/SKILL.md`:

```markdown
---
name: feedback
description: Turns feedback that the user sent about HephaestusV2 into a ticket of the HephaestusV2 project. The first message of a feedback chat calls it with the comment and the feedback context.
---

# Turn feedback into a ticket

The feedback, the user's comment followed by its context:

<feedback>
$ARGUMENTS
</feedback>

The first message of this chat includes a screenshot of the window the user was using, saved at the path of the context's Screenshot line. Work out what the feedback means from the comment, the screenshot and the context, asking questions when it is unclear, then create its ticket with the screenshot path as an attachment and summarize the ticket. Follow these steps:

1. Read the comment, the context and the screenshot, then the docs and the code of this project that concern them.
2. List every decision the ticket's implementation needs, as "Writing tickets" says, ask every one still open with ask_questions and end your turn. Continue when the answers arrive, and go to step 3 only once every decision is answered.
3. Call create_ticket with the identifier of this chat's project as projectID, a description that follows the template and holds the answers, and the screenshot path in attachments. When the feedback reports several problems, create one ticket per problem.
4. Reply with a short summary of the ticket that names its id.

Implement the ticket in this chat only when the user asks for that, and then use the skill hephaestus-skills:implement-ticket.
```

#### Default: implement-ticket

`Sources/HephaestusCore/Resources/skills/implement-ticket/SKILL.md`:

```markdown
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
```

#### Default: implement-bundle

`Sources/HephaestusCore/Resources/skills/implement-bundle/SKILL.md`:

```markdown
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
```

#### Default: finish-implementation

`Sources/HephaestusCore/Resources/skills/finish-implementation/SKILL.md`:

```markdown
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
- The Testing part has one line per bullet of the ticket's Testing section, in the same order, with its result: passed, failed, waiting for the user, or waiting for the release for a code-test bullet while no release built by CI contains the commit. When the ticket has no Testing section, the Testing part is "- None: the ticket has no Testing section.".
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
```

## Engine API

Parameters, results and errors are in [Engine API](engine-api.md#skills). All mutations run on the engine actor, one at a time.

| Method                  | Actors       | Effect                                                                                                                                                                                                | Events                                                              |
| ----------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `skills.list`           | user, claude | every skill of the library, sorted by name                                                                                                                                                            | none                                                                |
| `skills.get`            | user, claude | one skill                                                                                                                                                                                             | none                                                                |
| `skills.create`         | user, claude | creates `<library>/<name>/SKILL.md`; an absent body is `""`; enables the skill in no project                                                                                                          | `skills.changed`                                                    |
| `skills.update`         | user, claude | changes the given fields and keeps the other frontmatter keys and the extra files; a rename renames the folder and replaces the old name, at the same position, in every loaded project that lists it | `skills.changed`; `project.updated` per project changed by a rename |
| `skills.delete`         | user, claude | moves the skill folder to the Trash and removes the name from every loaded project that lists it                                                                                                      | `skills.changed`; `project.updated` per changed project             |
| `skills.readFile`       | user         | reads a file of the skill                                                                                                                                                                             | none                                                                |
| `skills.writeFile`      | user         | writes a text file of the skill                                                                                                                                                                       | `skills.changed`                                                    |
| `skills.deleteFile`     | user         | moves a file or folder of the skill to the Trash                                                                                                                                                      | `skills.changed`                                                    |
| `skills.setEnabled`     | user, claude | adds the name at the end of the project's `skills` when absent, or removes it when present; enabling requires the skill to exist                                                                      | `project.updated`                                                   |
| `skills.restoreDefault` | user         | writes the default `SKILL.md` of an [internal skill](#internal-skills) and records its digest; keeps the extra files                                                                                  | `skills.changed`                                                    |

- `skills.create` and `skills.update` check the name against [Skill names](#skill-names) (`invalid`, or `conflict` when it is taken) and the description length of 1 to 1024 characters (`invalid`).
- When a skill's library entry is a symbolic link, `skills.delete` moves the link to the Trash and leaves its target untouched.
- For an [internal skill](#internal-skills), `skills.update` with a `newName` other than its name, `skills.delete` and `skills.setEnabled` with `enabled: false` fail with `forbidden` and `<name> is an internal skill of HephaestusV2: it cannot be renamed.`, `… it cannot be moved to the Trash.` or `… it is always enabled.`; `skills.setEnabled` with `enabled: true` changes nothing and returns the project; `skills.create` fails with `conflict`. A claude actor whose chat is not a chat of the HephaestusV2 project gets `skills.list` without the internal skills, and `skills.get`, `skills.update` and `skills.delete` fail for them with `notFound`, as for a skill that does not exist.
- In the engine, `SkillsLibrary` (`Sources/HephaestusCore/Skills/`) reads and writes the library and runs its watcher, and the protocol `SkillsPluginProvider`, implemented by `SkillsPluginGenerator`, prepares the [generated plugin](#generated-plugin) for chat launches and the `skills.*` methods, so that tests can provide another implementation. Default chosen at design time.
- `skills.changed` carries the whole library, sorted by name. API mutations emit it when they complete, and the library watcher emits it for every change it sees ([Library](#library)), changes inside a skill and the engine's own writes included, so one change can produce two events. Clients replace their skill list with the event data and re-fetch, with `skills.get`, the skill they show.

## Per-project enablement

- The `skills` key of `project.yml` lists the names of the skills enabled in the project ([Data model](data-model.md#enabled-skills)), in the order they were enabled: `skills.setEnabled` appends.
- Names that are not skills of the library are missing: they stay in the file, the plugin leaves them out, and the Skills section shows them so that they can be disabled.
- The [internal skills](#internal-skills) are active in every project whatever its list: `skills.setEnabled` never adds or removes them, and the plugin links them.
- Each project, sub projects included, has its own list; a sub project does not inherit the skills of its parent. Default chosen at design time.
- Every chat of a project, whatever its kind, uses that project's list.
- Users enable and disable skills in the Skills section (`skills.setEnabled`); Claude does the same with `set_skill_enabled`.
- A project cloned onto another Mac keeps its list, and the names resolve against that Mac's library.

## Generated plugin

### Layout

```
<data dir>/Runtime/plugins/<projectID>/
  hephaestus-skills/
    .claude-plugin/
      plugin.json
    skills/
      feedback -> <skills library>/feedback
      finish-implementation -> <skills library>/finish-implementation
      implement-bundle -> <skills library>/implement-bundle
      implement-ticket -> <skills library>/implement-ticket
      release-notes -> <skills library>/release-notes
      swift-testing -> <skills library>/swift-testing
```

`plugin.json`, for project `HEPH`:

```json
{
  "name": "hephaestus-skills",
  "version": "1.0.0",
  "description": "Skills enabled for project HEPH in HephaestusV2."
}
```

The description is `Skills enabled for project <projectID> in HephaestusV2.` Default chosen at design time.

### Generation

The engine regenerates the plugin folder of a project when the project's `skills` list changes (`skills.setEnabled`, a rename, a delete) and before every launch of a chat process of the project, the first launch and every `--resume` relaunch ([Chats](chats.md)). Regenerating before every launch also covers a deleted `Runtime/` folder and a changed library location. Default chosen at design time.

1. The engine writes the missing internal skills and lets an unedited copy take a new default ([Protection](#protection)), then computes E, the names of the project's list that are skills of the library and the names of the internal skills that are skills of the library, without duplicates, sorted by name.
2. When E is empty, it deletes `Runtime/plugins/<projectID>/` if the folder exists.
3. Otherwise it:
   1. creates the folders of the layout;
   2. writes `plugin.json` atomically when it is missing or its content differs;
   3. removes from `skills/` every entry that is not a symbolic link named after a member of E and pointing to `<skills library>/<name>`;
   4. creates each missing link `skills/<name>` with the absolute path of `<skills library>/<name>` as target.
4. At a launch, the CLI gets `--plugin-dir <data dir>/Runtime/plugins/<projectID>` when E is not empty, and no `--plugin-dir` otherwise. With the internal skills, E is empty only when they could not be written.

The CLI loads every child of that folder as a plugin, here `hephaestus-skills`, and offers each linked skill to Claude as `hephaestus-skills:<name>` with its description. When Claude uses a skill, the chat shows the `Skill` tool call like any other tool call ([Chats](chats.md)). Because the entries are symbolic links, Claude reads the library's current files.

- When generation fails with a file system error at a launch, the CLI is launched without `--plugin-dir` and the chat gets a `system` item with level `warning` and the text `Skills could not be prepared: <error message>`. Default chosen at design time.
- Running chat processes are not restarted when skills, their files, the library location or a project's list change; a process launched afterwards uses the regenerated folder.
- `projects.remove` deletes `Runtime/plugins/<projectID>/`. Default chosen at design time.
- `Runtime/` can be deleted while no chat process runs; the next launch regenerates the folder.

### Checking a generated plugin

With Claude Code 2.1.309, this command loads the folder the way a chat process does and lists the linked skills in the plugin's component inventory:

```
claude --plugin-dir "<data dir>/Runtime/plugins/HEPH" plugin details hephaestus-skills
```

`claude plugin validate "<data dir>/Runtime/plugins/HEPH/hephaestus-skills"` checks `plugin.json`; it reports the symbolic links in `skills/` as not read, while a session follows them.

## MCP tools

| Tool                | Input                               | Engine method       |
| ------------------- | ----------------------------------- | ------------------- |
| `list_skills`       | none                                | `skills.list`       |
| `get_skill`         | name                                | `skills.get`        |
| `create_skill`      | name, description, body             | `skills.create`     |
| `update_skill`      | name, newName?, description?, body? | `skills.update`     |
| `delete_skill`      | name                                | `skills.delete`     |
| `set_skill_enabled` | projectID, name, enabled            | `skills.setEnabled` |

Input schemas, results and errors are in [MCP](mcp.md). The tools show and change the [internal skills](#internal-skills) only from chats of the HephaestusV2 project ([Claude's skill tools](#claudes-skill-tools)). No MCP tool reads, writes or deletes extra files; Claude reaches extra files with its own file tools, under the chat's permission mode.

## Skills section

The Skills section of the active project (sidebar, ⌘8, [UI](ui.md)) has two columns: the library list and the editor of the selected skill (`selectedSkillName`).

### Library list

- A filter field in the list's header bar, placeholder `Filter`, keeps the skills whose name or description contains its text, compared case-insensitively. Default chosen at design time.
- The header bar is the list's pane header: 36 pt high, the field centred vertically in it, its bottom separator on one line with those of the editor, of the inspector and of the other sections ([Pane headers](ui.md#pane-headers)).
- Rows are sorted by name. Each row shows the SF Symbol `checkmark.circle.fill` when the skill is enabled in the active project, the name, and the description on one truncated line.
- The [internal skills](#internal-skills) are listed only when the active project is the HephaestusV2 project, the window's device's project `HEPH`, and show `checkmark.circle.fill` there.
- When the project's list names skills the library lacks, a group `Missing from Library` follows, one row per name: the SF Symbol `exclamationmark.triangle`, the name, the text `Not found in the skills library` and a `Disable` button that calls `skills.setEnabled` with `enabled: false`.
- The bottom bar has `+` (New Skill…) and `−` (Move to Trash…, disabled without a selection and while an internal skill is selected).

### Editor

| Part              | Content                                                                                                                                                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Header            | Name field, disabled for an [internal skill](#internal-skills); buttons `Restore Default`, for an internal skill only, `Revert` and `Save`, on the editor's pane header ([Pane headers](ui.md#pane-headers))             |
| Under the header  | the name's validation message, when there is one; caption `Claude sees this skill as hephaestus-skills:<name>`; toggle `Enabled in <project name>`                                                                       |
| Description       | multi-line field that wraps, with the counter `<n>/1024`                                                                                                                                                                 |
| Other frontmatter | shown when `extraFrontmatter` is not empty: read-only, monospaced, one `key: value` line per key in YAML, sorted by key                                                                                                  |
| Body              | Markdown editor with the modes Edit, Preview and Split and the shared Markdown renderer ([Documentation viewer](documentation-viewer.md)); placeholder `Instructions Claude follows when it uses this skill (Markdown).` |
| Files             | the extra files with `+` (New File…) and `−` (Move to Trash…); the selected file opens under the list                                                                                                                    |
| Footer            | the skill folder path, home folder written `~`; `Reveal in Finder` when the window's device is this Mac                                                                                                                  |

- The header is a bar 36 pt high, its content centred vertically, its bottom separator on one line with those of the list, of the inspector and of the other sections ([Pane headers](ui.md#pane-headers)). The Name field, `Restore Default`, `Revert` and `Save` are on its one row; the name's validation message, the caption and the toggle, which do not fit on it, are on a row just under its separator, and the banners follow them. Which elements are on the header's row: Default chosen at design time.
- The `Enabled in <project name>` toggle applies at once through `skills.setEnabled`, using the saved name. For an internal skill it is on and disabled: it cannot be turned off.
- `Restore Default` calls `skills.restoreDefault` without confirmation; once it succeeds, the form's unsaved changes are discarded and the editor shows the restored skill. A failure shows as the alert of a failed control titled `Restore Default failed` ([Principles](ui.md#principles)), and the form keeps its changes. Default chosen at design time.
- The body's mode starts as Preview, as in the Docs section ([Modes](documentation-viewer.md#modes)), and is kept when the window selects another skill of the same project. Default chosen at design time.
- Preview renders the body natively with `MarkdownBlockRenderer` ([Block model](documentation-viewer.md#block-model)) and the options `baseDirectory` `""`, no `projectRootPath` and `stripFrontMatter` false: the body has no front matter and belongs to no project folder. Links in the preview do nothing and project images show as blocked. Default chosen at design time.
- The form and the open extra file belong to the window and project: `ProjectViewState.skillEditor` ([WindowState](ui.md#windowstate)), never encoded. Returning to the project restores them, unsaved changes included.
- A skill with an empty description shows the banner `This skill has no description. Claude uses the description to decide when to use the skill.`

Extra file view:

| File                                                                                 | View                                                                                                                                                                      |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| text (`FileContent.text` present)                                                    | the code editor with highlighting by file extension ([Code editor](code-editor.md)); ⌘S saves with `skills.writeFile`                                                     |
| image (`png`, `jpg`, `jpeg`, `gif`, `heic`, `heif`, `tif`, `tiff`, `bmp`, `webp`)    | the image, scaled to fit, read-only                                                                                                                                       |
| any other file, and a file above 20 MiB, returned without content, an image included | `Binary file · <size>`                                                                                                                                                    |
| a failed `skills.readFile`                                                           | the error row of the code editor ([Large and binary files](code-editor.md#large-and-binary-files)): `The file could not be opened.`, the engine's message and `Try Again` |

New File… opens a sheet with a `Path` field (a relative path such as `templates/changelog.md`). Create calls `skills.writeFile` with an empty text and selects the new file; path errors appear under the field. A path that names an existing extra file or folder of the skill, which `skills.writeFile` would empty, is refused under the field with `<path> already exists.`, as in [New File and New Folder](code-editor.md#new-file-and-new-folder). Selecting another extra file while the open one has unsaved changes asks the save question of [Saving](#saving) first; Cancel keeps the open file. Default chosen at design time.

### Saving

- The form (name, description, body) has unsaved changes when it differs from the last loaded skill. Save (⌘S) calls `skills.update` with the changed fields only, `newName` when the name changed. ⌘S saves the form when it has changes and the open extra file when it has changes.
- Revert discards the form's changes.
- Selecting another skill, leaving the section or closing the window while the form or the open extra file has unsaved changes asks `Do you want to save the changes to “<name>”?` with `Save`, `Don't Save` and `Cancel`: one prompt for the skill, also when both have changes. Save saves the form, then the extra file, those that have changes; a failed save cancels. Don't Save discards both.
- On `skills.changed`, the editor re-fetches the shown skill with `skills.get`, and the open extra file with `skills.readFile`. Content without unsaved changes is replaced silently. Content with unsaved changes whose saved version changed shows the banner `This skill was changed elsewhere.` with `Reload` and `Keep Mine`; Keep Mine hides the banner and the next save overwrites. Default chosen at design time.
- When the skill is deleted or renamed elsewhere while the form or the open extra file has unsaved changes, the editor stays with the banner `This skill was changed elsewhere.`: Reload discards the changes, Keep Mine keeps them and the next save reports the engine's error. Without unsaved changes, the editor shows `Skill <name> was not found.` Default chosen at design time.
- An error returned by the engine on save appears in an alert with its message.

Field validation, shown under the field while Save and Create stay disabled:

| Condition                          | Message                                                  |
| ---------------------------------- | -------------------------------------------------------- |
| name does not match the pattern    | `Use 1–64 lowercase letters, digits and single hyphens.` |
| name already used by another skill | `A skill named “<name>” already exists.`                 |
| description empty                  | `A description is required.`                             |
| description over 1024 characters   | `At most 1024 characters.`                               |

### New Skill sheet

| Field                      | Content                                |
| -------------------------- | -------------------------------------- |
| Name                       | text field, validated while typing     |
| Description                | multi-line field, 1 to 1024 characters |
| `Enable in <project name>` | checkbox, checked when the sheet opens |

`Cancel` (Escape) closes the sheet. `Create` (default button: Return outside the Description field, ⌘Return anywhere; enabled when both fields are valid) calls `skills.create` with the name and description, then `skills.setEnabled` with `enabled: true` when the checkbox is checked, then selects the new skill and focuses its body in Edit mode. The sheet offers to enable the new skill in the active project. When the skill is created but enabling it fails, the sheet still closes, the skill is selected, and the failure shows as the alert of a failed control titled `Enable in <project name> failed` ([Principles](ui.md#principles)). Default chosen at design time.

### Move to Trash

- Skill other than an [internal skill](#internal-skills): the alert `Move “<name>” to the Trash?` with the message `The skill is removed from every project that enables it.` and the buttons `Move to Trash` (destructive, default) and `Cancel` (Escape), as in [Move to Trash](code-editor.md#move-to-trash); confirming calls `skills.delete`. Default chosen at design time.
- Extra file: the alert `Move “<path>” to the Trash?` with the same buttons; confirming calls `skills.deleteFile`.

### Keyboard

| Key                                                                     | Action                                                                   |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| ⌘S                                                                      | save the form and the open extra file                                    |
| ⌫ or ⌘⌫ with a list row selected                                        | Move to Trash confirmation for that skill; nothing for an internal skill |
| Return in the Name field of the New Skill sheet, ⌘Return anywhere in it | Create                                                                   |
| Escape in a sheet                                                       | Cancel                                                                   |

### Empty and error states

| State                | Content                                                                                                                                                                                                                                                              |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Library empty        | the library has no skill that the list shows: title `No Skills`; text `Skills are folders with a SKILL.md file in <library path>. Enable a skill in a project to let its chats use it.`; button `New Skill…`                                                         |
| No skill selected    | `Select a skill`                                                                                                                                                                                                                                                     |
| Filter without match | `No skills match “<filter text>”`                                                                                                                                                                                                                                    |
| `skills.list` fails  | the error message, for example while the window's device is disconnected                                                                                                                                                                                             |
| `skills.get` fails   | in the editor column, the engine's message and `Try Again`, as a chat view's failed load ([Empty states](ui.md#empty-states)); a missing skill, and an internal skill selected in another project than the HephaestusV2 project, shows `Skill <name> was not found.` |

## Settings

The library folder is chosen in Settings ▸ Skills, whose controls are specified in [Skills library](ui.md#skills-library). When `skillsLibraryPath` changes, the engine uses the new folder, creates it when it is missing, writes the missing [internal skills](#internal-skills) there, and emits `settings.updated` and `skills.changed` ([Engine API](engine-api.md)). Skills of the previous folder are not moved or copied and project lists are not changed; names absent from the new library become missing.

## Remote windows

- A remote window shows and edits the main device's library through the same methods; files are read and written on the main device ([Remote devices](remote.md)).
- `Reveal in Finder` is hidden in remote windows.
- A remote snapshot carries neither the main device's data directory nor its home folder. The library path of the empty state and the editor's footer is the main device's `skillsLibraryPath`, or `~/Library/Application Support/HephaestusV2/Skills` when it is absent; a path under `/Users/<name>` is written with `~`. Default chosen at design time.

## Search and navigation

- The Skills scope of [Search](search.md) matches skills on their name, description and body.
- The navigation target `skill` {name}, from search, `ui.open` or the MCP tool `open_in_app`, shows the Skills section of the window's active project and selects the skill, as defined in [UI](ui.md#navigation). For an [internal skill](#internal-skills), it shows the Skills section of the HephaestusV2 project when the window's device has it.

## Limits

| Limit                             | Value                                    |
| --------------------------------- | ---------------------------------------- |
| Skill name                        | 1 to 64 characters                       |
| Description written by the engine | 1 to 1024 characters                     |
| File read or written              | as in [Engine API](engine-api.md#limits) |

## Requirements covered

- R46: A feature edits Claude skills.
- R47: Skills can be used inside projects.
- R48: A skill is an item the user can create, see and edit.
- R49: Skills are in their own folders, not in `~/.claude`.
- R168: The header bars at the top of the panes of the main window's centre column, and the inspector's header, are all 36 points high, so that their bottom separators lie on one line.
- R181: Feedback, Implement and Implement All start their chat by calling the internal skills feedback, implement-ticket and implement-bundle, which, with finish-implementation, hold the instructions of these tasks, are always active in every project, and are shown and edited only in the HephaestusV2 project.
