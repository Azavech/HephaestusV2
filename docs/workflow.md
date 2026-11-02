# Claude workflow

This is the operating manual Claude follows in every HephaestusV2 chat. Claude never invents: it asks labelled questions, each with a recommended answer. It writes tickets with the description template and respects the status rules. It implements a ticket by changing the docs first and then the code to match them; it then builds and tests, commits with a conventional commit message, pushes and comments on the ticket, and it never marks the ticket done. A bundle chat orchestrates a bundle: it starts one ticket chat per ticket, each running that workflow without pushing, and pushes once at the end. On the HephaestusV2 project itself, the push starts the self-update loop, which ends with the app restarting on the new version. The rules reach Claude through the system prompts of [Chats](chats.md), and the engine enforces the ones it can check. The user-facing behaviour of tickets and bundles is in [Tickets and bundles](tickets.md); both documents state the same rules.

## Where the rules apply

| Chat kind        | Started by                                                             | Prompt resources           | What this workflow adds                                                                                                                                      |
| ---------------- | ---------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `project`        | New Chat (⌥⌘N), the project chat panel or the Chats section            | `common.md`, `project.md`  | Free-form work; tickets are written with the template                                                                                                        |
| `ticket`         | Implement, New Chat in a ticket's Chats tab, `implement_ticket`        | `common.md`, `ticket.md`   | Implement runs the [implementation workflow](#implementation-workflow); a ticket chat started by a bundle chat commits without pushing ([Bundles](#bundles)) |
| `bundle`         | Implement All, New Chat in a bundle's Chats tab, `implement_bundle`    | `common.md`, `bundle.md`   | Implement All runs the [bundle workflow](#bundles): the chat orchestrates one ticket chat per ticket                                                         |
| `feedback`       | The ladybug ([Feedback](feedback.md))                                  | `common.md`, `feedback.md` | Clarify the feedback, then create its ticket                                                                                                                 |
| External session | A terminal Claude session using the external MCP token ([MCP](mcp.md)) | none                       | Only the [engine-enforced rules](#engine-enforced-rules); no `ask_questions` or `ask_symbol`                                                                 |

- The prompt resources are in `Sources/HephaestusCore/Resources/prompts/`, and their full text is in [Chats](chats.md). `common.md` states every rule of this document in imperative form.
- Claude CLI also reads the project's own `CLAUDE.md` from the project root. The `CLAUDE.md` of the HephaestusV2 repository links to this document. Default chosen at design time.
- An explicit instruction from the user in the chat replaces a step of this workflow, for example "do not push". The engine-enforced rules cannot be replaced: when an instruction conflicts with one of them, Claude tells the user that the user has to do it. Default chosen at design time.

## App data through MCP

- Claude reads and changes HephaestusV2 data (projects, tickets, comments, bundles, chats, web tabs and skills) with the tools of the `hephaestus` MCP server, which Claude sees as `mcp__hephaestus__<tool>` ([MCP](mcp.md)). It never edits the files under `.hephaestus/` directly. Default chosen at design time.
- Every tool call goes through the engine, which validates it and sends the change to every window and remote device.
- To show the user an item, Claude calls `open_in_app` with a navigation target.

## Never invent

- Claude never invents a requirement, behaviour, name or value visible to users, text shown to users, file format or product decision. Everything of this kind that it builds comes from the user's messages, the ticket with its comments and attachments, the docs, or the existing code.
- Technical choices inside the code that change no documented behaviour are Claude's to make. Default chosen at design time.
- Before asking, Claude looks for the answer itself in the ticket, its comments and attachments, the docs, the code and the git history, and asks only what is still unknown.
- Claude asks what is still unknown with the [questions protocol](#questions-protocol) before acting on it, then ends its turn and waits. It never continues on a guess to be confirmed later.
- Statements that contradict each other, such as a comment that contradicts the description, count as an unknown. Default chosen at design time.
- In comments and replies Claude reports only what it did and checked.

## Questions protocol

### Asking

- Claude asks with the MCP tool `ask_questions`. Its input `questions` is a list of `{label, question, options: [{label, description?}], recommended}`, and its schema is in [MCP](mcp.md).
- Questions are labelled `A`, `B`, `C` and so on, in order, starting at `A` in every call. One call holds at most 26 questions.
- Each question asks for one decision and offers 2 to 10 options. An option's `label` is the answer text; its optional `description` is one line stating the consequence.
- Exactly one option is recommended: `recommended` is the label of one of the question's options.
- Claude adds no "Other" option, because the UI always lets the user answer another way. Default chosen at design time.
- Claude puts every point that is unknown at that moment into one call. Default chosen at design time.
- The tool returns at once with the text `questions shown; answers arrive in the next user message; end your turn`. Claude then ends its turn: it calls no further tool.
- Claude does not repeat the questions in its reply text, because the chat shows them. Default chosen at design time.
- A chat has at most one waiting request: a question set without all its answers, or a [symbol request](#symbol-requests) without answer. Calling `ask_questions` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, and while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`. The question-set rule and its message are Default chosen at design time.
- `ask_questions` works only with a chat's own token, never with the external token ([MCP](mcp.md)).

### Validation

`chats.postQuestions` checks the input. Every failure is `invalid` with the message below, and nothing is shown to the user.

| Rule                                                                                         | Message                                                                                |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| 1 to 26 questions                                                                            | `ask_questions needs 1 to 26 questions.`                                               |
| Labels are `A`, `B`, `C` and so on, in order                                                 | `Question <n> must have the label "<letter>".`                                         |
| `question` is not empty after trimming                                                       | `Question <label> has no text.`                                                        |
| 2 to 10 options                                                                              | `Question <label> needs 2 to 10 options.`                                              |
| Option labels are not empty after trimming and are unique within the question, ignoring case | `Question <label> has an empty or repeated option label.`                              |
| Option labels are one line of at most 200 characters                                         | `Question <label> has an option label longer than 200 characters or on several lines.` |
| `recommended` equals the label of one of the question's options                              | `Question <label>: the recommended answer must be one of its option labels.`           |

The label, text and option-label checks, the maximum of 10 options and all messages are defaults; the rules of at least two options and exactly one recommended option come from the design. Default chosen at design time.

### Answering

- The questions appear in the chat as a card above the composer, one at a time, with a header such as `Question B (2 of 3)` and arrows that move between the questions of the set. The card lists the options, with the recommended one marked `Recommended` and preselected, plus a free-text field `Answer another way`, a Submit button and a Skip button. The card can be minimized into a one-line bar ([Chats](chats.md#pinned-questions-card)).
- The user answers the questions one by one, in any order, from any window or device. Each Submit stores one answer with `chats.answerQuestion` (`questionSetID`, `label`, `answer`); submitting again on an answered question replaces its answer while the set is not completed. Skip stores the answer `Skipped`. The chat's state is `waitingAnswers` while the set is not completed.
- The stored answer is the label of the chosen option, or the free text as typed, trimmed. Default chosen at design time.

### Answers message

When the last question of a set is answered, the engine marks the set `completed` and sends Claude one user message:

```text
Answers:
A: <answer>
B: <answer>
```

- The message has one line per question, in label order, in the form `<label>: <answer>`. Line breaks inside a free-text answer are kept. Default chosen at design time.
- A skipped question reads `<label>: Skipped`. Claude leaves that point out: it does not act on it or guess, and it mentions it in its reply.
- Answers are decisions: Claude applies them and does not ask them again. An answer that raises a new unknown leads to a new question set, labelled from `A` again.

### Plain-text questions

In an external session, where `ask_questions` and `ask_symbol` are not available, Claude writes the questions in its reply in this form and ends its turn; a symbol choice becomes a question whose options are the symbol names:

```text
A: <question>
   1. <option> (recommended)
   2. <option>
B: <question>
   1. <option>
   2. <option> (recommended)
```

The user answers with one `<label>: <answer>` line per question. Default chosen at design time.

### Symbol requests

When Claude needs the user to choose an SF Symbol, it asks with the MCP tool `ask_symbol` instead of listing symbol names as options of `ask_questions` ([MCP](mcp.md#ask_symbol)).

- One call asks for one symbol. Its inputs are `question`, the question; `suggestions`, 2 to 10 SF Symbol names; and `recommended`, the suggestion Claude recommends.
- The tool returns at once with the text `symbol request shown; the answer arrives in the next user message; end your turn`. Claude then ends its turn: it calls no further tool, and it does not repeat the question in its reply.
- A chat has at most one waiting request ([Asking](#asking)): calling `ask_symbol` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, and while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`.
- `ask_symbol` works only with a chat's own token, never with the external token ([MCP](mcp.md#ask_symbol)).

`chats.postSymbol` checks the input, after trimming each suggestion and `recommended`. Every failure is `invalid` with the message below, and nothing is shown to the user. The messages are Default chosen at design time.

| Rule                                                                                              | Message                                                              |
| ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `question` is not empty after trimming                                                            | `ask_symbol needs a question.`                                       |
| 2 to 10 suggestions                                                                               | `ask_symbol needs 2 to 10 suggestions.`                              |
| Suggestions are not empty and are distinct                                                        | `ask_symbol has an empty or repeated suggestion.`                    |
| Each suggestion is a name of the [symbol catalogue](chats.md#symbol-catalogue) of the main device | `<name> is not an SF Symbol of this Mac.`                            |
| `recommended` equals one of the suggestions                                                       | `ask_symbol: the recommended symbol must be one of the suggestions.` |

The suggestion check runs in the order of `suggestions` and names the first unknown suggestion.

The request appears in the chat as a pinned symbol card above the composer ([Chats](chats.md#pinned-symbol-card)): the suggestions as icons, the recommended one marked and preselected, a search over every SF Symbol of the Mac, a free-text field `Answer another way`, a Skip button and a Submit button. The user answers once with `chats.answerSymbol`, from any window or device; the chat's state is `waitingAnswers` until then. The engine then sends Claude one user message:

```text
Symbol: <answer>
```

- `<answer>` is `![](sf:<name>)` for a symbol chosen in the card, for example `Symbol: ![](sf:line.3.horizontal.decrease.circle)`; the text the user typed, trimmed, with its line breaks; or `Skipped` for a skipped request.
- A skipped request is handled like a skipped question: Claude leaves that point out, does not act on it or guess, and mentions it in its reply.
- The answer is a decision: Claude applies it and does not ask again.

## Writing tickets

- Claude creates a ticket with `create_ticket` (`projectID`, `description`, `attachments?`). It never gives a title: Haiku names the ticket ([Titles and naming](tickets.md#titles-and-naming)). The ticket starts as `todo`.
- The description uses this template, and the engine rejects any description that does not ([Template validation](tickets.md#template-validation)):

```text
Problem
(Explain the problem)

Current Behavior
(Explain the current behaviour)

Expected
(Explain the behaviour that should be expected)

Change
(Explain what should change)

Testing
(List the tests that decide whether the ticket is done)

Docs
(List all docs files and paragraphs relevant to the issue)
```

| Heading          | What Claude writes                                                                                                                                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Problem          | What is wrong or missing, from the user's point of view, in one to three sentences.                                                                                                                                                  |
| Current Behavior | What happens today, with numbered steps to reproduce a defect. For a feature that does not exist yet: `None: the feature does not exist yet.`                                                                                        |
| Expected         | The behaviour after the change, precise enough to be tested.                                                                                                                                                                         |
| Change           | What changes in the docs and in the code, naming the docs files and code areas, limited to what has been decided.                                                                                                                    |
| Testing          | One bullet per test that decides whether the ticket is done, prefixed with who performs it: `- Claude: <test>` for a test Claude runs, `- User: <test>` for a test the user performs.                                                |
| Docs             | One bullet per relevant docs file and section, as a Markdown link relative to the project root, for example `- [tickets.md › Status rules](docs/tickets.md#status-rules)`. A section that does not exist yet is followed by `(new)`. |

The content rules of this table are defaults. Default chosen at design time.

- Claude replaces the hint lines of the template, such as `(Explain the problem)`; it never keeps them.
- When something the ticket needs is unknown, Claude asks first and creates the ticket after the answers.
- Each problem gets its own ticket: a request covering several problems leads to one `create_ticket` call per problem. Default chosen at design time.
- Attachments are file paths on the main device, such as screenshots or logs. They are copied into the ticket ([Attachments](tickets.md#attachments)).
- After creating tickets, Claude tells the user their ids.
- When Claude rewrites the description of an existing ticket with `update_ticket`, the new description also follows the template.

## Ticket status

The status rules (the same list is in [Status rules](tickets.md#status-rules)):

- Every ticket is created with status `todo`; the user may change it afterwards with the status picker.
- Claude sets `in_progress` when it starts working on a ticket.
- When Claude has finished a ticket, after the completion comment, it sets `done` when every Claude test of the ticket's Testing section has passed and the user has said in the chat that every User test has passed; otherwise it sets `review`. A ticket without a Testing section goes to `review`. Claude may switch a ticket between `in_progress` and `review`, for example to make a correction the user asked for.
- Claude may never change the status of a `done` ticket.
- The user may set any status at any time.
- A `review` ticket is not done: Implement and Implement All stay enabled for it.

How Claude applies them:

- `set_ticket_status` with `in_progress` is the first step of the implementation workflow; in a bundle it is the first step for each ticket.
- In a ticket chat started with New Chat, Claude sets `in_progress` before its first change to the docs or the code for that ticket. Reading the ticket and answering questions do not change the status. Default chosen at design time.
- `set_ticket_status` with `done` or `review` follows the completion comment of a finished ticket. For a `review` ticket, the completion comment and the final reply ask the user to review the ticket and set it to Done.
- When the user later says in the chat that every User test of a `review` ticket has passed, and every Claude test has passed, Claude sets it to `done`.
- The engine does not check the tests: Claude applies this rule itself.
- To change a `review` ticket, for example for a correction the user asked for, Claude sets it to `in_progress` before its first change, and back to `review` after the completion comment of the correction.
- Claude sets `todo` only when the user asks for it, or when the user decides to skip a ticket of a bundle. Default chosen at design time.
- Claude does not implement a `done` ticket. It tells the user to set the status to To Do or In Progress first. Default chosen at design time.
- When the engine answers `forbidden`, Claude reports the message to the user and does not work around it.

## Implementation workflow

The steps, in order:

1. `set_ticket_status` with `in_progress`.
2. Read the ticket (`get_ticket`) and the docs it lists. Ask questions for anything unknown, then wait.
3. Change the docs first, then change the code to match the docs.
4. Build and test, with the project's commands or the repository's own commands.
5. Commit with a conventional commit message `<type>: <summary> (<TICKET-ID>)`, then push.
6. `add_comment` on the ticket with a summary of what changed, commit hash included.
7. `set_ticket_status` with `done` when every Claude test of the ticket has passed and the user has said in the chat that every User test has passed; otherwise with `review`.

The workflow starts with Implement, whose first message is `implement-ticket.md`, with `implement_ticket` called from another chat (from a bundle chat, the first message is `implement-bundle-ticket.md`, [Bundles](#bundles)), or when the user asks for the implementation in a ticket chat.

### Read

- `get_ticket` returns the description, comments and attachments. Claude views image attachments by reading their paths.
- Claude reads every docs section listed under Docs, the docs index (the `README.md` of the docs folder, when there is one) and the code involved.
- Unknowns are asked as described in [Questions protocol](#questions-protocol). After asking, Claude ends its turn and continues when the Answers message arrives.

### Docs first

- The docs are the files under the project's `docsPath` (`docs` by default). They are the contract the code is built and tested against.
- Claude first changes every affected docs section so that it describes the behaviour after the change completely, following the conventions of that docs folder (for HephaestusV2, see [Docs index](README.md)).
- When the docs already describe the expected behaviour (a defect where the code differs from the docs), they stay unchanged and the completion comment says so. Default chosen at design time.
- When the project has no docs folder, Claude asks whether to create one, recommending `<docsPath>/<topic>.md`. Default chosen at design time.
- Then Claude changes the code until it does what the docs say. Where the project has tests, it adds or updates tests for the changed behaviour.
- For HephaestusV2 itself, four more rules apply. Every docs file stays linked from `docs/README.md`. Markdown tables stay aligned (`python3 -I scripts/tables.py --fix <files>` aligns them). No personal data enters the repository. The docs conformance tests must pass ([CI](ci.md)).
- A change that adds a user requirement to HephaestusV2 also adds it to [Requirements](requirements.md) and to the `Requirements covered` section of each docs file that fulfils it. Default chosen at design time.

### Build and test

- When project.yml defines `commands.build` or `commands.test`, Claude runs them with `run_project` (`kind` `build`, then `test`) and waits for each to finish. The output also appears in the Console of every window ([Projects](projects.md)).
- Otherwise Claude runs the repository's own commands with its shell tool: the Makefile targets `build` and `test` when they exist, otherwise `swift build` and `swift test` for a Swift package, or `go build ./...` and `go test ./...` for a Go module. Default chosen at design time.
- When a command fails, Claude fixes the cause and runs it again. It never commits while the build or the tests fail. When a failure also happens without Claude's change, Claude asks whether to commit anyway. Default chosen at design time.
- When no build or test command exists, Claude skips this step and says so in the completion comment. Default chosen at design time.
- Claude does not start the project's `run` command unless the user asks for it. Default chosen at design time.
- When Claude checks the UI of HephaestusV2 itself, it uses a second, isolated instance and the debug MCP tools ([Development](development.md)), never the app the user is running. Default chosen at design time.

### Final reply

After the comment and the status, Claude ends with a short reply: what changed, the commit, the checks, the result of each test, and, for a `review` ticket, that it waits for the user to set it to Done. Default chosen at design time.

## Commits

```text
<type>: <summary> (<TICKET-ID>)

<optional body>

<optional footer>
```

| Type       | Use for                                               |
| ---------- | ----------------------------------------------------- |
| `feat`     | New behaviour, or a change to intended behaviour.     |
| `fix`      | A defect corrected.                                   |
| `docs`     | A change to the docs only.                            |
| `refactor` | Code restructured without a change in behaviour.      |
| `perf`     | Faster or lighter code without a change in behaviour. |
| `test`     | A change to the tests only.                           |
| `build`    | Build system, packaging and dependencies.             |
| `ci`       | CI workflows and their scripts.                       |
| `chore`    | Any other maintenance.                                |

The "Use for" column is a default. Default chosen at design time.

- When the docs and the code change together, the type describes the code change (`feat` or `fix`), not `docs`. Default chosen at design time.
- There is no scope: nothing comes between the type and the colon except `!` for a breaking change.
- The summary is in English, in the imperative mood, starts with a lowercase letter unless it starts with a name or code, and has no final period. The whole first line is at most 72 characters. Default chosen at design time.
- The body is optional. It follows a blank line, is wrapped at 72 columns and explains why. Default chosen at design time.
- A breaking change is written `<type>!: <summary> (<TICKET-ID>)` with the footer `BREAKING CHANGE: <what breaks>`. Claude marks a change as breaking only when the ticket or the user says so, and asks when unsure. Default chosen at design time.
- For HephaestusV2, release versions follow the commit types ([CI](ci.md)): a breaking change gives a major version, `feat` a minor version, anything else a patch.
- Each ticket gets one commit. A later correction asked for in the same chat gets its own commit, with the same ticket id. Default chosen at design time.
- Work outside a ticket, done in a project chat at the user's request, uses the same format without ` (<TICKET-ID>)`. Default chosen at design time.
- Claude stages by path only the files it changed for the ticket. It never stages with `git add -A` or `git add .`, never stages `.hephaestus/` (the user commits ticket data), and never commits changes it did not make. When a file it must change already has uncommitted changes it did not make, Claude asks. Default chosen at design time.
- Claude never amends or rebases a pushed commit, never skips hooks (`--no-verify`), never force-pushes and never changes the git configuration. Default chosen at design time.
- In HephaestusV2, no personal data (real names, e-mail addresses, home paths, device names or team ids) goes into files or commit messages; `scripts/check-public.sh` rejects it in CI ([CI](ci.md)).

Examples, from an illustrative project with the identifier `DEMO`:

```text
fix: answer 503 from /health when the database is down (DEMO-7)
feat: add a JSON export of orders (DEMO-9)
docs: document the health endpoint answers (DEMO-11)
```

```text
feat!: require an API key on every endpoint (DEMO-12)

Anonymous requests reached the order data. Every endpoint now checks
the X-API-Key header.

BREAKING CHANGE: requests without the X-API-Key header now answer 401.
```

## Pushing

- Claude pushes the current branch to its upstream with `git push`. It creates no branch and no pull request. Default chosen at design time.
- When the branch has no upstream but a remote named `origin` exists, Claude runs `git push -u origin <branch>`. With no remote at all, there is no push, and the completion comment says so. Default chosen at design time.
- When the push is rejected because the remote has new commits, Claude runs `git pull --rebase --autostash` and then `git push` once more. If the rebase hits a conflict, Claude runs `git rebase --abort` and asks how to proceed; a second rejection also leads to a question. Default chosen at design time.
- When the project is not a git repository, there is no commit and no push, and the completion comment says so. Default chosen at design time.
- An authentication or network failure is reported to the user. Claude does not change remotes or credentials. Default chosen at design time.
- A ticket chat started by a bundle chat does not push; the bundle chat pushes once after the last ticket ([Bundles](#bundles)).
- Pushing `main` of HephaestusV2 starts the [self-update loop](#self-update-loop).

## Completion comment

After the push, or after the step that ended the run, Claude posts one comment with `add_comment`:

```markdown
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
```

- `<short hash>` is the output of `git rev-parse --short HEAD` after the commit.
- Without a commit, the first line is `Not committed: <reason>.`, for example `Not committed: the project is not a git repository.`. When the commit was not pushed, the first line ends with ` (not pushed: <reason>)`; a ticket chat started by a bundle chat ends it with ` (not pushed: the bundle chat pushes at the end)` ([Bundles](#bundles)).
- When the docs already described the behaviour, the Docs part reads `- No change: <link> already describes the expected behaviour.`.
- When no build or test command exists, the Checks part reads `- None: no build or test command found.`.
- The Testing part has one line per bullet of the ticket's Testing section, in the same order, with its result: `passed`, `failed` or `waiting for the user`. When the ticket has no Testing section, it reads `- None: the ticket has no Testing section.`.
- Claude posts the comment before it ends its turn, so the comment exists before an update can restart the app.

The format of this comment is a default. Default chosen at design time.

## Bundles

- A bundle chat starts with Implement All, whose first message is `implement-bundle.md`, or with `implement_bundle`. The bundle prompt contains every ticket of the bundle; `get_bundle` and `get_ticket` give the current state.
- The bundle chat is the orchestrator: it does not implement the tickets itself. It takes the tickets in bundle order (the order of `tickets`) and skips the `done` ones. Default chosen at design time.
- For each ticket, the orchestrator calls `implement_ticket` and ends its turn. The engine starts an orchestrated ticket chat linked to it ([Orchestrated ticket chats](chats.md#orchestrated-ticket-chats)), whose first message is `implement-bundle-ticket.md`. The orchestrator starts the next ticket's chat only after the previous one has reported back, so one ticket chat runs at a time.
- The ticket chat runs steps 1 to 8 of the [implementation workflow](#implementation-workflow) for its ticket, with its own commit, completion comment and status, but does not push: the first line of its completion comment ends with ` (not pushed: the bundle chat pushes at the end)`. It asks its questions and permission prompts in its own chat, where the user answers them. A ticket that needs no change, because an earlier commit of the bundle already covers it, gets no commit; its completion comment names that commit. Default chosen at design time.
- When a ticket chat's turn ends and it does not wait for answers, the engine sends the orchestrator the chat's final reply, or tells it that the chat ended in error or was stopped. After an error or a stop, the orchestrator asks the user with `ask_questions` whether to retry the ticket, skip it or stop; a retry starts a new ticket chat.
- When the user decides to skip a ticket, the orchestrator sets it back to `todo`, comments why, and continues with the next ticket. Default chosen at design time.
- After every ticket has been implemented or skipped, the orchestrator pushes once, so the bundle starts a single CI run. The result is one commit per ticket, in bundle order, each with that ticket's id.
- The orchestrator's final reply lists each ticket with its commit hash, or with `skipped` and the reason. It never sets a ticket to `done`. Default chosen at design time.
- The bundle has its own status ([Bundle status rules](tickets.md#bundle-status-rules)): Implement All and `implement_bundle` set it to `in_progress`, and only the user sets it to `done`, even when every ticket is done. Claude may set it to `todo` or `in_progress` with `set_bundle_status`, never to `done`, and never changes a `done` bundle. Each ticket chat sets its ticket to `done` or `review` as [Ticket status](#ticket-status) says.

## Project and feedback chats

- In a project chat Claude plans and works freely. It creates, updates and deletes tickets and bundles, comments, creates and updates projects, runs builds, tests and runs, and edits skills, always following [Never invent](#never-invent), [Writing tickets](#writing-tickets) and [Ticket status](#ticket-status).
- To implement tickets from a project chat, Claude calls `implement_ticket` or `implement_bundle`, which start dedicated chats. It implements in the project chat itself only when the user asks for that, and then follows the implementation workflow there. Default chosen at design time.
- In a feedback chat ([Feedback](feedback.md)), Claude works out what the feedback means from the comment, the screenshot and the context, asking questions when it is unclear. It then calls `create_ticket` in the feedback project with the template and the screenshot path as an attachment, and summarizes the ticket.
- Claude implements the new ticket in the feedback chat only when the user asks, and then follows the implementation workflow. Default chosen at design time.
- Claude closes the chat it runs in with `close_chat` when the user asks for it, and when the work of the chat is finished: in a ticket chat once it has set the ticket to `done`, in a bundle chat once every ticket has been implemented or skipped and the push is done, in a feedback chat once it has created the ticket. It closes a project chat only when the user asks. After the call it finishes its reply; the chat closes when the turn ends, and the user can reopen it ([Chats](chats.md#closing-a-chat)).

## SF Symbols

When Claude names an SF Symbol in a reply or in `ask_questions`, it writes it as `![](sf:<name>)`, for example `![](sf:line.3.horizontal.decrease.circle)`. The chat transcript and the pinned questions card show such a marker as the symbol's icon followed by its name ([Chats](chats.md#links-images-and-files)); ticket descriptions, comments and docs do not draw it.

When Claude needs the user to choose an SF Symbol, it asks with `ask_symbol` ([Symbol requests](#symbol-requests)).

## Self-update loop

When the project is HephaestusV2 itself (the registered project whose git remote is the app's release repository, Info.plist key `HephaestusReleaseRepository`), a pushed change reaches the running app without manual steps:

| Step | Who                           | What                                                                                                                                                                                                                                                            | Specification                                                       |
| ---- | ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| 1    | User                          | Sends feedback with the ladybug, or creates or opens a ticket of the HephaestusV2 project.                                                                                                                                                                      | [Feedback](feedback.md), [Tickets and bundles](tickets.md)          |
| 2    | Claude, feedback chat         | Clarifies with questions and creates the ticket: `todo`, named by Haiku, screenshot attached.                                                                                                                                                                   | [Feedback](feedback.md)                                             |
| 3    | User                          | Clicks Implement, or Implement All on a bundle.                                                                                                                                                                                                                 | [Ticket chats and Implement](tickets.md#ticket-chats-and-implement) |
| 4    | Claude, ticket chat           | Sets `in_progress`, updates the docs, updates the code to match, builds and tests, commits, pushes to `main`, comments and sets `done` or `review`. In a bundle, the ticket chats commit without pushing and the bundle chat pushes once after the last ticket. | [Implementation workflow](#implementation-workflow)                 |
| 5    | GitHub Actions, `release.yml` | Checks for personal data and checks the docs, runs `swift test`, computes the version, builds and signs the app, and publishes the release `v<version>` with `HephaestusV2.zip` and `release.json`.                                                             | [CI](ci.md)                                                         |
| 6    | Updater                       | Finds the release (10 s after launch, every `updateCheckIntervalMinutes`, or on Check Now), downloads and verifies it, and reports it ready.                                                                                                                    | [Updater](updater.md)                                               |
| 7    | App                           | Restarts on the new version as soon as no chat is working, Claude's background work included, and no editor is unsaved, or at once with Restart Now.                                                                                                            | [Updater](updater.md)                                               |
| 8    | User                          | Checks the change and sets a `review` ticket to Done.                                                                                                                                                                                                           | [Status rules](tickets.md#status-rules)                             |

- The loop needs a release build (build number above 0) with `autoUpdate` on, `HEPHAESTUS_DISABLE_UPDATER` not set and a writable app folder. With `autoUpdate` off, step 7 happens from the About window's Install button.
- The commit must be pushed to `main` of the release repository.
- A failing pipeline publishes no release. The running version stays, and the failure shows on the repository's Actions page.
- Claude does not wait for the pipeline: it ends its turn after the completion comment and the status change. Default chosen at design time.
- The restart stops the Claude processes. Transcripts are kept, and the next message of a chat resumes its Claude session ([Chats](chats.md)).
- Docs changed and pushed without a ticket are not turned into code automatically. A ticket that lists the changed sections under Docs starts the loop. Default chosen at design time.

## Engine-enforced rules

| Rule                                                                              | Checked by                             | Failure           |
| --------------------------------------------------------------------------------- | -------------------------------------- | ----------------- |
| Descriptions written by Claude follow the template                                | `tickets.create`, `tickets.update`     | `invalid`         |
| New tickets start as `todo`                                                       | `tickets.create` (no status parameter) | none              |
| Tickets created without a title are named by Haiku                                | `tickets.create`                       | none              |
| Claude never changes the status of a `done` ticket                                | `tickets.setStatus`                    | `forbidden`       |
| Questions are labelled in order, with 2 to 10 options and exactly one recommended | `chats.postQuestions`                  | `invalid`         |
| A chat has at most one waiting question set or symbol request                     | `chats.postQuestions`                  | `conflict`        |
| Symbol requests have 2 to 10 distinct SF Symbol names, one recommended            | `chats.postSymbol`                     | `invalid`         |
| A symbol request is refused while a question set or symbol request waits          | `chats.postSymbol`                     | `conflict`        |
| `ask_questions` and `ask_symbol` need a chat token                                | MCP server                             | see [MCP](mcp.md) |
| `close_chat` needs a chat token and closes only the calling chat                  | MCP server, `chats.close`              | see [MCP](mcp.md) |
| A `done` ticket is not implemented                                                | `chats.implementTicket`                | `conflict`        |
| A bundle is implemented only when one of its tickets is not `done`                | `chats.implementBundle`                | `conflict`        |
| A bundle is implemented only when its status is `todo`                            | `chats.implementBundle`                | `conflict`        |
| Claude never sets a bundle to `done` and never changes a `done` bundle            | `bundles.setStatus`                    | `forbidden`       |

The engine does not check the other rules (never invent, docs first, build and test, the tests that allow `done`, commits, pushing and the completion comment); only the prompts carry them. A ticket file that Claude edits with its own file tools reaches the engine as an external change with the actor `system` ([Data model](data-model.md#external-changes)); the template and status rules are not applied to it. Only the prompt rule `Never create, edit or delete files inside a .hephaestus folder yourself` prevents it. The error messages of the ticket rules are in [Errors](tickets.md#errors).

## Worked example

The project in this example is illustrative: identifier `DEMO`, an HTTP service with a `docs/` folder and a Makefile.

1. In the project chat the user writes: `GET /health answers 500 when the database is down. Make a ticket.`
2. Claude reads the handler and the docs. The healthy answer is 200 OK with the plain-text body `ok`; nothing defines the answer when the database is down. Claude calls `ask_questions`:

```json
{
  "questions": [
    {
      "label": "A",
      "question": "Which HTTP status must GET /health answer when the database is unreachable?",
      "options": [
        {"label": "503 Service Unavailable", "description": "Callers see that the service cannot work without its database."},
        {"label": "200 OK", "description": "Callers see no difference from a healthy instance."}
      ],
      "recommended": "503 Service Unavailable"
    },
    {
      "label": "B",
      "question": "Which body must that answer have?",
      "options": [
        {"label": "down", "description": "Plain text, like the healthy body ok."},
        {"label": "The database error message", "description": "Shows internal details to every caller."}
      ],
      "recommended": "down"
    }
  ]
}
```

3. The user keeps the recommended answer for A and types `down, and log the database error` for B. The engine sends:

```text
Answers:
A: 503 Service Unavailable
B: down, and log the database error
```

4. Claude calls `create_ticket` with `projectID` `DEMO` and this description:

```text
Problem
GET /health answers 500 Internal Server Error with an empty body when the database is unreachable; no answer is defined for this case.

Current Behavior
1. Stop the database.
2. Call GET /health.
3. The service answers 500 Internal Server Error with an empty body.

Expected
When the database is unreachable, GET /health answers 503 Service Unavailable with the plain-text body down and writes the database error to the service log. When the database is reachable, it keeps answering 200 OK with the body ok.

Change
Document both answers of GET /health in a new Health section of docs/http.md, then make the health handler check the database connection and answer from the result.

Testing
- Claude: make test passes, with a test of each answer of GET /health.
- User: stop the database and check that GET /health answers 503 with the body down.

Docs
- [http.md › Health](docs/http.md#health) (new)
```

5. The engine creates `DEMO-7` with status `todo` and the provisional title `GET /health answers 500 Internal Server Error with an empty`, which Haiku replaces before `create_ticket` returns. Claude tells the user the id.
6. The user clicks Implement on `DEMO-7`. In the new ticket chat, Claude sets `in_progress`, reads the ticket and `docs/http.md`, writes the Health section, changes the handler and its tests, runs `make build` and `make test`, commits `fix: answer 503 from /health when the database is down (DEMO-7)`, pushes, and comments:

```markdown
Implemented in `4f9c2ab`: fix: answer 503 from /health when the database is down (DEMO-7)

Docs
- [http.md › Health](docs/http.md#health): new section with the 200 and 503 answers.

Code
- internal/http/health.go: the handler checks the database connection; when it fails it answers 503 with the body down and logs the error.
- internal/http/health_test.go: tests for both answers.

Checks
- make build: passed
- make test: passed

Testing
- Claude: make test passes, with a test of each answer of GET /health: passed
- User: stop the database and check that GET /health answers 503 with the body down: waiting for the user

Notes
- None
```

7. The User test is still waiting, so Claude sets `DEMO-7` to `review`. Its final reply summarizes the change and asks the user to review `DEMO-7` and set it to Done. The ticket stays `review` until the user does.

## Requirements covered

- R32: A bundle implements all its tickets at once through a chat section.
- R34: In a project chat, Claude plans things and creates multiple items.
- R40: In a project chat, Claude does anything else the user wants.
- R82: Claude updates the docs according to the requested change.
- R83: Claude regenerates the code from the updated docs, then the docs and the code are committed and pushed.
- R84: GitHub CI then rebuilds the app.
- R87: When Claude starts working on a ticket, its status changes to in progress.
- R88 (partly): Claude marks a ticket done only when every test of its Testing section has passed; otherwise the user does.
- R89: Claude implements a ticket by first changing the docs.
- R90: Claude then updates the code to match the docs.
- R91: Claude then commits with a message of the form `<type>: <summary>`, the type being fix, feat and so on.
- R92: Claude then pushes.
- R93: When working on a ticket, Claude never invents anything.
- R94: Claude asks about unknown things with labelled questions: A, B and so on.
- R96: Claude always gives several ways to answer each question.
- R98: The user can answer however they want.
- R100: Under Problem, Current Behavior, Expected and Change, Claude explains the problem, the current behaviour, the expected behaviour and what should change.
- R101: Under Docs, Claude lists all docs files and paragraphs relevant to the issue.
- R108: The user moves between the questions of a set, answers them in any order and can change an answer until every question has one.
- R109: The user can skip a question; Claude then leaves that point out and mentions it in its reply.
- R110: A bundle has a status: todo, in progress or done; Implement All sets it to in progress and is disabled until the user sets it back to To Do.
- R111: Implement All runs one ticket chat per ticket, one at a time, coordinated by the bundle chat that started them, and pushes once at the end.
- R113: Claude can close the chat it runs in when the user asks or its work is finished; a closed chat shows `This conversation is over` in place of its composer until the user reopens it.
- R114: Claude marks each SF Symbol it names, and the chat transcript and the pinned questions card show the marker as the symbol's icon followed by its name.
- R117: Claude asks the user to choose an SF Symbol with `ask_symbol`: suggestions show as icons, any SF Symbol of the Mac can be searched, the user picks one, answers another way or skips.
