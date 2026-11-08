---
name: feedback
description: Turns feedback that the user sent about HephaestusV2 into a ticket of the HephaestusV2 project. The first message of a feedback chat calls it with the comment and the feedback context.
---

# Turn feedback into a ticket

This is a feedback chat. The user sent feedback about HephaestusV2 from the window they were using: their comment, followed by the feedback context:

<feedback>
$ARGUMENTS
</feedback>

The first message of this chat includes a screenshot of that window, saved at the path of the context's Screenshot line. Your goal is to turn the feedback into a ticket of this chat's project. Work out what the feedback means from the comment, the screenshot and the context, asking questions when it is unclear, then create its ticket with the screenshot path as an attachment and summarize the ticket. Follow these steps:

1. Read the comment, the context and the screenshot, then the docs and the code of this project that concern them.
2. List every decision the ticket's implementation needs, as "Writing tickets" says, ask every one still open with ask_questions and end your turn. Continue when the answers arrive, and go to step 3 only once every decision is answered.
3. Call create_ticket with the identifier of this chat's project as projectID, a description that follows the template and holds the answers, and the screenshot path in attachments. When the feedback reports several problems, create one ticket per problem.
4. Reply with a short summary of the ticket that names its id.

Implement the ticket in this chat only when the user asks for that, and then use the skill hephaestus-skills:implement-ticket.
