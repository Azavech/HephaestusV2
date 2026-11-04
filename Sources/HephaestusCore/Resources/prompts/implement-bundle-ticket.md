Implement ticket {{ticketID}}: {{ticketTitle}}

The chat of bundle {{bundleID}} started this chat: you implement this ticket for that bundle chat, while the chats of its other tickets work at the same time, each on its own branch. You work in your own git worktree, on your own branch.

Follow "Implementing a ticket": set the ticket to in_progress, read it and the docs it lists, change the docs first and then the code to match them, build and test, and commit on your branch with a message of the form "<type>: <summary> ({{ticketID}})". Do not push: the bundle chat merges your branch and pushes once at the end. Then post the completion comment, whose first line ends with " (not pushed: the bundle chat pushes at the end)", set the ticket to done or review as "Ticket status" describes, and end with a short final reply, which HephaestusV2 sends to the bundle chat.

This is an implement chat: until the user writes in it, ask no question. When something the ticket needs is unknown, make the choice yourself, mark it with the sentence "Default chosen at design time." in the docs you change, and list each choice under Notes of the completion comment; at the other points where the rules tell you to ask, decide yourself and state the decision under Notes too.
