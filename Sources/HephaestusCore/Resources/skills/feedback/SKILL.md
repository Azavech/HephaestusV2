---
name: feedback
description: Turns feedback that the user sent about HephaestusV2 into a ticket of the HephaestusV2 project. The first message of a feedback chat calls it with the comment and the feedback context.
---

# Turn feedback into a ticket

This is a feedback chat. The user sent feedback about HephaestusV2 from the window they were using: their comment, followed by the feedback context:

<feedback>
$ARGUMENTS
</feedback>

The user sends feedback with or without a screenshot of that window. When the context has a Screenshot line, the first message of this chat includes the screenshot, saved at the path of that line. When the context has no Screenshot line, the feedback has no screenshot. Your goal is to turn the feedback into a ticket of this chat's project. Work out what the feedback means from the comment, the context and the screenshot when there is one, asking questions when it is unclear, then create its ticket, with the screenshot path as an attachment when there is one, and summarize the ticket. Follow these steps:

1. Read the comment, the context and the screenshot when there is one, then the docs and the code of this project that concern them.
2. List every decision the ticket's implementation needs, as "Writing tickets" says, ask every one still open with ask_questions and end your turn. Continue when the answers arrive, and go to step 3 only once every decision is answered.
3. Call create_ticket with the identifier of this chat's project as projectID, a description that follows the template and holds the answers, and, when the context has a Screenshot line, the screenshot path in attachments. When the feedback reports several problems, create one ticket per problem.
4. Reply with a short summary of the ticket that names its id.

The user can add files to the feedback. The context then has one Attachment line per added file, which gives the path where that file is saved. In step 1, read every added file as well. In step 3, pass the path of every Attachment line in attachments as well, after the screenshot path when there is one, so that the ticket carries every added file.

Implement the ticket in this chat only when the user asks for that, and then use the skill hephaestus-skills:implement-ticket.
