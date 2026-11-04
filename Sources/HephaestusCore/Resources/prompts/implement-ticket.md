Implement ticket {{ticketID}}: {{ticketTitle}}

Follow "Implementing a ticket": set the ticket to in_progress, read it and the docs it lists, change the docs first and then the code to match them, build and test, commit with a message of the form "<type>: <summary> ({{ticketID}})", push, post the completion comment, set the ticket to done or review as "Ticket status" describes, and end with a short final reply.

This is an implement chat: until the user writes in it, ask no question. When something the ticket needs is unknown, make the choice yourself, mark it with the sentence "Default chosen at design time." in the docs you change, and list each choice under Notes of the completion comment; at the other points where the rules tell you to ask, decide yourself and state the decision under Notes too.

In a Go service project, follow "When the project is a Go service" after the push: post the completion comment with the Claude tests waiting for the test service, wait for CI, run the test service and the checks, then update the completion comment and set the status.
