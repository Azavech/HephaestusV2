# Claude workflow

This is the operating manual Claude follows in every HephaestusV2 chat. Claude never invents: it asks the true unknowns with labelled questions, each with a recommended answer, and decides a point with an evident answer without asking; a chat started to implement a ticket asks nothing until the user writes in it and notes the choices it makes itself. It writes tickets with the description template and respects the status rules. It implements a ticket by changing the docs first and then the code to match them; it then builds and tests, commits with a conventional commit message, pushes, comments on the ticket and sets its status. A bundle chat orchestrates a bundle: it starts at once a ticket chat for every ticket that waits for no other ticket, each running that workflow on its own branch without pushing, then merges the branches into the main branch, builds and tests it, and pushes once at the end. In a project with a GitHub page, the ticket or bundle chat that pushed then starts a CI chat, which follows CI and reports back; it asks the user how to proceed when CI fails, and finishes only once CI is green or the user decides so ([Waiting for CI](#waiting-for-ci)). In a Go service project, the chat that pushed waits for CI to pass, then tests the tickets on a test service and sets them done ([Go service projects](#go-service-projects)). On the HephaestusV2 project itself, the push starts the self-update loop, which ends with the app restarting on the new version. The rules reach Claude through the [internal skills](skills.md#internal-skills), which the user edits in the HephaestusV2 project: HephaestusV2 puts the system prompt skills in the system prompts of [Chats](chats.md), and Claude calls the others. The engine enforces the rules it can check. The user-facing behaviour of tickets and bundles is in [Tickets and bundles](tickets.md); both documents state the same rules.

## Where the rules apply

| Chat kind        | Started by                                                                                                                                                   | System prompt skills | What this workflow adds                                                                                                                                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `project`        | New Chat (⌥⌘N), the project chat panel or the Chats section                                                                                                  | `common`, `project`  | Free-form work; tickets are written with the template                                                                                                                                                                                                                       |
| `ticket`         | Implement, New Chat in a ticket's Chats tab, `implement_ticket`                                                                                              | `common`, `ticket`   | Implement runs the [implementation workflow](#implementation-workflow) in an [implement chat](#implement-chats), which asks no question until the user writes in it; a ticket chat started by a bundle chat commits on its own branch without pushing ([Bundles](#bundles)) |
| `bundle`         | Implement All, New Chat in a bundle's Chats tab, `implement_bundle`                                                                                          | `common`, `bundle`   | Implement All runs the [bundle workflow](#bundles): the chat orchestrates ticket chats that run in parallel, then merges their branches                                                                                                                                     |
| `feedback`       | The ladybug ([Feedback](feedback.md))                                                                                                                        | `common`             | The first message calls the skill `feedback`, which describes the feedback chat: clarify the feedback, then create its ticket                                                                                                                                               |
| `ci`             | `watch_ci`, called by the chat that pushed an implementation ([Waiting for CI](#waiting-for-ci))                                                             | `ci`                 | Wait for the CI runs of the pushed commit and report the result; change no file, commit nothing and ask nothing                                                                                                                                                             |
| External session | A terminal Claude session using the external MCP token ([MCP](mcp.md))                                                                                       | none                 | Only the [engine-enforced rules](#engine-enforced-rules); no `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font`, `ask_animation` or `show_image`                                                                                           |
| Comment answer   | A new comment of the user that mentions `@Claude` ([Tickets](tickets.md#mentioning-claude)); a one-shot call, not a chat ([Chats](chats.md#comment-answers)) | `comment-answer`     | Answer the comment; change only the title, description, links and status of its ticket, never docs, code, other tickets, comments or attachments; questions go in the answer comment as [plain-text questions](#plain-text-questions)                                       |

- The system prompt skills are [internal skills](skills.md#system-prompt-skills) that the user edits in the [Internal Skills view](skills.md#internal-skills-view) (View ▸ Internal Skills), outside any project, with Restore Default; HephaestusV2 reads them at every launch of a chat and at every call ([Composition and rendering](chats.md#composition-and-rendering)), and their default text is in [Skills](skills.md#default-skillmd-files). The common skill states the rules of this document in imperative form, except those of [Implementation workflow](#implementation-workflow), [Completion comment](#completion-comment), [Waiting for CI](#waiting-for-ci), [Bundles](#bundles) and [Go service projects](#go-service-projects) and the description and the steps of a feedback chat of [Project and feedback chats](#project-and-feedback-chats).
- These rules reach Claude through the [internal skills](skills.md#internal-skills) `implement-ticket`, `implement-bundle`, `finish-implementation` and `feedback`, which the user can edit in the Internal Skills view, outside any project. The first message of Implement, `implement_ticket`, Implement All, `implement_bundle` and feedback calls one of them, and the common skill tells Claude to use `implement-ticket` whenever it implements a ticket and `implement-bundle` whenever it implements a bundle, in any chat. The text of this document describes the default content of the internal skills.
- A comment answer gets the comment-answer skill alone: the rules of this document that apply to it, [Never invent](#never-invent), the template of [Writing tickets](#writing-tickets), [Ticket status](#ticket-status), [Plain-text questions](#plain-text-questions) and the markers of [SF Symbols](#sf-symbols), [Colors](#colors), [Sounds](#sounds), [Keyboard shortcuts](#keyboard-shortcuts), [Fonts](#fonts) and [Animations](#animations), are stated there, and it implements nothing, commits nothing and asks nothing with `ask_questions` ([Default: comment-answer](skills.md#default-comment-answer)).
- A CI chat gets the ci skill alone: it follows the CI runs of one commit and reports the result to the chat that started it, and the other rules of this document do not apply to it ([Waiting for CI](#waiting-for-ci), [Default: ci](skills.md#default-ci)). Default chosen at design time.
- Claude CLI also reads the project's own `CLAUDE.md` from the project root. The `CLAUDE.md` of the HephaestusV2 repository links to this document. Default chosen at design time.
- An explicit instruction from the user in the chat replaces a step of this workflow, for example "do not push". The engine-enforced rules cannot be replaced: when an instruction conflicts with one of them, Claude tells the user that the user has to do it. Default chosen at design time.

### Implement chats

- An implement chat is a chat of kind `ticket` created by `chats.implementTicket`: from Implement in a ticket's Chats tab, from `implement_ticket`, and every ticket chat that a bundle chat starts ([Bundles](#bundles)). A ticket chat opened with New Chat, and the project, bundle and feedback chats, ask as the rest of this document describes.
- Until the user writes in it, an implement chat never asks: it calls none of `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font` and `ask_animation`, and it writes no question in its reply. The one exception is the question it asks the user after a CI failure ([Waiting for CI](#waiting-for-ci)). When something the ticket needs is unknown, it makes the choice itself and notes it ([Never invent](#never-invent)); at the other points where a chat asks, it decides itself and states the decision under Notes of its completion comment: a build or tests that fail without its change ([Build and test](#build-and-test)), a project without a docs folder ([Docs first](#docs-first)), a breaking change it is unsure about and a file it must change that has uncommitted changes it did not make ([Commits](#commits)), a rebase conflict on push and a second rejected push ([Pushing](#pushing)). It still never commits changes it did not make.
- The engine enforces it: `chats.implementTicket` writes `questionsBlocked: true` in the metadata file of the chat it creates ([Data model](data-model.md#chat-metadata-file)), and while the key is set the seven tools fail with `forbidden` ([Asking](#asking)). Only the question after a CI failure passes: once the engine has sent the chat a report of its CI chat that is a CI failure, the chat's next question set is accepted ([Reports to the orchestrator](chats.md#reports-to-the-orchestrator)).
- The first message the user sends in the chat after its first message, which calls the skill `implement-ticket`, from any device, removes the key. From then on the chat asks as the other chats do, for example about a correction the user asks for.
- The ticket's status follows the usual rules ([Ticket status](#ticket-status)): the choices an implement chat made itself do not keep the ticket in `review`.
- The bundle chat that orchestrates a bundle is not an implement chat and still asks: whether to retry, skip or stop after a ticket chat ends in error or is stopped, how to proceed when main fails to build or test ([Bundles](#bundles)), and how to proceed when CI fails ([Waiting for CI](#waiting-for-ci)).

## App data through MCP

- Claude reads and changes HephaestusV2 data (projects, tickets, comments, bundles, chats, web tabs and skills) with the tools of the `hephaestus` MCP server, which Claude sees as `mcp__hephaestus__<tool>` ([MCP](mcp.md)). It never edits the files under `.hephaestus/` directly. Default chosen at design time.
- Every tool call goes through the engine, which validates it and sends the change to every window and remote device.
- To show the user an item, Claude calls `open_in_app` with a navigation target.
- `get_ticket` gives the absolute path on the main device of every attachment of a ticket and of its comments ([MCP](mcp.md#get_ticket)). Claude reads an attachment at that path and never searches the disk for it, for example with `find`, `grep` or `Glob` from `/` or `~`.

## Never invent

- Claude never invents a requirement, behaviour, name or value visible to users, text shown to users, file format or product decision. Everything of this kind that it builds comes from the user's messages, the ticket with its comments and attachments, the docs, or the existing code.
- Technical choices inside the code that change no documented behaviour are Claude's to make. Default chosen at design time.
- Before asking, Claude looks for the answer itself in the ticket, its comments and attachments, the docs, the code and the git history.
- Claude asks only true unknowns: points where several answers are reasonable and neither the user's messages, the ticket with its comments, the docs, the code nor the answers already given settle them.
- A point with one evident answer, one that follows from the user's request, the docs, the code or a decision already made, is not an unknown: Claude decides it without asking. A ticket that Claude writes states such a point as decided.
- The chat that writes a ticket settles every decision of its implementation before it creates the ticket, so that the chat that implements it needs no question ([Writing tickets](#writing-tickets)).
- Claude asks what is still unknown with the [questions protocol](#questions-protocol) before acting on it, then ends its turn and waits. It never continues on a guess to be confirmed later.
- Statements that contradict each other, such as a comment that contradicts the description, count as an unknown. Default chosen at design time.
- In comments and replies Claude reports only what it did and checked.
- These rules apply in the project, ticket, bundle and feedback chats and in comment answers; a CI chat gets `ci.md` alone ([Where the rules apply](#where-the-rules-apply)).
- The exception is an [implement chat](#implement-chats) that the user has not written in yet: it asks nothing. When something the ticket needs is unknown, Claude makes the choice itself, marks it with the sentence `Default chosen at design time.` in the docs it changes, and lists each choice under Notes of its completion comment ([Completion comment](#completion-comment)).

## Questions protocol

### Asking

- Claude asks only the true unknowns of [Never invent](#never-invent): a point with an evident answer gets no question.
- Claude asks with the MCP tool `ask_questions`. Its input `questions` is a list of `{label, question, kind?, options: [{label, description?}], recommended, minChoices?, maxChoices?}`, and its schema is in [MCP](mcp.md).
- Questions are labelled `A`, `B`, `C` and so on, in order, starting at `A` in every call. One call holds at most 26 questions.
- Each question asks for one decision and offers 2 to 10 options. An option's `label` is the answer text; its optional `description` is one line stating the consequence.
- A question has a `kind`: `single`, where the user chooses one option, or `multiple`, where the user checks every option that applies and can add own answers. A question without `kind` is `single`, so a question set written before `kind` existed reads unchanged. Claude gives a question the kind `multiple` when several of its options can apply at once.
- In a `single` question exactly one option is recommended: `recommended` is the label of one of the question's options. In a `multiple` question `recommended` is a list of one or more of its option labels, and the card checks all of them.
- A `multiple` question bounds the number of choices with `minChoices`, 1 when absent, and `maxChoices`, no maximum when absent. Each checked option and each own answer counts as one choice. Both are only accepted on a `multiple` question.
- Claude adds no "Other" option, because the UI always lets the user answer another way. Default chosen at design time.
- Claude puts every point that is unknown at that moment into one call. Default chosen at design time.
- The tool returns at once with the text `questions shown; answers arrive in the next user message; end your turn`. Claude then ends its turn: it calls no further tool.
- Claude does not repeat the questions in its reply text, because the chat shows them. Default chosen at design time.
- A chat has at most one waiting request: a question set without all its answers, a [symbol request](#symbol-requests) without answer, a [color request](#color-requests) without answer, a [sound request](#sound-requests) without answer, a [shortcut request](#shortcut-requests) without answer, a [font request](#font-requests) without answer, or an [animation request](#animation-requests) without answer. Calling `ask_questions` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`, while a color request waits with `conflict` and `A color request is already waiting for an answer in this chat.`, while a sound request waits with `conflict` and `A sound request is already waiting for an answer in this chat.`, while a shortcut request waits with `conflict` and `A shortcut request is already waiting for an answer in this chat.`, while a font request waits with `conflict` and `A font request is already waiting for an answer in this chat.`, and while an animation request waits with `conflict` and `An animation request is already waiting for an answer in this chat.`. The question-set rule and its message are Default chosen at design time.
- `ask_questions` works only with a chat's own token, never with the external token ([MCP](mcp.md)).
- In an [implement chat](#implement-chats), while its metadata holds `questionsBlocked`, except for the question set that follows a CI failure report ([Waiting for CI](#waiting-for-ci)), `ask_questions` fails with `forbidden` and `This chat implements a ticket and cannot ask questions: decide yourself and note the choice in the completion comment.`, right after the check of the token and before the other checks (Default chosen at design time), and nothing is shown to the user. `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font` and `ask_animation` fail the same way, with the same message. Claude then makes the choice itself ([Never invent](#never-invent)) and does not report the refusal to the user.

### Validation

`chats.postQuestions` checks the input. Every failure is `invalid` with the message below, and nothing is shown to the user.

| Rule                                                                                                                                           | Message                                                                                   |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 1 to 26 questions                                                                                                                              | `ask_questions needs 1 to 26 questions.`                                                  |
| Labels are `A`, `B`, `C` and so on, in order                                                                                                   | `Question <n> must have the label "<letter>".`                                            |
| `question` is not empty after trimming                                                                                                         | `Question <label> has no text.`                                                           |
| 2 to 10 options                                                                                                                                | `Question <label> needs 2 to 10 options.`                                                 |
| Option labels are not empty after trimming and are unique within the question, ignoring case                                                   | `Question <label> has an empty or repeated option label.`                                 |
| Option labels are one line of at most 200 characters                                                                                           | `Question <label> has an option label longer than 200 characters or on several lines.`    |
| `minChoices` and `maxChoices` appear only on a question whose `kind` is `multiple`                                                             | `Question <label>: minChoices and maxChoices need kind "multiple".`                       |
| A `single` question: `recommended` is one label, or a list of one label, equal to the label of one of the question's options                   | `Question <label>: the recommended answer must be one of its option labels.`              |
| A `multiple` question: `recommended` is one label or a list of labels, at least one, distinct, each the label of one of the question's options | `Question <label>: the recommended answers must be distinct option labels, at least one.` |
| `minChoices` and `maxChoices` are at least 1                                                                                                   | `Question <label>: minChoices and maxChoices must be at least 1.`                         |
| `minChoices`, 1 when absent, is at most `maxChoices`                                                                                           | `Question <label>: minChoices must be at most maxChoices.`                                |
| The number of recommended labels is at most `maxChoices`                                                                                       | `Question <label> recommends more options than maxChoices.`                               |

`kind` is `single` or `multiple`; the input schema of `ask_questions` refuses another value ([MCP](mcp.md#ask_questions)).

The label, text and option-label checks, the maximum of 10 options and all messages are defaults; the rules of at least two options and exactly one recommended option of a `single` question come from the design, and so do `kind`, `minChoices`, `maxChoices` and the rules that bind them. Reading a lone label as a list of one label in a `multiple` question, and a list of one label as that label in a `single` question, is a default. Default chosen at design time.

### Answering

- The questions appear in the chat as a card above the composer, one at a time, with a header such as `Question B (2 of 3)` and arrows that move between the questions of the set. The card lists the options, with the recommended one marked `Recommended` and preselected, plus a free-text field `Answer another way`, a Skip button and a main button that reads `Submit` when every other question of the set has an answer, so that answering the displayed question sends the answers to Claude, and `Next` otherwise. The card can be minimized into a one-line bar ([Chats](chats.md#pinned-questions-card)).
- The user answers the questions one by one, in any order, from any window or device. Each Submit or Next stores one answer with `chats.answerQuestion` (`questionSetID`, `label`, `answer`); answering an answered question again replaces its answer while the set is not completed. Skip stores the answer `Skipped`. The chat's state is `waitingAnswers` while the set is not completed.
- The stored answer is the label of the chosen option, or the free text as typed, trimmed. Default chosen at design time.
- A `multiple` question shows a checkbox in place of each radio button, its recommended options checked, the number of choices to make under the question, and under `Answer another way` one-line text fields, a new empty field appearing below the last one as soon as it gets text. Submit or Next is enabled while the number of choices, checked options and filled fields together, is between `minChoices` and `maxChoices` ([Chats](chats.md#pinned-questions-card)).
- The stored answer of a `multiple` question is one line `- <choice>` per choice, lines separated by `\n`: the labels of the checked options in option order, then the texts of the filled fields, trimmed, in field order. Skip stores `Skipped`. Default chosen at design time.

### Answers message

When the last question of a set is answered, the engine marks the set `completed` and sends Claude one user message:

```text
Answers:
A: <answer>
B: <answer>
```

- The message has one line per question, in label order, in the form `<label>: <answer>`. Line breaks inside a free-text answer are kept. Default chosen at design time.
- An answered `multiple` question reads `<label>:` followed by one line per choice, each starting with `- `: the checked option labels in option order, then the user's texts in field order. A skipped `multiple` question reads `<label>: Skipped`. For example:

```text
Answers:
A:
- Option 1
- My own text
B: Skipped
```
- A skipped question reads `<label>: Skipped`. Claude leaves that point out: it does not act on it or guess, and it mentions it in its reply.
- Answers are decisions: Claude applies them and does not ask them again. An answer that raises a new unknown leads to a new question set, labelled from `A` again.

### Plain-text questions

In an external session and in a comment answer, where `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font` and `ask_animation` are not available, Claude writes the questions in its reply in this form and ends its turn; a symbol choice becomes a question whose options are the symbol names, a color choice a question whose options are the color values, a light and dark pair being written `Light <color>, Dark <color>`, a sound choice a question whose options are the sound names, a shortcut choice a question whose options are the shortcuts, a font choice a question whose options are the fonts, written in the [font notation](chats.md#font-notation), and an animation choice a question whose options are the animation expressions:

```text
A: <question>
   1. <option> (recommended)
   2. <option>
B: <question>
   1. <option>
   2. <option> (recommended)
```

The user answers with one `<label>: <answer>` line per question. Default chosen at design time.

In a comment answer, the reply is Claude's answer comment, and the questions end it; the user answers with a new comment that mentions `@Claude`, holding the `<label>: <answer>` lines, which starts a new call ([Comment answers](tickets.md#comment-answers)). The rules of [Answers message](#answers-message) apply to those lines.

### Symbol requests

When Claude needs the user to choose an SF Symbol, it asks with the MCP tool `ask_symbol` instead of listing symbol names as options of `ask_questions` ([MCP](mcp.md#ask_symbol)).

- One call asks for one symbol. Its inputs are `question`, the question; `suggestions`, 2 to 10 SF Symbol names; and `recommended`, the suggestion Claude recommends.
- The tool returns at once with the text `symbol request shown; the answer arrives in the next user message; end your turn`. Claude then ends its turn: it calls no further tool, and it does not repeat the question in its reply.
- A chat has at most one waiting request ([Asking](#asking)): calling `ask_symbol` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`, while a color request waits with `conflict` and `A color request is already waiting for an answer in this chat.`, while a sound request waits with `conflict` and `A sound request is already waiting for an answer in this chat.`, while a shortcut request waits with `conflict` and `A shortcut request is already waiting for an answer in this chat.`, while a font request waits with `conflict` and `A font request is already waiting for an answer in this chat.`, and while an animation request waits with `conflict` and `An animation request is already waiting for an answer in this chat.`.
- `ask_symbol` works only with a chat's own token, never with the external token ([MCP](mcp.md#ask_symbol)).
- In an [implement chat](#implement-chats), while its metadata holds `questionsBlocked`, `ask_symbol` fails with `forbidden` as `ask_questions` does ([Asking](#asking)).

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

### Color requests

When Claude needs the user to choose a color, it asks with the MCP tool `ask_color` instead of listing color values as options of `ask_questions` ([MCP](mcp.md#ask_color)).

- One call asks for one color, or for one light and dark pair. Its inputs are `question`, the question; `suggestions`, 2 to 10 suggestions; `recommended`, the suggestion Claude recommends; and `lightAndDark`, true to ask for a light and dark pair.
- A color is opaque, without opacity: a hex color `#RRGGBB` in sRGB, its six hex digits in either letter case, or a [system color name](chats.md#system-colors) such as `systemBlue`, `label` or `accentColor`.
- Claude sets `lightAndDark` when the destination of the color supports light and dark appearances, for example an asset catalog color set. Each suggestion and `recommended` are then pairs `{"light": "<color>", "dark": "<color>"}`; otherwise each is one color, a string.
- The tool returns at once with the text `color request shown; the answer arrives in the next user message; end your turn`. Claude then ends its turn: it calls no further tool, and it does not repeat the question in its reply.
- A chat has at most one waiting request ([Asking](#asking)): calling `ask_color` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`, while a color request waits with `conflict` and `A color request is already waiting for an answer in this chat.`, while a sound request waits with `conflict` and `A sound request is already waiting for an answer in this chat.`, while a shortcut request waits with `conflict` and `A shortcut request is already waiting for an answer in this chat.`, while a font request waits with `conflict` and `A font request is already waiting for an answer in this chat.`, and while an animation request waits with `conflict` and `An animation request is already waiting for an answer in this chat.`.
- `ask_color` works only with a chat's own token, never with the external token ([MCP](mcp.md#ask_color)).
- In an [implement chat](#implement-chats), while its metadata holds `questionsBlocked`, `ask_color` fails with `forbidden` as `ask_questions` does ([Asking](#asking)).

`chats.postColor` checks the input, after trimming each color of `suggestions` and `recommended`. Every failure is `invalid` with the message below, and nothing is shown to the user. The messages are Default chosen at design time.

| Rule                                                                                                    | Message                                                                               |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `question` is not empty after trimming                                                                  | `ask_color needs a question.`                                                         |
| 2 to 10 suggestions                                                                                     | `ask_color needs 2 to 10 suggestions.`                                                |
| Without `lightAndDark`, each suggestion and `recommended` are one color                                 | `ask_color needs one color per suggestion, or lightAndDark for light and dark pairs.` |
| With `lightAndDark`, each suggestion and `recommended` are a light and dark pair                        | `ask_color needs a light and dark pair per suggestion.`                               |
| Each color of the suggestions is a hex color `#RRGGBB` or a [system color name](chats.md#system-colors) | `<color> is not a hex color #RRGGBB or a system color name.`                          |
| Suggestions are distinct                                                                                | `ask_color has a repeated suggestion.`                                                |
| `recommended` equals one of the suggestions                                                             | `ask_color: the recommended color must be one of the suggestions.`                    |

- `lightAndDark` absent counts as false.
- The color check runs in the order of `suggestions`, the light color of a pair before its dark color, and names the first color that fails, as given.
- Two colors are equal when their hex digits are equal ignoring letter case, or when they are the same system color name; names are compared with their letter case. Two pairs are equal when their light colors are equal and their dark colors are equal.

The request appears in the chat as a pinned color card above the composer ([Chats](chats.md#pinned-color-card)): the suggestions as swatches, the recommended one marked and preselected, a grid of every system color, the macOS color panel and a hex field, a `Light and dark` toggle, a free-text field `Answer another way`, a Skip button and a Submit button. The user answers once with `chats.answerColor`, from any window or device; the chat's state is `waitingAnswers` until then. The engine then sends Claude one user message:

```text
Color: <answer>
```

- `<answer>` is `![](color:<color>)` for one color chosen in the card, for example `Color: ![](color:#FF9500)` or `Color: ![](color:systemBlue)`; `Light ![](color:<color>), Dark ![](color:<color>)` for a light and dark pair, for example `Color: Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)`; the text the user typed, trimmed, with its line breaks; or `Skipped` for a skipped request. A hex color chosen in the card is written in uppercase.
- The user chooses between one color and a pair with the card's `Light and dark` toggle, which starts as `lightAndDark` asked: the answer to a pair request can be one color, and the answer to a one-color request a pair.

### Sound requests

When Claude needs the user to choose a sound for an app of an Apple platform (iOS, macOS, watchOS, tvOS, visionOS), in a project whose type is Swift application ([Project types](projects.md#project-types)), it asks with the MCP tool `ask_sound` instead of listing sound names as options of `ask_questions` ([MCP](mcp.md#ask_sound)).

- One call asks for one sound. Its inputs are `question`, the question; `suggestions`, 2 to 10 sound names of the [sound catalogue](chats.md#sound-catalogue); and `recommended`, the suggestion Claude recommends.
- A sound name is `macOS/<file>` for a sound of `/System/Library/Sounds`, `<platform> <version>/<path>` for a sound of an installed Simulator runtime, for example `iOS 26.1/sms-received1.caf`, or `Project/<path from the project root>` for a sound file of the project ([Sound catalogue](chats.md#sound-catalogue)).
- `ask_sound` works only in a project of type Swift application: in a project of another type it fails with `forbidden` and `ask_sound is only available in Swift application projects.`, and nothing is shown to the user.
- The tool returns at once with the text `sound request shown; the answer arrives in the next user message; end your turn`. Claude then ends its turn: it calls no further tool, and it does not repeat the question in its reply.
- A chat has at most one waiting request ([Asking](#asking)): calling `ask_sound` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`, while a color request waits with `conflict` and `A color request is already waiting for an answer in this chat.`, while a sound request waits with `conflict` and `A sound request is already waiting for an answer in this chat.`, while a shortcut request waits with `conflict` and `A shortcut request is already waiting for an answer in this chat.`, while a font request waits with `conflict` and `A font request is already waiting for an answer in this chat.`, and while an animation request waits with `conflict` and `An animation request is already waiting for an answer in this chat.`.
- `ask_sound` works only with a chat's own token, never with the external token ([MCP](mcp.md#ask_sound)).
- In an [implement chat](#implement-chats), while its metadata holds `questionsBlocked`, `ask_sound` fails with `forbidden` as `ask_questions` does ([Asking](#asking)).

`chats.postSound` checks the project type, then the input, after trimming each suggestion and `recommended`. Every input failure is `invalid` with the message below, and nothing is shown to the user. The messages are Default chosen at design time.

| Rule                                                                                                                   | Message                                                            |
| ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `question` is not empty after trimming                                                                                 | `ask_sound needs a question.`                                      |
| 2 to 10 suggestions                                                                                                    | `ask_sound needs 2 to 10 suggestions.`                             |
| Suggestions are not empty and are distinct                                                                             | `ask_sound has an empty or repeated suggestion.`                   |
| Each suggestion is a name of the [sound catalogue](chats.md#sound-catalogue) of the main device for the chat's project | `<name> is not a sound of this Mac or of the project.`             |
| `recommended` equals one of the suggestions                                                                            | `ask_sound: the recommended sound must be one of the suggestions.` |

The suggestion check runs in the order of `suggestions` and names the first unknown suggestion.

The request appears in the chat as a pinned sound card above the composer ([Chats](chats.md#pinned-sound-card)): the suggestions in a list, the recommended one starred and preselected, a search over every sound of the catalogue, a free-text field `Answer another way`, a Skip button and a Submit button; selecting a row plays its sound. The user answers once with `chats.answerSound`, from any window or device; the chat's state is `waitingAnswers` until then. The engine then sends Claude one user message:

```text
Sound: <answer>
```

- `<answer>` is `![](sound:<name>)` for a sound chosen in the card, for example `Sound: ![](sound:iOS 26.1/sms-received1.caf)`; the text the user typed, trimmed, with its line breaks; or `Skipped` for a skipped request.
- A skipped request is handled like a skipped question: Claude leaves that point out, does not act on it or guess, and mentions it in its reply.
- The answer is a decision: Claude applies it and does not ask again.

### Shortcut requests

In a project whose [type](projects.md#project-types) is Swift application (`swiftApplication`), when Claude needs the user to choose a keyboard shortcut, it asks with the MCP tool `ask_shortcut` instead of listing shortcuts as options of `ask_questions` ([MCP](mcp.md#ask_shortcut)).

- One call asks for one shortcut. Its inputs are `question`, the question; `suggestions`, 2 to 10 shortcuts written in the [shortcut notation](chats.md#shortcut-notation), for example `⇧⌘K`; `recommended`, the suggestion Claude recommends; and `inUse`, every shortcut the app already uses, each with the name of its command, for example `⌘N` with `New Ticket`, or an empty array.
- The tool returns at once with the text `shortcut request shown; the answer arrives in the next user message; end your turn`. Claude then ends its turn: it calls no further tool, and it does not repeat the question in its reply.
- A chat has at most one waiting request ([Asking](#asking)): calling `ask_shortcut` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`, while a color request waits with `conflict` and `A color request is already waiting for an answer in this chat.`, while a sound request waits with `conflict` and `A sound request is already waiting for an answer in this chat.`, while a shortcut request waits with `conflict` and `A shortcut request is already waiting for an answer in this chat.`, while a font request waits with `conflict` and `A font request is already waiting for an answer in this chat.`, and while an animation request waits with `conflict` and `An animation request is already waiting for an answer in this chat.`.
- `ask_shortcut` works only with a chat's own token, never with the external token ([MCP](mcp.md#ask_shortcut)).
- In an [implement chat](#implement-chats), while its metadata holds `questionsBlocked`, `ask_shortcut` fails with `forbidden` as `ask_questions` does ([Asking](#asking)).
- In a project of another type, the call fails with `forbidden` and `ask_shortcut is available only in Swift application projects.`, and nothing is shown to the user. The code and the message are Default chosen at design time.

`chats.postShortcut` checks the project type, then the input, after trimming each suggestion, `recommended`, and each `shortcut` and `command` of `inUse`. Every failure of the input is `invalid` with the message below, and nothing is shown to the user. The checks run in this order; the suggestions and the entries of `inUse` are checked in their order, and the message names the first one that fails. The 500-entry limit, the command length and the messages are Default chosen at design time.

| Rule                                                                      | Message                                                                                          |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `question` is not empty after trimming                                    | `ask_shortcut needs a question.`                                                                 |
| 2 to 10 suggestions                                                       | `ask_shortcut needs 2 to 10 suggestions.`                                                        |
| Suggestions are not empty and are distinct                                | `ask_shortcut has an empty or repeated suggestion.`                                              |
| Each suggestion is in the [shortcut notation](chats.md#shortcut-notation) | `<shortcut> is not a shortcut in menu notation: the modifiers ⌃⌥⇧⌘ in this order, then one key.` |
| `recommended` equals one of the suggestions                               | `ask_shortcut: the recommended shortcut must be one of the suggestions.`                         |
| At most 500 entries in `inUse`                                            | `ask_shortcut accepts at most 500 inUse entries.`                                                |
| Each `shortcut` of `inUse` is in the shortcut notation                    | `<shortcut> is not a shortcut in menu notation: the modifiers ⌃⌥⇧⌘ in this order, then one key.` |
| Each `command` of `inUse` is one line of 1 to 200 characters              | `ask_shortcut: the command of <shortcut> in inUse must be one line of 1 to 200 characters.`      |
| No shortcut appears twice in `inUse`                                      | `ask_shortcut: <shortcut> appears twice in inUse.`                                               |

The request appears in the chat as a pinned shortcut card above the composer ([Chats](chats.md#pinned-shortcut-card)): the suggestions drawn as key caps, the recommended one marked and preselected, a recorder field `Record Shortcut`, the warnings `Used by macOS: <action>` and `Used by the app: <command>` for the selected shortcut, a free-text field `Answer another way`, a Skip button and a Submit button. The user answers once with `chats.answerShortcut`, from any window or device; the chat's state is `waitingAnswers` until then. The engine then sends Claude one user message:

```text
Shortcut: <answer>
```

- `<answer>` is `![](shortcut:<shortcut>)` for a shortcut chosen or recorded in the card, for example `Shortcut: ![](shortcut:⇧⌘K)`; the text the user typed, trimmed, with its line breaks; or `Skipped` for a skipped request.
- A shortcut that macOS or the app already uses can be the answer: the warnings do not block Submit.

### Font requests

When Claude needs the user to choose a font, it asks with the MCP tool `ask_font` instead of listing font names as options of `ask_questions` ([MCP](mcp.md#ask_font)).

- One call asks for one font. Its inputs are `question`, the question; `sample`, the sample text the card draws in the selected font, taken from where the font will be used; `suggestions`, 2 to 10 fonts; and `recommended`, the suggestion Claude recommends.
- A font is written in the [font notation](chats.md#font-notation): a Dynamic Type text style such as `.headline`, or `<family>/<weight>/<size>` such as `System Rounded/Semibold/17` or `Avenir Next/Demi Bold/15`.
- The tool returns at once with the text `font request shown; the answer arrives in the next user message; end your turn`. Claude then ends its turn: it calls no further tool, and it does not repeat the question in its reply.
- A chat has at most one waiting request ([Asking](#asking)): calling `ask_font` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`, while a color request waits with `conflict` and `A color request is already waiting for an answer in this chat.`, while a sound request waits with `conflict` and `A sound request is already waiting for an answer in this chat.`, while a shortcut request waits with `conflict` and `A shortcut request is already waiting for an answer in this chat.`, while a font request waits with `conflict` and `A font request is already waiting for an answer in this chat.`, and while an animation request waits with `conflict` and `An animation request is already waiting for an answer in this chat.`.
- `ask_font` works only with a chat's own token, never with the external token ([MCP](mcp.md#ask_font)).
- In an [implement chat](#implement-chats), while its metadata holds `questionsBlocked`, `ask_font` fails with `forbidden` as `ask_questions` does ([Asking](#asking)).

`chats.postFont` checks the input, after trimming `sample`, each suggestion and `recommended`. Every failure is `invalid` with the message below, and nothing is shown to the user. The messages are Default chosen at design time.

| Rule                                                                                                                                                           | Message                                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `question` is not empty after trimming                                                                                                                         | `ask_font needs a question.`                                                                                                  |
| `sample` is not empty after trimming                                                                                                                           | `ask_font needs a sample text.`                                                                                               |
| 2 to 10 suggestions                                                                                                                                            | `ask_font needs 2 to 10 suggestions.`                                                                                         |
| Suggestions are not empty and are distinct                                                                                                                     | `ask_font has an empty or repeated suggestion.`                                                                               |
| Each suggestion is a text style or has three parts separated by `/` ([Font notation](chats.md#font-notation))                                                  | `<font> is not a font: write a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17.` |
| The size of each family font is 1 to 999 points with at most one decimal                                                                                       | `<font>: the size must be 1 to 999 pt, with at most one decimal.`                                                             |
| The family of each family font is a family of the [font catalogue](chats.md#font-catalogue) of the main device, and its weight is one of that family's weights | `<font> is not a font of this Mac.`                                                                                           |
| `recommended` equals one of the suggestions                                                                                                                    | `ask_font: the recommended font must be one of the suggestions.`                                                              |

The suggestion checks run in the order of `suggestions`, each suggestion through the notation, size and catalogue rules in turn, and name the first suggestion that fails.

The request appears in the chat as a pinned font card above the composer ([Chats](chats.md#pinned-font-card)): the suggestions drawn in their fonts, the recommended one marked and preselected, a search over every font of the catalogue, a `Weight` menu and a `Size` field, the sample drawn in the selected font, a free-text field `Answer another way`, a Skip button and a Submit button. The user answers once with `chats.answerFont`, from any window or device; the chat's state is `waitingAnswers` until then. The engine then sends Claude one user message:

```text
Font: <answer>
```

- `<answer>` is `![](font:<font>)` for a font chosen in the card, for example `Font: ![](font:System Rounded/Semibold/17)` or `Font: ![](font:.headline)`; the text the user typed, trimmed, with its line breaks; or `Skipped` for a skipped request.
- A skipped request is handled like a skipped question: Claude leaves that point out, does not act on it or guess, and mentions it in its reply.
- The answer is a decision: Claude applies it and does not ask again.

### Animation requests

In a project whose [type](projects.md#project-types) is Swift application (`swiftApplication`), when Claude needs the user to choose an animation, it asks with the MCP tool `ask_animation` instead of listing animation expressions as options of `ask_questions` ([MCP](mcp.md#ask_animation)).

- One call asks for one animation. Its inputs are `question`, the question; `suggestions`, 2 to 10 animations, each written as its SwiftUI expression ([Animation expressions](#animation-expressions)); and `recommended`, the suggestion Claude recommends.
- The tool returns at once with the text `animation request shown; the answer arrives in the next user message; end your turn`. Claude then ends its turn: it calls no further tool, and it does not repeat the question in its reply.
- A chat has at most one waiting request ([Asking](#asking)): calling `ask_animation` while a question set waits fails with `conflict` and `Questions are already waiting for answers in this chat.`, while a symbol request waits with `conflict` and `A symbol request is already waiting for an answer in this chat.`, while a color request waits with `conflict` and `A color request is already waiting for an answer in this chat.`, while a sound request waits with `conflict` and `A sound request is already waiting for an answer in this chat.`, while a shortcut request waits with `conflict` and `A shortcut request is already waiting for an answer in this chat.`, while a font request waits with `conflict` and `A font request is already waiting for an answer in this chat.`, and while an animation request waits with `conflict` and `An animation request is already waiting for an answer in this chat.`.
- `ask_animation` works only with a chat's own token, never with the external token ([MCP](mcp.md#ask_animation)).
- In an [implement chat](#implement-chats), while its metadata holds `questionsBlocked`, `ask_animation` fails with `forbidden` as `ask_questions` does ([Asking](#asking)).
- In a project of another type, the call fails with `forbidden` and `ask_animation is available only in Swift application projects.`, and nothing is shown to the user. The code and the message are Default chosen at design time.

#### Animation expressions

An animation is a SwiftUI preset written as its SwiftUI expression: `.` and the preset's name, alone or followed by its parameters in parentheses, for example `.spring`, `.snappy(duration: 0.3, extraBounce: 0.1)`, `.spring(duration: 0.4, bounce: 0.2)` or `.easeInOut(duration: 0.25)`.

| Presets                                        | Parameters, in this order | SwiftUI's defaults              |
| ---------------------------------------------- | ------------------------- | ------------------------------- |
| `.smooth`, `.snappy`, `.bouncy`                | `duration`, `extraBounce` | `duration` 0.5, `extraBounce` 0 |
| `.spring`                                      | `duration`, `bounce`      | `duration` 0.5, `bounce` 0      |
| `.easeIn`, `.easeOut`, `.easeInOut`, `.linear` | `duration`                | `duration` 0.35                 |

| Parameter     | Range                   | Unit    |
| ------------- | ----------------------- | ------- |
| `duration`    | 0.1 to 2, both included | seconds |
| `bounce`      | -1 to 1, both included  | none    |
| `extraBounce` | 0 to 1, both included   | none    |

- The parameters are written `<label>: <number>` and separated by `,`, as in Swift. A parameter that is left out takes SwiftUI's default, so `.spring` and `.spring(duration: 0.5, bounce: 0)` move alike; the parameters that are written keep the order of the table, each at most once, and `()` without a parameter is refused. Writing only some parameters is Default chosen at design time.
- A number is an optional `-`, one or more digits, and optionally `.` followed by one or more digits, for example `0.4`, `1` or `-0.25`.
- Spaces may follow `(`, `:` and `,` and precede `)`, `:` and `,`; no other white space is allowed, and line breaks never are. Default chosen at design time.
- The ranges are those of the sliders of the Custom row ([Chats](chats.md#pinned-animation-card)).

#### Animation validation

`chats.postAnimation` checks the input, after trimming each suggestion and `recommended`, in the order of this table; the suggestion checks run on each suggestion in the order of `suggestions`, all checks on one suggestion before the next, and name the first suggestion that fails. Every failure is `invalid` with the message below, and nothing is shown to the user. The messages are Default chosen at design time.

| Rule                                                                                                                                               | Message                                                                                                  |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `question` is not empty after trimming                                                                                                             | `ask_animation needs a question.`                                                                        |
| 2 to 10 suggestions                                                                                                                                | `ask_animation needs 2 to 10 suggestions.`                                                               |
| Suggestions are not empty and are distinct                                                                                                         | `ask_animation has an empty or repeated suggestion.`                                                     |
| The suggestion is `.`, a name of letters, and optionally parameters in parentheses, as [Animation expressions](#animation-expressions) writes them | `<suggestion> is not a SwiftUI animation expression.`                                                    |
| The name is a preset                                                                                                                               | `<suggestion>: use .smooth, .snappy, .bouncy, .spring, .easeIn, .easeOut, .easeInOut or .linear.`        |
| The parameters are those of the preset, each at most once, in the order of the table                                                               | `<suggestion>: .<preset> takes (<labels>).`, for example `.spring takes (duration:bounce:).`             |
| Each parameter is within its range                                                                                                                 | `<suggestion>: <label> must be from <minimum> to <maximum>.`, for example `bounce must be from -1 to 1.` |
| `recommended` equals one of the suggestions                                                                                                        | `ask_animation: the recommended animation must be one of the suggestions.`                               |

#### Answering an animation request

The request appears in the chat as a pinned animation card above the composer ([Chats](chats.md#pinned-animation-card)): one row per suggestion with its expression and a lane in which a circle slides from the left end to the right end, the recommended one marked and preselected, a `Custom` row in which the user chooses a preset and its parameters, a `Play All` button, a free-text field `Answer another way`, a Skip button and a Submit button. The user answers once with `chats.answerAnimation`, from any window or device; the chat's state is `waitingAnswers` until then. The engine then sends Claude one user message:

```text
Animation: <answer>
```

- `<answer>` is `![](animation:<expression>)` for an animation chosen in the card, a suggestion or the Custom row's expression, for example `Animation: ![](animation:.spring(duration: 0.4, bounce: 0.2))`; the text the user typed, trimmed, with its line breaks; or `Skipped` for a skipped request.
- A skipped request is handled like a skipped question: Claude leaves that point out, does not act on it or guess, and mentions it in its reply.
- The answer is a decision: Claude applies it and does not ask again.

## Writing tickets

- Claude creates a ticket with `create_ticket` (`projectID`, `description`, `attachments?`, `links?`). It never gives a title: Haiku names the ticket ([Titles and naming](tickets.md#titles-and-naming)). The ticket starts as `todo`.
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

| Heading          | What Claude writes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Problem          | What is wrong or missing, from the user's point of view, in one to three sentences.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Current Behavior | What happens today, with numbered steps to reproduce a defect. For a feature that does not exist yet: `None: the feature does not exist yet.`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Expected         | The behaviour after the change, precise enough to be tested.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Change           | What changes in the docs and in the code, naming the docs files and code areas, limited to what has been decided. It can name the code tests to add.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Testing          | One bullet per check of the behaviour in the running app that decides whether the ticket is done, prefixed with who performs it: `- Claude: <test>` for a check Claude runs, on an isolated instance or in a virtual machine ([Build and test](#build-and-test)), `- User: <test>` for a check the user performs. A check is a User bullet only when it needs the user's own accounts, data or hardware; every other check is a Claude bullet. Never a code test: no bullet for a build or test command such as `swift test`, a unit test, a test file or the docs conformance tests. In a project whose type is Go service, only Claude bullets, each a check of the behaviour on the test service, and no User bullet ([Go service projects](#go-service-projects)). |
| Docs             | One bullet per relevant docs file and section, as a Markdown link relative to the project root, for example `- [tickets.md › Status rules](docs/tickets.md#status-rules)`. A section that does not exist yet is followed by `(new)`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

The rule that a check is a User bullet only when it needs the user's own accounts, data or hardware comes from the user ([R205](requirements.md#requirements)); the other content rules of this table are defaults. Default chosen at design time.

- Claude replaces the hint lines of the template, such as `(Explain the problem)`; it never keeps them.
- Code tests stay part of the work without being acceptance tests: the Change section can name the tests to add, and Claude still adds tests and runs the [build and test](#build-and-test) step before it commits. For HephaestusV2, the release workflow runs `swift test` again before it builds a release, so a commit whose code tests fail never ships ([CI](ci.md#release-workflow)).
- When something the ticket needs is unknown, Claude asks first and creates the ticket after the answers.
- Before `create_ticket`, and before `update_ticket` rewrites a description, the chat that writes the ticket settles every decision its implementation needs, so that the chat that implements it needs no question:
  1. it lists those decisions: requirements, behaviours, names and values visible to users, texts shown to users, file formats and product decisions;
  2. it looks for each one in the user's messages, the ticket's comments and attachments, the docs, the code and the git history ([Never invent](#never-invent));
  3. it asks every decision still open with `ask_questions` ([Questions protocol](#questions-protocol));
  4. it writes the answers into the description, under Expected and Change.
- The answers are the validation: once every decision is answered, Claude creates the ticket, or rewrites its description, without a further validation question.
- A feedback chat creates its ticket, and closes, only after every decision is answered ([Project and feedback chats](#project-and-feedback-chats)).
- Each problem gets its own ticket: a request covering several problems leads to one `create_ticket` call per problem. Default chosen at design time.
- Attachments are file paths on the main device, such as screenshots or logs. They are copied into the ticket ([Attachments](tickets.md#attachments)).
- When a ticket depends on another ticket of the same project, or is related to one, Claude records it as a link with the `links` input of `create_ticket` or `update_ticket`, of kind `dependsOn` or `related`, and never writes `Depends on <ID>` in the description ([Ticket links](tickets.md#ticket-links)).
- After creating tickets, Claude tells the user their ids.
- When Claude rewrites the description of an existing ticket with `update_ticket`, the new description also follows the template.

## Ticket status

The status rules (the same list is in [Status rules](tickets.md#status-rules)):

- Every ticket is created with status `todo`; the user may change it afterwards with the status picker.
- Claude sets `in_progress` when it starts working on a ticket.
- When Claude has finished a ticket, after the completion comment, it sets `done` when every Claude test of the ticket's Testing section has passed and the user has said in the chat that every User test has passed; otherwise it sets `review`. A ticket without a Testing section goes to `review`. Claude may switch a ticket between `in_progress` and `review`, for example to make a correction the user asked for.
- In a project whose type is Go service, the implement chat of a single ticket and the bundle chat set the tickets to `done` or `review` after the checks on the test service; a ticket chat started by a bundle chat sets its ticket to `review` ([Go service projects](#go-service-projects)).
- In a project with a GitHub page, the ticket or bundle chat that pushed sets the tickets to `done` or `review` only once its CI chat has reported that CI passed or was not checked, or once the user has chosen `Finish without green CI`; a ticket chat started by a bundle chat sets its ticket to `review`, and the bundle chat sets each merged ticket after CI ([Waiting for CI](#waiting-for-ci)).
- A code-test bullet of a Testing section (a bullet for a build or test command, a unit test, a test file or the docs conformance tests), for example in an older ticket or a ticket the user wrote, counts as passed once a release built by CI contains the ticket's commit.
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
- When the engine answers `forbidden`, Claude reports the message to the user and does not work around it. The refusal of a question in an [implement chat](#implement-chats) is the exception: Claude makes the choice itself ([Asking](#asking)).

## Implementation workflow

The steps, in order:

1. `set_ticket_status` with `in_progress`.
2. Read the ticket (`get_ticket`) and the docs it lists. Ask questions for anything unknown, then wait; an [implement chat](#implement-chats) asks none and makes the choices itself.
3. Change the docs first, then change the code to match the docs.
4. Build and test, with the repository's own commands, then run the Claude tests of the ticket ([Build and test](#build-and-test)).
5. Commit with a conventional commit message `<type>: <summary> (<TICKET-ID>)`, then push.
6. `add_comment` on the ticket with a summary of what changed, commit hash included. In a project with a GitHub page, a ticket or bundle chat then calls `watch_ci` with the pushed commit and waits for the report of the CI chat ([Waiting for CI](#waiting-for-ci)).
7. `set_ticket_status` with `done` when every Claude test of the ticket has passed and the user has said in the chat that every User test has passed; otherwise with `review`. In a project with a GitHub page, a ticket or bundle chat sets it only once the CI chat has reported that CI passed or was not checked, or once the user has chosen `Finish without green CI` ([Waiting for CI](#waiting-for-ci)).

The workflow starts with Implement, whose first message is `/hephaestus-skills:implement-ticket <ticket id>`, with `implement_ticket` called from another chat (from a bundle chat, the first message is `/hephaestus-skills:implement-ticket <ticket id> <bundle id>`, [Bundles](#bundles)), or when the user asks for the implementation in a chat. Its steps are those of the internal skill `implement-ticket`, which Claude uses whenever it implements a ticket, and its end those of `finish-implementation` ([Internal skills](skills.md#internal-skills)).

In a project whose type is Go service, the implement chat of a single ticket (Implement, or `implement_ticket` called from a chat that is not a bundle chat) gives each Claude test the result `waiting for the test service` in its completion comment, then runs the steps of [Go service projects](#go-service-projects), whose step 6 replaces step 7.

### Read

- `get_ticket` returns the description, comments and attachments, each attachment with its absolute path `<project root>/.hephaestus/<path>` ([MCP](mcp.md#get_ticket)). Claude views image attachments by reading those paths.
- Claude reads every docs section listed under Docs, the docs index (the `README.md` of the docs folder, when there is one) and the code involved.
- Unknowns are asked as described in [Questions protocol](#questions-protocol). After asking, Claude ends its turn and continues when the Answers message arrives.
- Until the user writes in it, an [implement chat](#implement-chats) asks nothing: Claude makes each choice itself, marks it with the sentence `Default chosen at design time.` in the docs it changes and lists it under Notes of the completion comment ([Never invent](#never-invent)).

### Docs first

- The docs are the files under the project's `docsPath` (`docs` by default). They are the contract the code is built and tested against.
- Claude first changes every affected docs section so that it describes the behaviour after the change completely, following the conventions of that docs folder (for HephaestusV2, see [Docs index](README.md)).
- When the docs already describe the expected behaviour (a defect where the code differs from the docs), they stay unchanged and the completion comment says so. Default chosen at design time.
- When the project has no docs folder, Claude asks whether to create one, recommending `<docsPath>/<topic>.md`. Default chosen at design time. Until the user writes in it, an [implement chat](#implement-chats) decides itself whether to create one and states the decision under Notes of the completion comment.
- Then Claude changes the code until it does what the docs say. Where the project has tests, it adds or updates tests for the changed behaviour.
- For HephaestusV2 itself, four more rules apply. Every docs file stays linked from `docs/README.md`. Markdown tables stay aligned (`python3 -I scripts/tables.py --fix <files>` aligns them). No personal data enters the repository. The docs conformance tests must pass ([CI](ci.md)).
- A change that adds a user requirement to HephaestusV2 also adds it to [Requirements](requirements.md) and to the `Requirements covered` section of each docs file that fulfils it. Default chosen at design time.

### Build and test

- Claude runs the repository's own commands with its shell tool: the Makefile targets `build` and `test` when they exist, otherwise `swift build` and `swift test` for a Swift package, or `go build ./...` and `go test ./...` for a Go module. Default chosen at design time.
- When a command fails, Claude fixes the cause and runs it again. It never commits while the build or the tests fail. When a failure also happens without Claude's change, Claude asks whether to commit anyway. Default chosen at design time. Until the user writes in it, an [implement chat](#implement-chats) decides itself whether to commit anyway and states the decision under Notes of the completion comment.
- When no build or test command exists, Claude skips this step and says so in the completion comment. Default chosen at design time.
- Claude does not run the project itself (the Makefile target `run`, `swift run` or `go run`) unless the user asks for it. Default chosen at design time.
- Then Claude runs the Claude tests of the ticket's Testing section; in a project whose type is Go service, they run on the test service after the push instead ([Go service projects](#go-service-projects)). A check that needs what an isolated instance cannot do, such as menus, typed text, list rows, scrolling, system dialogs and permission prompts, runs in a virtual machine that Claude starts with the VM tools, without asking: Claude copies the build in, runs it there, and drives and observes it with the VM tools ([Claude's virtual machines](virtual-machines.md#claudes-virtual-machines)). A check that cannot run, for example because `vm_start` fails, gets the result `failed` with the reason. That result is Default chosen at design time.
- When Claude checks the UI of HephaestusV2 itself, it uses a second, isolated instance and the debug MCP tools, and a virtual machine for what those tools cannot do ([Automated UI checks](development.md#automated-ui-checks), [VM checks](development.md#vm-checks)), never the app the user is running. The isolated instance is Default chosen at design time; the virtual machine comes from the user ([R205](requirements.md#requirements)).

### Waiting for CI

These rules apply to every project and sub project that has a [GitHub page](projects.md#github-page), HephaestusV2 included. A project without a GitHub page keeps the other rules of this document.

- The chat that pushes an implementation is its orchestrator: the implement chat of a single ticket (Implement, or `implement_ticket` outside a bundle), a ticket chat in which the user asked for the implementation, and the bundle chat after its single push ([Bundles](#bundles)). A ticket chat started by a bundle chat neither pushes nor waits for CI. A project chat or a feedback chat that implements a ticket at the user's request starts no CI chat: `watch_ci` accepts only ticket and bundle chats. Default chosen at design time.
- Without a pushed commit (no remote, a push that failed, a folder that is not a git repository), or when `watch_ci` fails, the orchestrator does not wait for CI either. Such a chat sets the status as in a project without a GitHub page, and the Notes of its completion comment and its final reply say that CI was not followed, and why. Default chosen at design time.
- The orchestrator does not consider its task done before CI is green: it sets no ticket to `done` or `review` and does not close its chat until its CI chat has reported that CI passed or was not checked, or until the user has chosen `Finish without green CI`.

The steps after the push:

1. The orchestrator posts or updates its completion comments ([Completion comment](#completion-comment), [Bundles](#bundles)), calls `watch_ci` with the full hash of the pushed commit ([MCP](mcp.md#watch_ci)) and ends its turn.
2. The engine starts a [CI chat](chats.md#ci-chats): a chat of kind `ci`, linked to the orchestrator and to its ticket or bundle, with the orchestrator's settings. There Claude waits with the gh CLI for every workflow run of the commit on the project's GitHub repository until they end, then ends its turn with a final reply whose first line is `CI passed.`, `CI failed.` or `CI not checked.`. After `CI failed.` it lists each failed run, its failed jobs and the cause read with `gh run view --log-failed`; after `CI not checked.` it gives the reason: no workflow run exists for the commit, or the gh CLI is missing or not logged in. It changes no file, makes no commit and asks no question ([Default: ci](skills.md#default-ci)). The result lines, and `CI not checked.` covering a missing gh CLI: Default chosen at design time.
3. When the CI chat's turn ends, the engine sends the orchestrator `CI chat finished its turn:`, a blank line and the final reply; `CI chat ended in error: <error message>` when the turn ended in error; `CI chat was stopped.` when it was stopped ([Reports to the orchestrator](chats.md#reports-to-the-orchestrator)).
4. After `CI passed.` or `CI not checked.`, the orchestrator finishes its task. A ticket chat sets its ticket to `done` or `review` ([Ticket status](#ticket-status)). The bundle chat sets each merged ticket to `done` when [Ticket status](#ticket-status) allows it, from the test results its ticket chat reported, and leaves the others in `review`; this is an exception to the rule that it never sets a ticket to `done` ([Bundles](#bundles)). Default chosen at design time. In a Go service project, steps 2 to 6 of [Go service projects](#go-service-projects) set the tickets instead. After `CI not checked.`, the final reply says that CI was not checked.
5. After `CI failed.`, an error or a stop, the orchestrator asks the user with `ask_questions` how to proceed, with the options below, also in an implement chat in which the user has not written: the engine accepts this question there ([Implement chats](#implement-chats)). It then does what the answer says:
   - `Fix and check again`: Claude fixes the cause, builds and tests, commits the fix as `fix: <summary> (<TICKET-ID>)` with the id of the ticket whose change caused the failure, pushes, adds the fix commit with its short hash and subject to Notes of that ticket's completion comment with `update_comment`, and calls `watch_ci` with the new commit: the steps go on from step 2.
   - `Re-run the failed runs`: Claude runs `gh run rerun <run id> --repo <owner>/<name> --failed` for each failed run, `<owner>/<name>` being the repository of the project's GitHub page, which the CI chat watched, then calls `watch_ci` with the same commit: the steps go on from step 2.
   - `Finish without green CI`: Claude names the failed runs under Notes of each ticket's completion comment with `update_comment`, sets the tickets to `review`, and ends with its final reply. In a Go service project, steps 2 to 6 of [Go service projects](#go-service-projects) do not run: the Claude tests keep the result `waiting for the test service`.

Once its task is done, after step 4, after `Finish without green CI` or, in a Go service project, after step 6 of [Go service projects](#go-service-projects), the orchestrator closes its CI chats, and the bundle chat its ticket chats too ([Project and feedback chats](#project-and-feedback-chats)).

The bundle chat fixes a failed CI run itself after `Fix and check again`: this is an exception to the rule that the orchestrator does not implement the tickets itself ([Bundles](#bundles)).

### Go service projects

These rules apply to every project and sub project whose [type](projects.md#project-types) is `goService`. A Go service has no user interface: its tickets are tested on a test service and have no User test. Other projects, HephaestusV2 included, keep the other rules.

- The Testing section of a Go service ticket has only Claude bullets, each a check of the behaviour on the test service; it has no User bullet ([Writing tickets](#writing-tickets)).
- The chat that pushed goes on with the steps below after its push: the implement chat of a single ticket (Implement, or `implement_ticket` outside a bundle), or the bundle chat after its single push, for every ticket it merged ([Bundles](#bundles)).
- The implement chat of a single ticket posts its completion comment after the push, with the result `waiting for the test service` for each Claude test, updates it in step 5 and sets the status in step 6.
- In a bundle, the ticket chats do not run their Claude tests: their lines in the completion comments read `waiting for the test service`, and the ticket chats set their tickets to `review`.
- Claude inspects and operates the project's environments on Kubernetes with the [Kubernetes and Argo CD tools](mcp.md#kubernetes-and-argo-cd-tools), which take an environment's name and use its kubeconfig file, namespace, deployment and Argo CD application, never with kubectl and a guessed kubeconfig file, namespace or deployment; the system prompt lists the environments ([Rendered blocks](chats.md#rendered-blocks)). It stops a port forward with `k8s_stop_port_forward` once it no longer needs it. Default chosen at design time.
- When the project root holds `openapi/contract.yaml`, Claude reads and changes the service through its API with the [API tools](mcp.md#api-tools), `api_operations` and `api_call`, which take an environment's name and use its URL, its certificate setting and the credentials and headers stored in the API Explorer, never with curl and a guessed URL, certificate flags or credentials. Default chosen at design time.

The steps after the push:

1. CI: in a project with a GitHub page, Claude starts a CI chat and waits for its report, as [Waiting for CI](#waiting-for-ci) describes; steps 2 to 6 follow once the CI chat has reported that CI passed or was not checked. In a project without a GitHub page, Claude waits with the gh CLI for the CI runs of the pushed commit until they end. When a run fails, it fixes the cause, builds and tests, commits the fix as `fix: <summary> (<TICKET-ID>)` with the id of the ticket whose change caused the failure, pushes and waits again, until every run is green. When there is no run to wait for (no workflow, no gh CLI or no remote), it skips the wait, still runs the test service, and its final reply says that CI was not checked.
2. Test service: it builds the Docker image from the repository's Dockerfile and runs it with docker, with a temporary postgres when the service uses one, and mocks of the services it calls.
3. Checks: it runs every Claude bullet of each ticket's Testing section against the test service. When a check fails, it fixes the code, builds and tests, commits the fix with the id of the ticket whose change caused it, pushes, waits for CI as in step 1, and runs the checks again, until every check passes.
4. When the test service cannot start (no Dockerfile, docker not available, the container exits), a cause in the repository is fixed, pushed and checked again as in step 3; a cause outside the repository gives the Claude tests of the tickets the result `failed` with the reason, and the tickets go to `review`.
5. It updates each ticket's completion comment with `update_comment`: the Testing lines get their results, and Notes lists each fix commit of that ticket with its short hash and subject.
6. It sets each ticket whose Claude tests have all passed to `done`, following [Ticket status](#ticket-status); the other tickets go to `review`. Then it stops the test service and closes the chats it started. The bundle chat then closes its own chat ([Project and feedback chats](#project-and-feedback-chats)).

The bundle chat fixes the failed CI runs and checks itself and sets the tickets to `done` in step 6: in a Go service project, these are exceptions to the rules that the orchestrator does not implement the tickets itself and never sets a ticket to `done` ([Bundles](#bundles)). It still asks the user after an error or a stop of a ticket chat, when main fails to build or test before the push, and, in a project with a GitHub page, how to proceed when CI fails ([Waiting for CI](#waiting-for-ci)).

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
- A breaking change is written `<type>!: <summary> (<TICKET-ID>)` with the footer `BREAKING CHANGE: <what breaks>`. Claude marks a change as breaking only when the ticket or the user says so, and asks when unsure. Default chosen at design time. Until the user writes in it, an [implement chat](#implement-chats) that is unsure decides itself and states the decision under Notes of the completion comment.
- For HephaestusV2, release versions follow the commit types ([CI](ci.md)): a breaking change gives a major version, `feat` a minor version, anything else a patch.
- Each ticket gets one commit. A later correction asked for in the same chat gets its own commit, with the same ticket id. Default chosen at design time.
- Each fix of a failed CI run ([Waiting for CI](#waiting-for-ci)), and in a Go service project each fix of a failed check on the test service, gets its own commit `fix: <summary> (<TICKET-ID>)`, with the id of the ticket whose change caused the failure ([Go service projects](#go-service-projects)).
- Work outside a ticket, done in a project chat at the user's request, uses the same format without ` (<TICKET-ID>)`. Default chosen at design time.
- Claude stages by path only the files it changed for the ticket. It never stages with `git add -A` or `git add .`, never stages `.hephaestus/` (the user commits ticket data), and never commits changes it did not make. When a file it must change already has uncommitted changes it did not make, Claude asks. Default chosen at design time. Until the user writes in it, an [implement chat](#implement-chats) decides itself how to proceed, still without committing the changes it did not make, and states the decision under Notes of the completion comment.
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
- When the push is rejected because the remote has new commits, Claude runs `git pull --rebase --autostash` and then `git push` once more. If the rebase hits a conflict, Claude runs `git rebase --abort` and asks how to proceed; a second rejection also leads to a question. Default chosen at design time. Until the user writes in it, an [implement chat](#implement-chats) decides itself how to proceed in both cases and states the decision under Notes of the completion comment.
- When the project is not a git repository, there is no commit and no push, and the completion comment says so. Default chosen at design time.
- An authentication or network failure is reported to the user. Claude does not change remotes or credentials. Default chosen at design time.
- A ticket chat started by a bundle chat does not push; the bundle chat pushes once after it has merged the branches of every ticket ([Bundles](#bundles)).
- After the push, in a project with a GitHub page, the ticket or bundle chat that pushed starts a CI chat and waits for CI ([Waiting for CI](#waiting-for-ci)). Claude pushes each fix commit of a failed CI run, or of a failed check in a Go service project, with these rules, then waits for CI again ([Go service projects](#go-service-projects)).
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
- The Testing part has one line per bullet of the ticket's Testing section, in the same order, with its result: `passed`, `failed`, `waiting for the user`, or `waiting for the release` for a code-test bullet while no release built by CI contains the commit ([Ticket status](#ticket-status)). When the ticket has no Testing section, it reads `- None: the ticket has no Testing section.`.
- In an [implement chat](#implement-chats), Notes lists each choice Claude made itself because something the ticket needed was unknown, and each decision it took at a point where the other chats ask.
- In a Go service project, the result of a Claude test is `waiting for the test service` until the checks on the test service have run. The chat that runs them then updates the comment with `update_comment`: each Testing line gets its result, and Notes lists each fix commit of the ticket with its short hash and subject ([Go service projects](#go-service-projects)).
- In a project with a GitHub page, the ticket or bundle chat that pushed posts the comment before it calls `watch_ci`. With `update_comment`, Notes then gets each fix commit of a failed CI run, with its short hash and subject, and, after `Finish without green CI`, the failed runs ([Waiting for CI](#waiting-for-ci)).
- Claude posts the comment before it ends its turn, so the comment exists before an update can restart the app.

The format of this comment is a default. Default chosen at design time.

## Bundles

- A bundle chat starts with Implement All or `implement_bundle`, whose first message is `/hephaestus-skills:implement-bundle <bundle id>`: the orchestrator follows the internal skill `implement-bundle` ([Internal skills](skills.md#internal-skills)). The bundle prompt contains every ticket of the bundle; `get_bundle` and `get_ticket` give the current state.
- The bundle chat is the orchestrator: it does not implement the tickets itself, and it skips the `done` ones. Default chosen at design time. In a project with a GitHub page, it fixes a failed CI run itself when the user chooses `Fix and check again` ([Waiting for CI](#waiting-for-ci)), and in a Go service project the failed CI runs and checks ([Go service projects](#go-service-projects)). Below, main is the project root's current branch.
- A ticket waits only for the tickets of the same bundle that it declares a Depends on link to ([Ticket links](tickets.md#ticket-links)) and that are not `done`. Related links and tickets outside the bundle never make it wait.
- The orchestrator calls `implement_ticket` for every ticket that waits for nothing, all in one turn, and ends its turn; the number of ticket chats running at once is not limited. For each call the engine creates the branch `<bundle id>/<ticket id>` (for example `HEPH-B18/HEPH-56`) from main, checked out in the git worktree `<data dir>/Worktrees/<project id>/<ticket id>`, then starts an orchestrated ticket chat linked to the orchestrator, which works in that worktree ([Orchestrated ticket chats](chats.md#orchestrated-ticket-chats)) and whose first message is `/hephaestus-skills:implement-ticket <ticket id> <bundle id>`. When the engine cannot create the branch or the worktree, `implement_ticket` fails with git's message and no chat starts; the orchestrator asks the user whether to retry the ticket, skip it or stop, as after an error.
- The ticket chat runs steps 1 to 7 of the [implementation workflow](#implementation-workflow) for its ticket in its worktree, with its own commit on its branch, completion comment and status, but does not push: the first line of its completion comment ends with ` (not pushed: the bundle chat pushes at the end)`. It is an [implement chat](#implement-chats): it asks no questions until the user writes in it, and it asks its permission prompts in its own chat, where the user answers them. A ticket that needs no change, because a commit of the bundle already on its branch covers it, gets no commit; its completion comment names that commit. Default chosen at design time. In a Go service project, the ticket chat does not run its Claude tests: their lines in its completion comment read `waiting for the test service`, and it sets its ticket to `review`. In a project with a GitHub page, it sets its ticket to `review` too: the bundle chat sets it after CI ([Waiting for CI](#waiting-for-ci)).
- When a ticket chat's turn ends and it does not wait for answers, the engine sends the orchestrator the chat's final reply, or tells it that the chat ended in error or was stopped.
- When every bundle ticket that a waiting ticket depends on has reported back, the orchestrator merges their branches into main, then starts the waiting ticket's chat, whose branch starts from main and so contains their commits.
- The orchestrator merges a branch by rebasing it onto main in the branch's worktree, then fast-forwarding main to it in the project root, so main holds one commit per ticket. On a conflict, it resolves the conflict itself, then builds and tests.
- After an error or a stop of a ticket chat, the orchestrator asks the user with `ask_questions` whether to retry the ticket, skip it or stop; the other ticket chats keep running.
  - Retry: the orchestrator calls `implement_ticket` again. The engine removes the ticket's old worktree and branch, and the new chat starts on a fresh branch from main.
  - Skip: the orchestrator sets the ticket back to `todo` and comments why. Every bundle ticket that depends on it is skipped too: set back to `todo` with a comment that names the skipped ticket.
  - Stop: the orchestrator starts no other ticket chat and lets the running ones finish; nothing is merged or pushed, every branch and worktree is kept, and every chat it started stays open: a stopped bundle is not done.
- After every ticket has reported back or been skipped, the orchestrator merges the branches not merged yet, in bundle order. It then builds and tests main once, as [Build and test](#build-and-test) says. A failure stops the push and the orchestrator asks the user. Otherwise it pushes once, so the bundle starts a single CI run. The result is one commit per ticket, each with that ticket's id.
- The rebase changes the commit hashes: the orchestrator updates each ticket's completion comment with `update_comment`, so that its first line names the hash of the ticket's commit on main.
- In a project with a GitHub page, after the push the orchestrator starts a CI chat and waits for its report: it sets the tickets and closes its chat only once CI passed or was not checked, or once the user chose `Finish without green CI` ([Waiting for CI](#waiting-for-ci)).
- In a Go service project, after the push the orchestrator waits for CI, runs the test service and the Claude tests of every merged ticket, fixing what fails, updates the completion comments, sets the tickets to `done` or `review` and closes its chat ([Go service projects](#go-service-projects)). It still asks the user after an error or a stop of a ticket chat, when main fails to build or test before the push, and, in a project with a GitHub page, how to proceed when CI fails.
- After the push, the orchestrator removes the worktrees and branches of the merged tickets; those of skipped tickets are kept. When the project has no remote, there is no push, and it removes them once main builds and tests after the last merge.
- When its task is done, after the push and, when it follows CI or runs the checks of a Go service project, after those, the orchestrator closes the ticket chats and CI chats it started, with the `chatIDs` of `close_chat`, just before it closes its own chat; a chat with a turn in progress stays open ([Project and feedback chats](#project-and-feedback-chats)).
- The orchestrator's final reply lists each ticket with the hash of its commit on main, or with `skipped` and the reason, and names the conflicts it resolved and the chats that `close_chat` did not close. It never sets a ticket to `done`, except after CI in a project with a GitHub page ([Waiting for CI](#waiting-for-ci)) and in a Go service project. Default chosen at design time.
- The bundle has its own status ([Bundle status rules](tickets.md#bundle-status-rules)): Implement All and `implement_bundle` set it to `in_progress`. The engine sets it to `done` when every ticket of the bundle is `done`, whoever set the last ticket, and back to `in_progress` when a ticket of a `done` bundle is not `done`; otherwise only the user sets it to `done`. Claude may set it to `todo` or `in_progress` with `set_bundle_status`, never to `done`, and never changes a `done` bundle. Each ticket chat sets its ticket to `done` or `review` as [Ticket status](#ticket-status) says; in a project with a GitHub page, the ticket chats set `review` and the orchestrator sets the tickets after CI, and in a Go service project after the checks on the test service.

## Project and feedback chats

- In a project chat Claude plans and works freely. It creates, updates and deletes tickets and bundles, comments, creates and updates projects, runs builds and tests, and edits skills, always following [Never invent](#never-invent), [Writing tickets](#writing-tickets) and [Ticket status](#ticket-status).
- To implement tickets from a project chat, Claude calls `implement_ticket` or `implement_bundle`, which start dedicated chats. It implements in the project chat itself only when the user asks for that, and then follows the implementation workflow there with the skill `implement-ticket`. A bundle is orchestrated only by its bundle chat, because only that chat's `implement_ticket` calls give ticket chats their own branch and worktree ([Orchestrated ticket chats](chats.md#orchestrated-ticket-chats)): asked to implement a bundle in another chat, Claude implements its tickets one after the other with `implement-ticket`. Default chosen at design time.
- A feedback chat ([Feedback](feedback.md)) gets the common skill alone in its system prompt. Its first message calls the internal skill `feedback` with the comment and the feedback context; the skill tells Claude that this is a feedback chat, sent from the window the user was using, whose goal is a ticket of the chat's project. Claude works out what the feedback means from the comment, the context and, when the feedback has one, the screenshot, asking questions when it is unclear. It settles every decision of the ticket's implementation as [Writing tickets](#writing-tickets) describes, then calls `create_ticket` in the feedback project with the template and, when the feedback has a screenshot, the screenshot path as an attachment, and summarizes the ticket.
- The files that the user added to the feedback ([Added files](feedback.md#added-files)) reach Claude with it: the feedback context has one `Attachment:` line per file, with the path where it is saved. Claude reads every added file with the comment and, when the feedback has one, the screenshot, and passes the path of every `Attachment:` line in the `attachments` of `create_ticket`, after the screenshot path when the feedback has a screenshot, so the ticket carries every added file.
- Claude implements the new ticket in the feedback chat only when the user asks, and then follows the implementation workflow. Default chosen at design time.
- Claude closes the chat it runs in with `close_chat` when the user asks for it, and when the work of the chat is finished: in a ticket chat once it has set the ticket to `done`, in a bundle chat once every ticket has been implemented or skipped and the push is done (in a project with a GitHub page, once CI passed or was not checked or the user chose `Finish without green CI` ([Waiting for CI](#waiting-for-ci)); in a Go service project, once it has finished step 6 of [Go service projects](#go-service-projects)), in a feedback chat once it has created the ticket. It closes a project chat only when the user asks. After the call it finishes its reply; the chat closes when the turn ends, and the user can reopen it ([Chats](chats.md#closing-a-chat)).
- Claude closes other chats of the project, with the `chatIDs` of `close_chat`, only when the user asks it to close them, never on its own, except an orchestrator, which closes the chats it started when its task is done (below). The listed chats close at once, except a chat whose turn is in progress, which stays open; the result lists each refused chat with the reason, and Claude tells the user which chats were not closed and why. A call that names a chat the calling chat does not orchestrate follows the chat's permission mode, so in Ask Every Time the user approves it first ([Chats](chats.md#closing-a-chat), [MCP](mcp.md#close_chat)).
- An orchestrator closes on its own, with the `chatIDs` of `close_chat`, every chat it orchestrates, those whose `orchestrator` is its chat, when its task is done: the bundle chat its ticket chats and CI chats, after its push and, when it follows CI ([Waiting for CI](#waiting-for-ci)) or runs the checks of a Go service project ([Go service projects](#go-service-projects)), after those, just before it closes its own chat ([Bundles](#bundles)); the implement chat of a single ticket its CI chats, after it has set the ticket's status. A ticket chat in which the user asked for the implementation closes its CI chats after it has set the ticket's status too. Default chosen at design time. The call runs without a permission prompt in every permission mode, also when it names the calling chat ([Chats](chats.md#close-chat-hook)). A bundle that the user stopped is not done, and its chats stay open. A chat with a turn in progress is refused and stays open, and the orchestrator names the refused chats in its final reply.

## SF Symbols

When Claude names an SF Symbol in a reply, in `ask_questions`, or in a ticket description or a comment that it writes (with `create_ticket`, `update_ticket`, `add_comment` or `update_comment`, or as a [comment answer](#where-the-rules-apply)), it writes it as `![](sf:<name>)`, for example `![](sf:line.3.horizontal.decrease.circle)`. The chat transcript, the pinned questions card, ticket descriptions and comments show such a marker as the symbol's icon followed by its name ([Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)); docs do not draw it.

When Claude needs the user to choose an SF Symbol, it asks with `ask_symbol` ([Symbol requests](#symbol-requests)).

## Colors

When Claude names a color in a reply, in `ask_questions`, or in a ticket description or a comment that it writes, it writes it as `![](color:<color>)`, `<color>` being a hex color `#RRGGBB` or a [system color name](chats.md#system-colors), for example `![](color:#FF9500)` or `![](color:systemBlue)`. The chat transcript, the pinned questions card, ticket descriptions and comments show such a marker as a swatch of the color followed by the hex or the name ([Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)); docs do not draw it.

When Claude needs the user to choose a color, it asks with `ask_color` ([Color requests](#color-requests)).

## Sounds

When Claude names a sound in a reply, or in a ticket description or a comment that it writes, it writes it as `![](sound:<name>)`, `<name>` being a name of the [sound catalogue](chats.md#sound-catalogue) written as it is, spaces included, for example `![](sound:macOS/Glass.aiff)` or `![](sound:iOS 26.1/sms-received1.caf)`. The chat transcript shows a sound marker as a play button followed by the sound's name, and the pinned questions, symbol and sound cards, ticket descriptions and comments as the character `▶` followed by the name; the play button and the `▶` play the sound ([Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)). Docs do not draw it.

When, in a Swift application project, Claude needs the user to choose a sound for an app of an Apple platform, it asks with `ask_sound` ([Sound requests](#sound-requests)).

## Keyboard shortcuts

When Claude names a keyboard shortcut in a reply, or in a ticket description or a comment that it writes, it writes it as `![](shortcut:<shortcut>)`, `<shortcut>` being written in the [shortcut notation](chats.md#shortcut-notation), the modifiers `⌃⌥⇧⌘` in this order and then one key, with a key `(`, `)` or `\` written with a `\` before it, for example `![](shortcut:⇧⌘K)`, `![](shortcut:⌘↩)` or `![](shortcut:⌘\()`. The chat transcript shows such a marker as key caps, and ticket descriptions and comments as its key caps as text ([Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)). Docs do not draw it.

When, in a Swift application project, Claude needs the user to choose a keyboard shortcut, it asks with `ask_shortcut` ([Shortcut requests](#shortcut-requests)).

## Fonts

When Claude names a font in a reply, or in a ticket description or a comment that it writes, it writes it as `![](font:<font>)`, `<font>` being written in the [font notation](chats.md#font-notation), a Dynamic Type text style or `<family>/<weight>/<size>`, for example `![](font:.headline)` or `![](font:System Rounded/Semibold/17)`. The chat transcript, the pinned questions card, ticket descriptions and comments show such a marker as the font reads, for example `System Rounded · Semibold · 17 pt`, drawn in that font ([Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)). Docs do not draw it.

When Claude needs the user to choose a font, it asks with `ask_font` ([Font requests](#font-requests)).

## Animations

When Claude names an animation in a reply, or in a ticket description or a comment that it writes, it writes it as `![](animation:<expression>)`, `<expression>` being a SwiftUI animation expression of [Animation expressions](#animation-expressions), for example `![](animation:.spring(duration: 0.4, bounce: 0.2))`. The chat transcript shows such a marker as a replay button and a lane followed by the expression, and ticket descriptions and comments as the expression ([Chats](chats.md#links-images-and-files), [Tickets](tickets.md#ticket-detail)). Docs do not draw it.

When, in a Swift application project, Claude needs the user to choose an animation, it asks with `ask_animation` ([Animation requests](#animation-requests)).

## Showing images

Whenever Claude shows the user an image, for example one it rendered, a screenshot or an image of the project, it calls `show_image` with the paths of the image files and an optional caption in Markdown ([MCP](mcp.md#show_image)). The app copies the images into the chat and shows them, below the caption, at the place of the call, in local and remote windows; they stay visible after the files are deleted ([Chats](chats.md#shown-images)).

- Claude does not show an image with a Markdown image in its reply, and does not attach it to a ticket comment only so that the user can see it. A Markdown image to a file outside the project folder is refused in the transcript ([Images](documentation-viewer.md#images)).
- `show_image` accepts PNG, JPEG, GIF and WebP files; Claude saves an image in one of these formats before it shows it. A call with another file or a missing path fails as a whole and shows nothing ([Image rules](mcp.md#image-rules)).
- `show_image` asks the user nothing and needs no permission: Claude continues its work after it returns, also in an implement chat that the user has not written in yet.

## Global memories

Besides the memory folder of its project, which the Claude CLI gives it, every chat receives the device's global memories folder: the common skill names the folder and the lines of its `MEMORY.md`, and Claude reads and writes the folder's files with its own file tools ([Global memories](memories.md#global-memories), [In chats](memories.md#in-chats)).

- Claude decides per memory where it saves it: a memory that holds for every project goes to the global memories folder, with its line in the global `MEMORY.md`; the other memories go to the project's memory folder.
- When a line of the global `MEMORY.md` concerns its work, Claude reads that memory's file.
- In a chat of a sub project, the common skill also names the memory folders inherited from the parent projects, which Claude reads and never writes in: it saves every new memory in its project's memory folder or in the global memories folder ([Inherited memories](memories.md#inherited-memories)).

## Self-update loop

When the project is HephaestusV2 itself (the HephaestusV2 project: the project `HEPH` whose origin names the repository `Azavech/HephaestusV2`, whose URL is hardcoded in the app, [HephaestusV2 project](projects.md#hephaestusv2-project)), a pushed change reaches the running app without manual steps:

| Step | Who                           | What                                                                                                                                                                                                                                                                                                                      | Specification                                                       |
| ---- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| 1    | User                          | Sends feedback with the ladybug, or creates or opens a ticket of the HephaestusV2 project.                                                                                                                                                                                                                                | [Feedback](feedback.md), [Tickets and bundles](tickets.md)          |
| 2    | Claude, feedback chat         | Asks every open decision with questions, then creates the ticket: `todo`, named by Haiku, screenshot attached when the feedback has one.                                                                                                                                                                                  | [Feedback](feedback.md)                                             |
| 3    | User                          | Clicks Implement, or Implement All on a bundle.                                                                                                                                                                                                                                                                           | [Ticket chats and Implement](tickets.md#ticket-chats-and-implement) |
| 4    | Claude, ticket chat           | Sets `in_progress`, updates the docs and the code, builds and tests, commits, pushes to `main`, comments, starts a CI chat, sets `done` or `review` once CI is green. In a bundle, the ticket chats commit on their own branches without pushing; the bundle chat merges them into `main`, builds, tests and pushes once. | [Implementation workflow](#implementation-workflow)                 |
| 5    | GitHub Actions, `release.yml` | Checks for personal data and checks the docs, runs `swift test`, computes the version, builds and signs the app, and publishes the release `v<version>` with `HephaestusV2.zip` and `release.json`.                                                                                                                       | [CI](ci.md)                                                         |
| 6    | Updater                       | Finds the release (10 s after launch, every `updateCheckIntervalMinutes`, or on Check Now), downloads and verifies it, and reports it ready.                                                                                                                                                                              | [Updater](updater.md)                                               |
| 7    | App                           | Restarts on the new version as soon as no chat is working, Claude's background work included, and no editor is unsaved. The status bar's Update item shows from the moment the update is found; a click on it installs the update and restarts after the restart checks.                                                  | [Updater](updater.md)                                               |
| 8    | User                          | Checks the change and sets a `review` ticket to Done.                                                                                                                                                                                                                                                                     | [Status rules](tickets.md#status-rules)                             |

- The loop needs a release build (build number above 0) with `autoUpdate` on, `HEPHAESTUS_DISABLE_UPDATER` not set and a writable app folder. With `autoUpdate` off, step 7 happens from the About window's Install button, a click on the status bar's Update item or Update Now in Settings > Updates.
- The commit must be pushed to `main` of the release repository.
- A failing pipeline publishes no release. The running version stays, and the failure shows on the repository's Actions page. The CI chat reports it to the chat that pushed, which asks the user how to proceed ([Waiting for CI](#waiting-for-ci)).
- The ticket or bundle chat that pushed follows the pipeline through its CI chat, since HephaestusV2 has a GitHub page: it sets the status and finishes once CI is green, or once the user decides so ([Waiting for CI](#waiting-for-ci)). The app installs the release only once no chat is working, so after the CI chat and the chat that pushed have finished.
- The restart stops the Claude processes. Transcripts are kept, and the next message of a chat resumes its Claude session ([Chats](chats.md)).
- Docs changed and pushed without a ticket are not turned into code automatically. A ticket that lists the changed sections under Docs starts the loop. Default chosen at design time.

## Engine-enforced rules

| Rule                                                                                                                                                                                                   | Checked by                                                                                                                                     | Failure                                    |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Descriptions written by Claude follow the template                                                                                                                                                     | `tickets.create`, `tickets.update`                                                                                                             | `invalid`                                  |
| New tickets start as `todo`                                                                                                                                                                            | `tickets.create` (no status parameter)                                                                                                         | none                                       |
| Tickets created without a title are named by Haiku                                                                                                                                                     | `tickets.create`                                                                                                                               | none                                       |
| Claude never changes the status of a `done` ticket                                                                                                                                                     | `tickets.setStatus`                                                                                                                            | `forbidden`                                |
| Questions are labelled in order, with 2 to 10 options; a `single` question has exactly one recommended, a `multiple` question one or more, at most `maxChoices`, and `minChoices` at most `maxChoices` | `chats.postQuestions`                                                                                                                          | `invalid`                                  |
| A chat has at most one waiting question set, symbol, color, sound, shortcut, font or animation request                                                                                                 | `chats.postQuestions`                                                                                                                          | `conflict`                                 |
| Symbol requests have 2 to 10 distinct SF Symbol names, one recommended                                                                                                                                 | `chats.postSymbol`                                                                                                                             | `invalid`                                  |
| A symbol request is refused while a question set, symbol, color, sound, shortcut, font or animation request waits                                                                                      | `chats.postSymbol`                                                                                                                             | `conflict`                                 |
| Color requests have 2 to 10 distinct hex colors or system color names, or pairs of them, one recommended                                                                                               | `chats.postColor`                                                                                                                              | `invalid`                                  |
| A color request is refused while a question set, symbol, color, sound, shortcut, font or animation request waits                                                                                       | `chats.postColor`                                                                                                                              | `conflict`                                 |
| Sound requests are posted only in projects of type Swift application                                                                                                                                   | `chats.postSound`                                                                                                                              | `forbidden`                                |
| Sound requests have 2 to 10 distinct names of the sound catalogue, one recommended                                                                                                                     | `chats.postSound`                                                                                                                              | `invalid`                                  |
| A sound request is refused while a question set, symbol, color, sound, shortcut, font or animation request waits                                                                                       | `chats.postSound`                                                                                                                              | `conflict`                                 |
| Shortcut requests are posted only in Swift application projects                                                                                                                                        | `chats.postShortcut`                                                                                                                           | `forbidden`                                |
| Shortcut requests have 2 to 10 distinct shortcuts in menu notation, one recommended, and valid `inUse` entries                                                                                         | `chats.postShortcut`                                                                                                                           | `invalid`                                  |
| A shortcut request is refused while a question set, symbol, color, sound, shortcut, font or animation request waits                                                                                    | `chats.postShortcut`                                                                                                                           | `conflict`                                 |
| Font requests have a question, a sample and 2 to 10 distinct fonts of the font catalogue, one recommended                                                                                              | `chats.postFont`                                                                                                                               | `invalid`                                  |
| A font request is refused while a question set, symbol, color, sound, shortcut, font or animation request waits                                                                                        | `chats.postFont`                                                                                                                               | `conflict`                                 |
| Animation requests are posted only in Swift application projects                                                                                                                                       | `chats.postAnimation`                                                                                                                          | `forbidden`                                |
| The Kubernetes and Argo CD tools run only for the chat's own Claude, in Go service projects                                                                                                            | the methods of [Kubernetes and Argo CD](engine-api.md#kubernetes-and-argo-cd)                                                                  | `forbidden`                                |
| The API tools run only for the chat's own Claude, in Go service projects                                                                                                                               | the methods of [API](engine-api.md#api)                                                                                                        | `forbidden`                                |
| Animation requests have 2 to 10 distinct SwiftUI animation expressions with parameters in range, one recommended                                                                                       | `chats.postAnimation`                                                                                                                          | `invalid`                                  |
| An animation request is refused while a question set, symbol, color, sound, shortcut, font or animation request waits                                                                                  | `chats.postAnimation`                                                                                                                          | `conflict`                                 |
| `ask_questions`, `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font` and `ask_animation` need a chat token                                                                              | MCP server                                                                                                                                     | see [MCP](mcp.md)                          |
| `show_image` needs a chat token and shows only PNG, JPEG, GIF and WebP files                                                                                                                           | MCP server, `chats.postImages`                                                                                                                 | `forbidden`, `invalid`                     |
| An implement chat posts no question set, symbol, color, sound, shortcut, font or animation request until the user writes in it, except one question set after a CI failure report                      | `chats.postQuestions`, `chats.postSymbol`, `chats.postColor`, `chats.postSound`, `chats.postShortcut`, `chats.postFont`, `chats.postAnimation` | `forbidden`                                |
| `close_chat` needs a chat token and closes only chats of the calling chat's project                                                                                                                    | MCP server, `chats.close`                                                                                                                      | see [MCP](mcp.md)                          |
| A comment answer uses only the read tools, `update_ticket` and `set_ticket_status`, and changes only its comment's ticket                                                                              | MCP server                                                                                                                                     | `forbidden`, see [MCP](mcp.md#actor-rules) |
| `close_chat` never closes another chat while a turn is in progress in it                                                                                                                               | `chats.close`                                                                                                                                  | see [MCP](mcp.md)                          |
| `watch_ci` needs a chat token, a ticket or bundle chat that no other chat started, and a project with a GitHub page                                                                                    | MCP server, `chats.watchCI`                                                                                                                    | `forbidden`, `conflict`                    |
| Links join two tickets of the same project, once per pair, without a Depends on cycle                                                                                                                  | `tickets.create`, `tickets.update`                                                                                                             | `invalid`, `notFound`                      |
| A `done` ticket is not implemented                                                                                                                                                                     | `chats.implementTicket`                                                                                                                        | `conflict`                                 |
| A bundle is implemented only when one of its tickets is not `done`                                                                                                                                     | `chats.implementBundle`                                                                                                                        | `conflict`                                 |
| A bundle is implemented only when its status is `todo`                                                                                                                                                 | `chats.implementBundle`                                                                                                                        | `conflict`                                 |
| Claude never sets a bundle to `done` and never changes a `done` bundle                                                                                                                                 | `bundles.setStatus`                                                                                                                            | `forbidden`                                |

The engine does not check the other rules (never invent, docs first, build and test, the tests that allow `done`, commits, pushing, waiting for CI and the completion comment); only the prompts carry them. A ticket file that Claude edits with its own file tools reaches the engine as an external change with the actor `system` ([Data model](data-model.md#external-changes)); the template and status rules are not applied to it. Only the prompt rule `Never create, edit or delete files inside a .hephaestus folder yourself` prevents it. The error messages of the ticket rules are in [Errors](tickets.md#errors).

## Worked example

The project in this example is illustrative: identifier `DEMO`, an HTTP service with a `docs/` folder and a Makefile, and no GitHub page, so Claude does not wait for CI ([Waiting for CI](#waiting-for-ci)).

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
Document both answers of GET /health in a new Health section of docs/http.md, then make the health handler check the database connection and answer from the result, with a test of each answer.

Testing
- Claude: in a virtual machine, start the service without its database and check that GET /health answers 503 with the body down.

Docs
- [http.md › Health](docs/http.md#health) (new)
```

5. The engine creates `DEMO-7` with status `todo` and the provisional title `GET /health answers 500 Internal Server Error with an empty`, which Haiku replaces before `create_ticket` returns. Claude tells the user the id.
6. The user clicks Implement on `DEMO-7`. In the new ticket chat, Claude sets `in_progress`, reads the ticket and `docs/http.md`, writes the Health section, changes the handler and its tests, and runs `make build` and `make test`. It runs the Claude test in a virtual machine: `vm_start`, `vm_copy_in` of the built service, then `vm_shell` to start it without a database and call GET /health, which answers 503 with the body down. It commits `fix: answer 503 from /health when the database is down (DEMO-7)`, pushes, and comments:

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
- Claude: in a virtual machine, start the service without its database and check that GET /health answers 503 with the body down: passed

Notes
- None
```

7. The ticket has no User test and its Claude test has passed, so Claude sets `DEMO-7` to `done` and closes its chat with `close_chat` ([Project and feedback chats](#project-and-feedback-chats)). Its final reply summarizes the change, the commit, the checks and the result of the test.

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
- R111: Implement All runs the tickets that wait for no other ticket in parallel, each in its own ticket chat on its own branch, coordinated by the bundle chat that started them, which merges the branches and pushes once at the end.
- R113: Claude can close the chat it runs in when the user asks or its work is finished; a closed chat shows `This conversation is over` in place of its composer until the user reopens it.
- R114: Claude marks each SF Symbol it names, and the chat transcript and the pinned questions card show the marker as the symbol's icon followed by its name.
- R117: Claude asks the user to choose an SF Symbol with `ask_symbol`: suggestions show as icons, any SF Symbol of the Mac can be searched, the user picks one, answers another way or skips.
- R119: The Testing section of a ticket Claude writes lists only checks of the behaviour in the running app, never code tests; the code tests to add can be named under Change.
- R124: A ticket can depend on other tickets of its project or be related to them; the other ticket shows the inverse link, Blocks or Related; the user and Claude add and remove links; the ticket list marks a ticket that depends on a ticket that is not done, and Implement asks for confirmation while one is not done.
- R126: The engine sets a bundle to done when every ticket of the bundle is done, whoever changed the last ticket, and sets a done bundle back to in progress when one of its tickets is not done.
- R132: Claude asks the user to choose a color with `ask_color`, as one color or a light and dark pair: suggestions show as swatches, any system color can be picked from a grid and any other color with the macOS color panel or a hex field, the user answers another way or skips, and the chat shows the colors Claude names and the answer as swatches.
- R133: In a Swift application project, Claude asks the user to choose a sound with `ask_sound`: the card lists the suggestions and searches the macOS sounds, the installed Simulator runtimes' sounds and the project's sound files; selecting one plays it; the user picks one, answers another way or skips.
- R134: In a Swift application project, Claude asks the user to choose a keyboard shortcut with `ask_shortcut`: suggestions show as key caps, the user can record another combination and sees when macOS or the app already uses the selected one, then picks one, answers another way or skips.
- R135: Claude asks the user to choose a font with `ask_font` and a sample text: the suggestions are drawn in their fonts, every font of the Mac and of the project can be searched, the user picks one, sets its weight and size and sees the sample in it, answers another way or skips.
- R136: In a Swift application project, Claude asks the user to choose a SwiftUI animation with `ask_animation`: each suggestion plays in a lane, the user compares them, sets a preset and its parameters in a Custom row, picks one, answers another way or skips.
- R137: Claude closes other chats of the project when the user asks it to, never on its own, except an orchestrator, which closes the chats it started when its task is done; a chat with a turn in progress is not closed.
- R140: A comment that mentions `@Claude` gets an answer from Claude as a new comment, made by a one-shot call without a chat; typing `@` in the comment composer suggests Claude, mentions are highlighted, Claude may change the ticket's title, description, links and status, a row shows while Claude replies and offers Retry when it could not, and the answers count in the project's costs.
- R143: Claude asks the user only true unknowns and decides points with an evident answer without asking.
- R144: The chat that writes a ticket settles every decision of its implementation with the user before it creates the ticket or rewrites its description, and writes the answers into the description; a feedback chat creates its ticket, and closes, only after every decision is answered.
- R145: A chat started to implement a ticket asks the user no question until the user writes in it: it makes the choices itself, marks them in the docs and lists them, with the decisions it took, in its completion comment; the engine refuses its questions.
- R146: In a Go service project, Claude waits after the push for CI to be green, fixing what fails, then tests the tickets on a test service and sets them done; Go service tickets have no User tests.
- R150: Claude shows the user images in the chat with `show_image`: PNG, JPEG, GIF and WebP files are copied into the chat and shown, with an optional caption, at the place of the call, without a permission prompt, in local and remote windows; clicking one opens the image viewer.
- R151: Claude can ask multiple-choice questions: the user checks options within the minimum and maximum Claude sets and adds own answers.
- R161: After an implementation is pushed in a project with a GitHub page, a CI chat follows CI and reports to the orchestrator, which asks the user how to proceed when CI fails and finishes only once CI is green or the user decides so.
- R162: Each environment of a Go service names its namespace, deployment, Argo CD application and kubeconfig, which Claude receives and uses through HephaestusV2's Kubernetes and Argo CD tools.
- R164: The main button of the pinned questions card reads `Submit` only when pressing it sends the answers to Claude, and `Next` on the other questions of the set.
- R169: Claude keeps global memories that every chat of every project receives; the user shows and edits them with View ▸ Global Memories.
- R175: Ticket descriptions and comments draw the SF Symbol, color, font, shortcut, sound and animation markers, and Claude writes them there when it names one.
- R181: Feedback, Implement and Implement All start their chat by calling the internal skills feedback, implement-ticket and implement-bundle, which, with finish-implementation, hold the instructions of these tasks, are always active in every project, and are shown and edited only with View ▸ Internal Skills.
- R184: Claude marks each keyboard shortcut, font, sound and animation it names in a chat reply, and the chat transcript draws the marker.
- R185: Every prompt that HephaestusV2 gives Claude is an internal skill that the user edits with View ▸ Internal Skills, with Restore Default, and that HephaestusV2 puts in the system prompt of the chats and calls that use it.
- R205: A ticket Claude writes has a User Testing bullet only for a check that needs the user's own accounts, data or hardware; Claude runs every other check itself, in a virtual machine that it starts without asking when the check needs what the offscreen check instance cannot do.
