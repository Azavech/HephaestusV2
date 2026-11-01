import Foundation

// The tools of docs/mcp.md › Tool catalogue and › Debug tools, in `tools/list` order, with the
// exact descriptions and input schemas of docs/mcp.md › Tools and › Debug tools. Generated from
// docs/mcp.md; the docs conformance tests compare it with the docs.

extension MCPToolCatalog {
    /// The 42 tools of docs/mcp.md › Tool catalogue, in `tools/list` order.
    public static let tools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_projects",
            description: #"""
            List the projects registered in HephaestusV2 on this Mac, sub projects included: identifier, name, type, root folder, parent, sub projects and ticket counts by status.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {},
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.list",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "get_project",
            description: #"""
            Get a project: its .hephaestus/project.yml settings (name, type, docs folder, build/run/test commands, sub projects, web tabs, enabled skills, chat defaults), root folder, parent, sub projects and git remote URL.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.get",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "create_project",
            description: #"""
            Create a project in a folder on this Mac (the folder is created when missing) and register it in HephaestusV2. The identifier is 2 to 8 letters, unique and permanent: ask the user for the name and the identifier unless they gave them. With parentID the folder must be inside the parent project's folder and the new project becomes its sub project. type is none when omitted.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "path": {
                  "type": "string",
                  "description": "Absolute path of the project folder, or a path starting with ~/."
                },
                "name": {
                  "type": "string",
                  "description": "Project name shown in the app."
                },
                "identifier": {
                  "type": "string",
                  "description": "2 to 8 letters A to Z, stored uppercase, unique on this Mac, never changed."
                },
                "type": {
                  "type": "string",
                  "description": "Project type: none, goService (Go service) or swiftApplication (Swift application).",
                  "enum": ["none", "goService", "swiftApplication"]
                },
                "parentID": {
                  "type": "string",
                  "description": "Identifier of the parent project, to create a sub project."
                }
              },
              "required": ["path", "name", "identifier"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.create",
            handling: .createProject
        ),
        MCPToolDefinition(
            name: "update_project",
            description: #"""
            Change a project's name, type, docs folder or commands. Omitted arguments are left unchanged. commands replaces all three commands: a command that is missing or empty is removed.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "name": {
                  "type": "string",
                  "description": "New project name."
                },
                "type": {
                  "type": "string",
                  "description": "Project type: none, goService (Go service) or swiftApplication (Swift application).",
                  "enum": ["none", "goService", "swiftApplication"]
                },
                "docsPath": {
                  "type": "string",
                  "description": "Docs folder relative to the project root, for example docs."
                },
                "commands": {
                  "type": "object",
                  "description": "Every command of the project; a command that is missing or empty is removed.",
                  "properties": {
                    "build": {
                      "type": "string",
                      "description": "Build command, run by the shell in the project root."
                    },
                    "run": {
                      "type": "string",
                      "description": "Run command, run by the shell in the project root."
                    },
                    "test": {
                      "type": "string",
                      "description": "Test command, run by the shell in the project root."
                    }
                  },
                  "additionalProperties": false
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.update",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "remove_project",
            description: #"""
            Remove a project and its sub projects from HephaestusV2 on this Mac. They are unregistered and their files are left untouched; their runs stop and the Claude processes of their chats end. A chat cannot remove the project it belongs to.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.remove",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "run_project",
            description: #"""
            Run a project's build, run or test command in its root folder, as the app's Build, Run and Test actions do; the output also appears in the app's console. With wait (default: true for build and test, false for run) the call returns when the command exits or when timeoutSeconds (default 600) have passed, with the exit code and the end of the output; the timeout ends the wait, not the run.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "kind": {
                  "type": "string",
                  "description": "Command to run.",
                  "enum": ["build", "run", "test"]
                },
                "wait": {
                  "type": "boolean",
                  "description": "Wait for the command to exit. Default: true for build and test, false for run."
                },
                "timeoutSeconds": {
                  "type": "integer",
                  "description": "Longest wait in seconds when wait is true. Default 600.",
                  "minimum": 1,
                  "maximum": 1700
                }
              },
              "required": ["projectID", "kind"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.run",
            handling: .runProject
        ),
        MCPToolDefinition(
            name: "stop_run",
            description: #"""
            Stop a project run; runID is run.runID of the run_project result.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "runID": {
                  "type": "string",
                  "description": "Run id (a UUID): run.runID of the run_project result."
                }
              },
              "required": ["runID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.stopRun",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "list_tickets",
            description: #"""
            List a project's tickets, optionally only those with one status: todo, in_progress, review or done.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "status": {
                  "type": "string",
                  "description": "Only list tickets with this status.",
                  "enum": ["todo", "in_progress", "review", "done"]
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.list",
            handling: .listTickets
        ),
        MCPToolDefinition(
            name: "get_ticket",
            description: #"""
            Get a ticket: title, status, dates, creator, description, attachments, comments and chat ids. Attachment paths are relative to the project's .hephaestus folder.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                }
              },
              "required": ["ticketID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.get",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "create_ticket",
            description: #"""
            Create a ticket in a project. It starts as todo and its title is generated from the description. The description must use this template, the six headings alone on their lines and in this order:

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

            attachments are paths of files on this Mac (absolute, starting with ~/, or relative to the project root) that are copied into the ticket.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "description": {
                  "type": "string",
                  "description": "Ticket description following the template."
                },
                "attachments": {
                  "type": "array",
                  "description": "Files on this Mac to attach: absolute paths, paths starting with ~/, or paths relative to the project root.",
                  "items": {"type": "string"}
                }
              },
              "required": ["projectID", "description"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.create",
            handling: .attachmentsFromPaths
        ),
        MCPToolDefinition(
            name: "update_ticket",
            description: #"""
            Change a ticket's title or description. Omitted arguments are left unchanged; a new description must follow the same template as create_ticket. Use set_ticket_status for the status and add_comment to report work.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                },
                "title": {
                  "type": "string",
                  "description": "New title, one line."
                },
                "description": {
                  "type": "string",
                  "description": "New description, following the ticket template."
                }
              },
              "required": ["ticketID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.update",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "delete_ticket",
            description: #"""
            Delete a ticket and its attachments; it is also removed from every bundle.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                }
              },
              "required": ["ticketID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.delete",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "set_ticket_status",
            description: #"""
            Set a ticket's status to todo, in_progress, review or done. Set in_progress when you start working on a ticket. When you have finished it, set done if every Claude test of its Testing section has passed and the user has said that every User test has passed, otherwise review. You cannot change the status of a done ticket.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                },
                "status": {
                  "type": "string",
                  "description": "New status.",
                  "enum": ["todo", "in_progress", "review", "done"]
                }
              },
              "required": ["ticketID", "status"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.setStatus",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "add_comment",
            description: #"""
            Add a comment by Claude to a ticket, in markdown, optionally with files attached (paths on this Mac: absolute, starting with ~/, or relative to the project root).
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                },
                "text": {
                  "type": "string",
                  "description": "Comment text (markdown)."
                },
                "attachments": {
                  "type": "array",
                  "description": "Files on this Mac to attach: absolute paths, paths starting with ~/, or paths relative to the project root.",
                  "items": {"type": "string"}
                }
              },
              "required": ["ticketID", "text"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.addComment",
            handling: .attachmentsFromPaths
        ),
        MCPToolDefinition(
            name: "update_comment",
            description: #"""
            Change the text of a comment of a ticket, whoever wrote it. The comment's attached files do not change.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                },
                "commentID": {
                  "type": "string",
                  "description": "Comment id (a UUID), from get_ticket."
                },
                "text": {
                  "type": "string",
                  "description": "New comment text (markdown)."
                }
              },
              "required": ["ticketID", "commentID", "text"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.updateComment",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "delete_comment",
            description: #"""
            Delete a comment of a ticket, whoever wrote it; its attached files are moved to the Trash.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                },
                "commentID": {
                  "type": "string",
                  "description": "Comment id (a UUID), from get_ticket."
                }
              },
              "required": ["ticketID", "commentID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.deleteComment",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "remove_attachment",
            description: #"""
            Remove a file attached to a ticket itself (not to one of its comments); the file is moved to the Trash.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                },
                "attachmentID": {
                  "type": "string",
                  "description": "Attachment id (a UUID), from get_ticket."
                }
              },
              "required": ["ticketID", "attachmentID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "tickets.removeAttachment",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "implement_ticket",
            description: #"""
            Start a new ticket chat that implements the ticket, as the user's Implement button does: a separate Claude session works on it with the project's default chat settings. Returns the new chat.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "ticketID": {
                  "type": "string",
                  "description": "Ticket id, for example HEPH-12."
                }
              },
              "required": ["ticketID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.implementTicket",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "list_bundles",
            description: #"""
            List a project's bundles (named groups of tickets implemented together).
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "bundles.list",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "get_bundle",
            description: #"""
            Get a bundle: title, dates, ticket ids in implementation order and chat ids.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "bundleID": {
                  "type": "string",
                  "description": "Bundle id, for example HEPH-B2."
                }
              },
              "required": ["bundleID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "bundles.get",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "create_bundle",
            description: #"""
            Create a bundle from tickets of one project; ticketIDs is the implementation order and holds at least one ticket. Without title, a title is generated from the ticket titles.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "ticketIDs": {
                  "type": "array",
                  "description": "Ids of tickets of this project, in implementation order.",
                  "items": {"type": "string"}
                },
                "title": {
                  "type": "string",
                  "description": "Bundle title; generated when omitted."
                }
              },
              "required": ["projectID", "ticketIDs"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "bundles.create",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "update_bundle",
            description: #"""
            Change a bundle's title or tickets. Omitted arguments are left unchanged; ticketIDs replaces the whole list, in implementation order.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "bundleID": {
                  "type": "string",
                  "description": "Bundle id, for example HEPH-B2."
                },
                "title": {
                  "type": "string",
                  "description": "New title."
                },
                "ticketIDs": {
                  "type": "array",
                  "description": "Every ticket id of the bundle, in implementation order.",
                  "items": {"type": "string"}
                }
              },
              "required": ["bundleID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "bundles.update",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "delete_bundle",
            description: #"""
            Delete a bundle. Its tickets are not changed.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "bundleID": {
                  "type": "string",
                  "description": "Bundle id, for example HEPH-B2."
                }
              },
              "required": ["bundleID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "bundles.delete",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "implement_bundle",
            description: #"""
            Start a new bundle chat that implements every ticket of the bundle in order, one commit per ticket, as the user's Implement All button does. Returns the new chat.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "bundleID": {
                  "type": "string",
                  "description": "Bundle id, for example HEPH-B2."
                }
              },
              "required": ["bundleID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.implementBundle",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "ask_questions",
            description: #"""
            Ask the user about anything unknown instead of guessing. Give 1 to 26 questions labelled A, B, C… in order; each has the question, 2 to 10 options with distinct labels, and the label of the recommended option. The user can also answer in their own words. The app shows the questions one at a time. This tool returns immediately: end your turn after calling it. The answers arrive in the next user message: "Answers:" followed by one line "<label>: <answer>" per question. Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "questions": {
                  "type": "array",
                  "description": "1 to 26 questions, in the order they are asked.",
                  "items": {
                    "type": "object",
                    "properties": {
                      "label": {
                        "type": "string",
                        "description": "A for the first question, B for the second, C for the third, up to Z."
                      },
                      "question": {
                        "type": "string",
                        "description": "The question."
                      },
                      "options": {
                        "type": "array",
                        "description": "2 to 10 possible answers with distinct labels; the user can also answer another way.",
                        "items": {
                          "type": "object",
                          "properties": {
                            "label": {
                              "type": "string",
                              "description": "The answer, as it is reported when chosen."
                            },
                            "description": {
                              "type": "string",
                              "description": "What choosing this answer implies."
                            }
                          },
                          "required": ["label"],
                          "additionalProperties": false
                        }
                      },
                      "recommended": {
                        "type": "string",
                        "description": "The label of the recommended option, copied exactly."
                      }
                    },
                    "required": ["label", "question", "options", "recommended"],
                    "additionalProperties": false
                  }
                }
              },
              "required": ["questions"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postQuestions",
            handling: .askQuestions
        ),
        MCPToolDefinition(
            name: "list_chats",
            description: #"""
            List a project's chats of every kind (project, ticket, bundle, feedback), most recently updated first, with their title, kind, linked ticket or bundle, settings and state.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.list",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "get_chat",
            description: #"""
            Get a chat with its transcript, for example another chat of the same ticket.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "chatID": {
                  "type": "string",
                  "description": "Chat id (a UUID)."
                }
              },
              "required": ["chatID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.get",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "rename_chat",
            description: #"""
            Rename a chat. The title is one line of 1 to 100 characters; the automatic title never replaces it.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "chatID": {
                  "type": "string",
                  "description": "Chat id (a UUID)."
                },
                "title": {
                  "type": "string",
                  "description": "New title, one line."
                }
              },
              "required": ["chatID", "title"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.rename",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "search",
            description: #"""
            Search HephaestusV2: projects, tickets, bundles, docs, code, chats, skills and web tabs. Matching is case-insensitive and every whitespace-separated term must appear. projectID limits the search to one project; scopes limits the kinds searched. Each result has a target that open_in_app accepts.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "query": {
                  "type": "string",
                  "description": "Search terms."
                },
                "scopes": {
                  "type": "array",
                  "description": "Kinds to search; every kind when omitted or empty.",
                  "items": {
                    "type": "string",
                    "enum": ["projects", "tickets", "bundles", "docs", "code", "chats", "skills", "web"]
                  }
                },
                "projectID": {
                  "type": "string",
                  "description": "Search only this project; every project when omitted."
                }
              },
              "required": ["query"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "search.query",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "list_docs",
            description: #"""
            List the markdown documents in a project's docs folder with their titles. Paths are relative to the project root.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "docs.list",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "list_web_tabs",
            description: #"""
            List a project's web tabs in tab order with their URL, title and lock state.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "webTabs.list",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "open_web_tab",
            description: #"""
            Add a web tab at the end of a project's tab strip, on every device showing the project. A locked tab cannot be closed until it is unlocked.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "url": {
                  "type": "string",
                  "description": "Absolute http or https URL."
                },
                "title": {
                  "type": "string",
                  "description": "Tab title; the URL's host when omitted."
                },
                "locked": {
                  "type": "boolean",
                  "description": "Lock the tab. Default false."
                }
              },
              "required": ["projectID", "url"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "webTabs.open",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "update_web_tab",
            description: #"""
            Change a web tab of a project: load another URL, rename it or lock it. Omitted arguments are left unchanged. Only the user can unlock a tab.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "tabID": {
                  "type": "string",
                  "description": "Web tab id (a UUID), from list_web_tabs."
                },
                "url": {
                  "type": "string",
                  "description": "Absolute http or https URL."
                },
                "title": {
                  "type": "string",
                  "description": "Tab title."
                },
                "locked": {
                  "type": "boolean",
                  "description": "true locks the tab; false is refused."
                }
              },
              "required": ["projectID", "tabID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "webTabs.update",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "move_web_tab",
            description: #"""
            Move a web tab of a project to another position of its tab strip; 0 is the first position.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "tabID": {
                  "type": "string",
                  "description": "Web tab id (a UUID), from list_web_tabs."
                },
                "toIndex": {
                  "type": "integer",
                  "description": "New position, starting at 0.",
                  "minimum": 0
                }
              },
              "required": ["projectID", "tabID", "toIndex"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "webTabs.move",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "close_web_tab",
            description: #"""
            Close a web tab of a project on every device. A locked tab cannot be closed.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "tabID": {
                  "type": "string",
                  "description": "Web tab id (a UUID), from list_web_tabs."
                }
              },
              "required": ["projectID", "tabID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "webTabs.close",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "list_skills",
            description: #"""
            List the skills of the HephaestusV2 skills library (not those in ~/.claude) with their descriptions.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {},
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "skills.list",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "get_skill",
            description: #"""
            Get a library skill: name, description, SKILL.md body, extra frontmatter and extra files.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "description": "Name of a library skill."
                }
              },
              "required": ["name"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "skills.get",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "create_skill",
            description: #"""
            Create a skill in the HephaestusV2 skills library: a folder with a SKILL.md made of the name, the description and the body. The name is lowercase letters and digits in groups joined by single hyphens, 1 to 64 characters; the description has 1 to 1024 characters. The user enables skills per project in the app.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "description": "Skill name: lowercase letters and digits in groups joined by single hyphens, 1 to 64 characters."
                },
                "description": {
                  "type": "string",
                  "description": "What the skill does and when Claude should use it, 1 to 1024 characters."
                },
                "body": {
                  "type": "string",
                  "description": "SKILL.md content after the frontmatter (markdown); may be empty."
                }
              },
              "required": ["name", "description", "body"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "skills.create",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "update_skill",
            description: #"""
            Rename a library skill or change its description or SKILL.md body. Omitted arguments are left unchanged. A renamed skill stays enabled in the projects that use it.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "description": "Current name of the skill."
                },
                "newName": {
                  "type": "string",
                  "description": "New name: lowercase letters and digits in groups joined by single hyphens, 1 to 64 characters."
                },
                "description": {
                  "type": "string",
                  "description": "New description, 1 to 1024 characters."
                },
                "body": {
                  "type": "string",
                  "description": "New SKILL.md content after the frontmatter (markdown)."
                }
              },
              "required": ["name"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "skills.update",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "delete_skill",
            description: #"""
            Delete a library skill: its folder is moved to the Trash and no project uses it any more.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "description": "Name of the skill to delete."
                }
              },
              "required": ["name"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "skills.delete",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "set_skill_enabled",
            description: #"""
            Enable or disable a library skill in a project. Chats of the project started afterwards get the skills it enables.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "projectID": {
                  "type": "string",
                  "description": "Project identifier: 2 to 8 letters, for example HEPH."
                },
                "name": {
                  "type": "string",
                  "description": "Name of a library skill."
                },
                "enabled": {
                  "type": "boolean",
                  "description": "true enables the skill in the project, false disables it."
                }
              },
              "required": ["projectID", "name", "enabled"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "skills.setEnabled",
            handling: .forward
        ),
        MCPToolDefinition(
            name: "open_in_app",
            description: #"""
            Show something to the user in HephaestusV2: a project, ticket, bundle, chat, doc (optionally at a heading), file (optionally at a line) or folder of the code tree, skill, web tab or project section. The app shows it on the device the user is chatting from.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "target": {
                  "type": "object",
                  "description": "What to show. kind decides the other properties: project: projectID; ticket: ticketID; bundle: bundleID; chat: chatID; doc: projectID, path and optionally fragment; file: projectID, path and optionally line; skill: name; webTab: projectID and tabID; section: projectID and section.",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "description": "Kind of item to show.",
                      "enum": ["project", "ticket", "bundle", "chat", "doc", "file", "skill", "webTab", "section"]
                    },
                    "projectID": {
                      "type": "string",
                      "description": "Project identifier: 2 to 8 letters, for example HEPH."
                    },
                    "ticketID": {
                      "type": "string",
                      "description": "Ticket id, for example HEPH-12."
                    },
                    "bundleID": {
                      "type": "string",
                      "description": "Bundle id, for example HEPH-B2."
                    },
                    "chatID": {
                      "type": "string",
                      "description": "Chat id (a UUID)."
                    },
                    "path": {
                      "type": "string",
                      "description": "Path relative to the project root, as list_docs returns for a doc."
                    },
                    "fragment": {
                      "type": "string",
                      "description": "Heading anchor of the doc to scroll to, without #, for example menus-and-keyboard-shortcuts."
                    },
                    "line": {
                      "type": "integer",
                      "description": "Line to show in the file, starting at 1."
                    },
                    "name": {
                      "type": "string",
                      "description": "Skill name."
                    },
                    "tabID": {
                      "type": "string",
                      "description": "Web tab id (a UUID)."
                    },
                    "section": {
                      "type": "string",
                      "description": "Project section to show.",
                      "enum": ["dashboard", "tickets", "bundles", "chats", "code", "docs", "web", "skills", "costs", "settings"]
                    }
                  },
                  "required": ["kind"],
                  "additionalProperties": false
                }
              },
              "required": ["target"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "ui.open",
            handling: .openInApp
        ),
    ]

    /// The 3 debug tools of docs/mcp.md › Debug tool catalogue, in the order `tools/list`
    /// appends them when debug tools are enabled.
    public static let debugTools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "debug_screenshot",
            description: #"""
            Debug: capture a HephaestusV2 window of this Mac to a PNG file, without screen-recording permission, and return its path and size in pixels. window is an id from debug_ui_state; the key window when omitted.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "window": {
                  "type": "integer",
                  "description": "Window id from debug_ui_state; the key window when omitted."
                }
              },
              "additionalProperties": false
            }
            """#),
            isDebug: true,
            engineMethod: nil,
            handling: .debugUI
        ),
        MCPToolDefinition(
            name: "debug_navigate",
            description: #"""
            Debug: navigate the frontmost main HephaestusV2 window, switched to this Mac when needed (a new one when there is none), to a target, same shape as open_in_app, and return that window's information once its state is updated.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "target": {
                  "type": "object",
                  "description": "What to show. kind decides the other properties: project: projectID; ticket: ticketID; bundle: bundleID; chat: chatID; doc: projectID, path and optionally fragment; file: projectID, path and optionally line; skill: name; webTab: projectID and tabID; section: projectID and section.",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "description": "Kind of item to show.",
                      "enum": ["project", "ticket", "bundle", "chat", "doc", "file", "skill", "webTab", "section"]
                    },
                    "projectID": {
                      "type": "string",
                      "description": "Project identifier: 2 to 8 letters, for example HEPH."
                    },
                    "ticketID": {
                      "type": "string",
                      "description": "Ticket id, for example HEPH-12."
                    },
                    "bundleID": {
                      "type": "string",
                      "description": "Bundle id, for example HEPH-B2."
                    },
                    "chatID": {
                      "type": "string",
                      "description": "Chat id (a UUID)."
                    },
                    "path": {
                      "type": "string",
                      "description": "Path relative to the project root, as list_docs returns for a doc."
                    },
                    "fragment": {
                      "type": "string",
                      "description": "Heading anchor of the doc to scroll to, without #, for example menus-and-keyboard-shortcuts."
                    },
                    "line": {
                      "type": "integer",
                      "description": "Line to show in the file, starting at 1."
                    },
                    "name": {
                      "type": "string",
                      "description": "Skill name."
                    },
                    "tabID": {
                      "type": "string",
                      "description": "Web tab id (a UUID)."
                    },
                    "section": {
                      "type": "string",
                      "description": "Project section to show.",
                      "enum": ["dashboard", "tickets", "bundles", "chats", "code", "docs", "web", "skills", "costs", "settings"]
                    }
                  },
                  "required": ["kind"],
                  "additionalProperties": false
                }
              },
              "required": ["target"],
              "additionalProperties": false
            }
            """#),
            isDebug: true,
            engineMethod: nil,
            handling: .debugUI
        ),
        MCPToolDefinition(
            name: "debug_ui_state",
            description: #"""
            Debug: list the HephaestusV2 windows of this Mac from front to back with their id, kind, title, key state, frame and UI state (device, project, section, selection).
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {},
              "additionalProperties": false
            }
            """#),
            isDebug: true,
            engineMethod: nil,
            handling: .debugUI
        ),
    ]
}
