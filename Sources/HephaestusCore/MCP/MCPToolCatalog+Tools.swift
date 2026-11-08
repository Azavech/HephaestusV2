import Foundation

// The tools of docs/mcp.md › Tool catalogue, › Kubernetes and Argo CD tools and › Debug tools, in
// `tools/list` order, with the exact descriptions and input schemas of docs/mcp.md › Tools,
// › Kubernetes and Argo CD tools and › Debug tools. Generated from docs/mcp.md; the docs
// conformance tests compare it with the docs.

extension MCPToolCatalog {
    /// The 50 tools of docs/mcp.md › Tool catalogue, then the 9 tools of docs/mcp.md › Kubernetes
    /// and Argo CD tools, in `tools/list` order.
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
            Get a project: its .hephaestus/project.yml settings (name, type, color, icon, docs folder, GitHub page, use parent settings, sub projects, web tabs, enabled skills, chat defaults, own environments, changes to inherited environments), root folder, parent, sub projects, git remote URL, GitHub page (githubPage: its parent's for a sub project that uses its parent's settings, else the page set in Project Settings, else the page of its origin remote on GitHub) and environments (environments: those that apply, for a sub project that uses its parent's settings its parent's environments with its changes first, then its own; inheritedEnvironments: the parent's environments it inherits; currentEnvironment: the name of the current working environment, to use when the user names no environment).
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
            Create a project in a folder on this Mac (the folder is created when missing) and register it in HephaestusV2. The identifier is 2 to 8 letters, unique and permanent: ask the user for the name and the identifier unless they gave them. HEPH is reserved for HephaestusV2. With parentID the folder must be inside the parent project's folder and the new project becomes its sub project. type is none when omitted.
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
            Change a project's name, type, color, icon or docs folder. Omitted arguments are left unchanged. color is a hex color #RRGGBB, and an empty color removes it. icon is the name of an SF Symbol of this Mac, for example hammer, and an empty or null icon removes it.
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
                "color": {
                  "type": "string",
                  "description": "Color of the project's badge in the ticket list: #RRGGBB, for example #34C759; an empty string removes it."
                },
                "icon": {
                  "type": "string",
                  "description": "Name of an SF Symbol of this Mac shown as the project's icon, for example hammer; an empty string or null removes it."
                },
                "docsPath": {
                  "type": "string",
                  "description": "Docs folder relative to the project root, for example docs."
                }
              },
              "required": ["projectID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "projects.update",
            handling: .updateProject
        ),
        MCPToolDefinition(
            name: "remove_project",
            description: #"""
            Remove a project and its sub projects from HephaestusV2 on this Mac. They are unregistered and their files are left untouched; the Claude processes of their chats end. A chat cannot remove the project it belongs to, and the HephaestusV2 project and its ancestors cannot be removed.
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
            name: "list_tickets",
            description: #"""
            List a project's tickets, those of its sub projects included, optionally only those with one status: todo, in_progress, review or done.
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
            Get a ticket: title, status, dates, creator, description, attachments, comments, chat ids, links and history. links are the links the ticket declares (dependsOn, related); inverseLinks are the links other tickets declare to it (blocks, related). history lists its creation, status changes and renames with their authors and dates. Attachment paths are absolute paths on this Mac.
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
            handling: .getTicket
        ),
        MCPToolDefinition(
            name: "create_ticket",
            description: #"""
            Create a ticket in a project. It starts as todo. Its title is generated from the description before the call returns; when the generation fails, the ticket keeps a provisional title taken from the description. The description must use this template, the six headings alone on their lines and in this order:

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

            attachments are paths of files on this Mac (absolute, starting with ~/, or relative to the project root) that are copied into the ticket. links are links to other tickets of the same project: dependsOn when this ticket needs the other ticket to be done first, related when they are only related.
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
                },
                "links": {
                  "type": "array",
                  "description": "Links to other tickets of the same project.",
                  "items": {
                    "type": "object",
                    "properties": {
                      "kind": {
                        "type": "string",
                        "description": "dependsOn when this ticket needs the other ticket to be done first, related otherwise.",
                        "enum": ["dependsOn", "related"]
                      },
                      "ticket": {
                        "type": "string",
                        "description": "Id of a ticket of the same project, for example HEPH-15."
                      }
                    },
                    "required": ["kind", "ticket"],
                    "additionalProperties": false
                  }
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
            Change a ticket's title, description or links. Omitted arguments are left unchanged; a new description must follow the same template as create_ticket; links replaces the links the ticket declares, so list every link to keep, and [] removes them all. Use set_ticket_status for the status and add_comment to report work.
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
                },
                "links": {
                  "type": "array",
                  "description": "The links this ticket declares, replacing the current ones: every link to keep and the new ones; [] removes them all.",
                  "items": {
                    "type": "object",
                    "properties": {
                      "kind": {
                        "type": "string",
                        "description": "dependsOn when this ticket needs the other ticket to be done first, related otherwise.",
                        "enum": ["dependsOn", "related"]
                      },
                      "ticket": {
                        "type": "string",
                        "description": "Id of a ticket of the same project, for example HEPH-15."
                      }
                    },
                    "required": ["kind", "ticket"],
                    "additionalProperties": false
                  }
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
            Set a ticket's status to todo, in_progress, review or done. Set in_progress when you start working on a ticket. When you have finished it, set done if every Claude test of its Testing section has passed and the user has said that every User test has passed, otherwise review. A code-test bullet of the Testing section (a build or test command, a unit test, a test file or the docs conformance tests) counts as passed once a release built by CI contains the ticket's commit. You cannot change the status of a done ticket.
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
            Start a new ticket chat that implements the ticket, as the user's Implement button does: a separate Claude session works on it with the project's default chat settings. Called from a bundle chat for a ticket of its bundle, the new chat takes the bundle chat's settings, works on the new branch <bundle id>/<ticket id> in its own git worktree, commits there without pushing and reports each of its turns back to the bundle chat. Returns the new chat.
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
            name: "set_bundle_status",
            description: #"""
            Set a bundle's status to todo or in_progress. Implement All and implement_bundle set in_progress themselves. The engine sets done when every ticket is done; only the user sets done otherwise, and you cannot change the status of a done bundle.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "bundleID": {
                  "type": "string",
                  "description": "Bundle id, for example HEPH-B2."
                },
                "status": {
                  "type": "string",
                  "description": "New status.",
                  "enum": ["todo", "in_progress"]
                }
              },
              "required": ["bundleID", "status"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "bundles.setStatus",
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
            Start a new bundle chat that implements every ticket of the bundle, as the user's Implement All button does: it starts at once a ticket chat on its own branch for every ticket that waits for no other ticket, merges the branches with one commit per ticket, and pushes once at the end. Returns the new chat.
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
            Ask the user about anything unknown instead of guessing. Give 1 to 26 questions labelled A, B, C… in order; each has the question, 2 to 10 options with distinct labels, and the label of the recommended option. When several options of a question can apply at once, give it kind "multiple": the user checks every option that applies, recommended is the list of the labels of the options you recommend, and minChoices and maxChoices bound the number of choices. The user can also answer in their own words. The app shows the questions one at a time. This tool returns immediately: end your turn after calling it. The answers arrive in the next user message: "Answers:" followed by one line "<label>: <answer>" per question; a multiple question reads "<label>:" followed by one line "- <choice>" per choice. Only available in chats started by HephaestusV2.
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
                      "kind": {
                        "type": "string",
                        "enum": ["single", "multiple"],
                        "description": "single (when absent): the user chooses one option. multiple: the user checks every option that applies and can add own answers; use it when several options can apply at once."
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
                        "description": "single: the label of the recommended option, copied exactly. multiple: the list of the labels of the recommended options, copied exactly."
                      },
                      "minChoices": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "multiple only: the fewest choices the user makes, checked options and own answers together; 1 when absent."
                      },
                      "maxChoices": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "multiple only: the most choices the user makes, checked options and own answers together; no maximum when absent."
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
            name: "ask_symbol",
            description: #"""
            Ask the user to choose one SF Symbol, instead of listing symbol names in ask_questions. Give the question, 2 to 10 suggested SF Symbol names and the recommended one. The app shows the suggestions as icons, the recommended one preselected, with a search over every SF Symbol of the Mac; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Symbol: ![](sf:<name>)" for a chosen symbol, "Symbol: <answer>" for an answer in the user's own words, or "Symbol: Skipped". Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "The question."
                },
                "suggestions": {
                  "type": "array",
                  "description": "2 to 10 distinct SF Symbol names, for example line.3.horizontal.decrease.circle.",
                  "items": {
                    "type": "string"
                  }
                },
                "recommended": {
                  "type": "string",
                  "description": "The recommended symbol: one of the suggestions, copied exactly."
                }
              },
              "required": ["question", "suggestions", "recommended"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postSymbol",
            handling: .askSymbol
        ),
        MCPToolDefinition(
            name: "ask_color",
            description: #"""
            Ask the user to choose one color, instead of listing color values in ask_questions. A color is a hex color #RRGGBB (sRGB, without opacity) or a system color name such as systemBlue, label or accentColor. Give the question, 2 to 10 suggested colors and the recommended one. Set lightAndDark when the destination of the color supports light and dark appearances, for example an asset catalog color set: each suggestion and recommended are then objects {"light": "<color>", "dark": "<color>"}. The app shows the suggestions as swatches, the recommended one preselected, with every system color, the macOS color panel and a hex field; the user can switch between one color and a light and dark pair, answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Color: ![](color:<color>)" for one color, "Color: Light ![](color:<color>), Dark ![](color:<color>)" for a pair, "Color: <answer>" for an answer in the user's own words, or "Color: Skipped". Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "The question."
                },
                "suggestions": {
                  "type": "array",
                  "description": "2 to 10 distinct suggestions. Each is a color, a hex color #RRGGBB or a system color name such as systemBlue; with lightAndDark, each is an object {\"light\": \"<color>\", \"dark\": \"<color>\"}.",
                  "items": {
                    "description": "A color, or with lightAndDark an object {\"light\": \"<color>\", \"dark\": \"<color>\"}."
                  }
                },
                "recommended": {
                  "description": "The recommended suggestion: one of the suggestions, copied exactly."
                },
                "lightAndDark": {
                  "type": "boolean",
                  "description": "true to ask for a light and dark pair, when the destination of the color supports light and dark appearances, for example an asset catalog color set."
                }
              },
              "required": ["question", "suggestions", "recommended"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postColor",
            handling: .askColor
        ),
        MCPToolDefinition(
            name: "ask_sound",
            description: #"""
            Ask the user to choose one sound for an app of an Apple platform, instead of listing sound names in ask_questions. Only available in projects of type Swift application. Give the question, 2 to 10 suggested sound names and the recommended one. A sound name is macOS/<file> for a sound of /System/Library/Sounds, for example macOS/Glass.aiff; <runtime>/<path> for a sound under System/Library/Audio/UISounds of an installed Simulator runtime, <runtime> being the runtime's name in xcrun simctl list runtimes, for example iOS 26.1/sms-received1.caf; or Project/<path from the project root> for a .caf, .aiff, .wav or .mp3 file of the project, for example Project/Sounds/alert.caf. The app lists the suggestions, the recommended one preselected, with a search over every sound of the Mac and the project, and plays the sound the user selects; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Sound: ![](sound:<name>)" for a chosen sound, "Sound: <answer>" for an answer in the user's own words, or "Sound: Skipped". Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "The question."
                },
                "suggestions": {
                  "type": "array",
                  "description": "2 to 10 distinct sound names, for example macOS/Glass.aiff or iOS 26.1/sms-received1.caf.",
                  "items": {
                    "type": "string"
                  }
                },
                "recommended": {
                  "type": "string",
                  "description": "The recommended sound: one of the suggestions, copied exactly."
                }
              },
              "required": ["question", "suggestions", "recommended"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postSound",
            handling: .askSound
        ),
        MCPToolDefinition(
            name: "ask_shortcut",
            description: #"""
            Ask the user to choose one keyboard shortcut, instead of listing shortcuts in ask_questions. Only available in projects of type Swift application. Write each shortcut in macOS menu notation: the modifiers ⌃ ⌥ ⇧ ⌘ in this order, then one key: an uppercase letter, a digit or punctuation as typed without Shift, ↩ ⌤ ⎋ ⇥ Space ⌫ ⌦ ← → ↑ ↓ ↖ ↘ ⇞ ⇟, or F1 to F20, for example ⇧⌘K, ⇧⌘/ or ⌃⌥Space. Give the question, 2 to 10 suggested shortcuts, the recommended one, and in inUse every shortcut the app already uses with its command name. The app shows the suggestions as key caps, the recommended one preselected, lets the user record another combination, and warns when the selected shortcut is a standard macOS shortcut or one of inUse; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Shortcut: ![](shortcut:<shortcut>)" for a chosen or recorded shortcut, "Shortcut: <answer>" for an answer in the user's own words, or "Shortcut: Skipped". Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "The question."
                },
                "suggestions": {
                  "type": "array",
                  "description": "2 to 10 distinct shortcuts in macOS menu notation, for example ⇧⌘K.",
                  "items": {
                    "type": "string"
                  }
                },
                "recommended": {
                  "type": "string",
                  "description": "The recommended shortcut: one of the suggestions, copied exactly."
                },
                "inUse": {
                  "type": "array",
                  "description": "Every shortcut the app already uses, with the name of its command, for example ⌘N with New Ticket; an empty array when the app has none.",
                  "items": {
                    "type": "object",
                    "properties": {
                      "shortcut": {
                        "type": "string",
                        "description": "The shortcut, in the same notation."
                      },
                      "command": {
                        "type": "string",
                        "description": "The name of the command that uses it."
                      }
                    },
                    "required": ["shortcut", "command"],
                    "additionalProperties": false
                  }
                }
              },
              "required": ["question", "suggestions", "recommended", "inUse"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postShortcut",
            handling: .askShortcut
        ),
        MCPToolDefinition(
            name: "ask_font",
            description: #"""
            Ask the user to choose one font, instead of listing font names in ask_questions. Give the question, a sample text taken from where the font will be used, 2 to 10 suggested fonts and the recommended one. A font is a Dynamic Type text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17: the family is System, System Rounded, System Serif, System Monospaced, a font family installed on the Mac or the family of a font file of the project, the weight one of the family's weights, the size 1 to 999 points with at most one decimal. The app shows the suggestions drawn in their fonts, the recommended one preselected, weight and size controls, the sample drawn in the selected font and a search over every font of the Mac and of the project; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Font: ![](font:<font>)" for a chosen font, "Font: <answer>" for an answer in the user's own words, or "Font: Skipped". Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "The question."
                },
                "sample": {
                  "type": "string",
                  "description": "The sample text the app draws in the selected font, taken from where the font will be used."
                },
                "suggestions": {
                  "type": "array",
                  "description": "2 to 10 distinct fonts: a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17.",
                  "items": {
                    "type": "string"
                  }
                },
                "recommended": {
                  "type": "string",
                  "description": "The recommended font: one of the suggestions, copied exactly."
                }
              },
              "required": ["question", "sample", "suggestions", "recommended"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postFont",
            handling: .askFont
        ),
        MCPToolDefinition(
            name: "ask_animation",
            description: #"""
            Ask the user to choose one SwiftUI animation, instead of listing animation expressions in ask_questions. Only available in projects of type Swift application. Give the question, 2 to 10 suggested animations written as SwiftUI expressions and the recommended one. An animation is .smooth, .snappy or .bouncy with (duration:extraBounce:), .spring with (duration:bounce:), or .easeIn, .easeOut, .easeInOut or .linear with (duration:), with its parameters or without them (SwiftUI's defaults), for example .spring(duration: 0.4, bounce: 0.2); duration goes from 0.1 to 2, bounce from -1 to 1 and extraBounce from 0 to 1. The app plays each suggestion as a circle sliding along a lane, the recommended one preselected, with a Custom row where the user sets a preset and its parameters; the user can also answer in their own words or skip. This tool returns immediately: end your turn after calling it. The answer arrives in the next user message: "Animation: ![](animation:<expression>)" for a chosen animation, "Animation: <answer>" for an answer in the user's own words, or "Animation: Skipped". Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "The question."
                },
                "suggestions": {
                  "type": "array",
                  "description": "2 to 10 distinct SwiftUI animation expressions, for example .spring(duration: 0.4, bounce: 0.2).",
                  "items": {
                    "type": "string"
                  }
                },
                "recommended": {
                  "type": "string",
                  "description": "The recommended animation: one of the suggestions, copied exactly."
                }
              },
              "required": ["question", "suggestions", "recommended"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postAnimation",
            handling: .askAnimation
        ),
        MCPToolDefinition(
            name: "show_image",
            description: #"""
            Show the user one or more images in this chat, for example an image you rendered or a screenshot you took. Give the paths of the image files on this Mac (absolute, starting with ~/, or relative to the project root) and an optional caption in markdown. Only PNG, JPEG, GIF and WebP files are accepted; any other file or a missing path fails the whole call. The app copies the images into the chat, so they stay visible after the files are deleted, and shows the caption and the images at the place of the call; clicking an image opens it in the image viewer. Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "paths": {
                  "type": "array",
                  "description": "1 to 10 image files on this Mac, shown in this order: absolute paths, paths starting with ~/, or paths relative to the project root.",
                  "items": {"type": "string"}
                },
                "caption": {
                  "type": "string",
                  "description": "Text shown above the images (markdown)."
                }
              },
              "required": ["paths"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.postImages",
            handling: .showImage
        ),
        MCPToolDefinition(
            name: "list_chats",
            description: #"""
            List a project's chats of every kind (project, ticket, bundle, feedback, ci), most recently updated first, with their title, kind, linked ticket or bundle, settings and state.
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
            name: "close_chat",
            description: #"""
            Close the chat you run in, or with chatIDs chats of your project. Without chatIDs it closes the chat you run in: you can still finish your reply; when your turn ends, HephaestusV2 ends your session and the chat shows "This conversation is over" until the user reopens it. Call it when the user asks you to close the chat, or when the work of the chat is finished. chatIDs lists chats of your project to close at once; your own chat's id in it closes your chat as without chatIDs. Close another chat only when the user asked you to close it, never on your own, except the ticket chats and CI chats you started as their orchestrator, which you close when your task is done. A listed chat whose turn is in progress, a chat of another project and an unknown id are not closed: the result lists each one in refused, with the reason. Only available in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "chatIDs": {
                  "type": "array",
                  "description": "Ids of chats of your project to close (UUIDs). Omit it to close the chat you run in.",
                  "items": {"type": "string"}
                }
              },
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.close",
            handling: .closeChat
        ),
        MCPToolDefinition(
            name: "watch_ci",
            description: #"""
            Start a CI chat that follows the CI of a commit you pushed: a separate Claude session waits with the gh CLI for every workflow run of the commit on the project's GitHub repository, then reports to this chat when its turn ends, with a final reply whose first line is "CI passed.", "CI failed." or "CI not checked.". Call it after the push of an implementation, from the ticket or bundle chat that pushed, in a project that has a GitHub page; then end your turn. Returns the new chat.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "commit": {
                  "type": "string",
                  "description": "Full hash of the pushed commit, as git rev-parse HEAD prints it."
                }
              },
              "required": ["commit"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "chats.watchCI",
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
            List a project's web tabs in tab order with their URL, title and lock state. A locked tab also has its original URL, the page it goes back to each time the user comes back to it. githubTab marks the two tabs that HephaestusV2 keeps first in a project with a GitHub page: page, its GitHub page, and ci, its CI page; they cannot be closed, unlocked or moved.
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
            Add a web tab at the end of a project's tab strip, on every device showing the project. A locked tab cannot be closed until it is unlocked, and goes back to this URL each time the user comes back to it.
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
            Change a web tab of a project: load another URL, rename it or lock it. Omitted arguments are left unchanged. Only the user can unlock a tab. Locking a tab makes its URL its original URL, the page it goes back to each time the user comes back to it; loading another URL in a locked tab keeps its original URL, so show another page in a new tab with open_web_tab.
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
            Move a web tab of a project to another position of its tab strip; 0 is the first position. The GitHub tabs (githubTab page and ci) cannot be moved, and no tab can be moved before them.
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
                      "enum": ["dashboard", "tickets", "bundles", "chats", "code", "docs", "web", "builds", "skills", "memories", "costs", "apiExplorer", "settings"]
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
        MCPToolDefinition(
            name: "k8s_status",
            description: #"""
            Get the state of the Kubernetes deployment of an environment of this Go service project: its desired, ready, updated and available replicas, its container images and conditions, and its pods with their phase, ready containers, restarts, age and node. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                }
              },
              "required": ["environment"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "kubernetes.status",
            handling: .kubernetesJSON
        ),
        MCPToolDefinition(
            name: "k8s_logs",
            description: #"""
            Get the last log lines of the pods of the Kubernetes deployment of an environment of this Go service project, each line prefixed with [pod/<pod>/<container>], or of one pod with pod. container picks the container (default: each pod's default container), tailLines the number of lines per container (default 200, at most 5000), sinceSeconds keeps the lines of the last seconds only, and previous gives the logs of the previous container, the one that ended, for example after a crash. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                },
                "pod": {
                  "type": "string",
                  "description": "Name of one pod; every pod of the deployment when omitted."
                },
                "container": {
                  "type": "string",
                  "description": "Name of the container; each pod's default container when omitted."
                },
                "tailLines": {
                  "type": "integer",
                  "description": "Number of last lines of each container. Default 200.",
                  "minimum": 1,
                  "maximum": 5000
                },
                "sinceSeconds": {
                  "type": "integer",
                  "description": "Keep only the lines of the last sinceSeconds seconds.",
                  "minimum": 1,
                  "maximum": 2147483647
                },
                "previous": {
                  "type": "boolean",
                  "description": "Get the logs of the previous container, the one that ended, for example after a crash."
                }
              },
              "required": ["environment"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "kubernetes.logs",
            handling: .kubernetesLogs
        ),
        MCPToolDefinition(
            name: "k8s_events",
            description: #"""
            Get the Kubernetes events of the deployment of an environment of this Go service project, of its ReplicaSets and of its pods, newest first, each with its type, reason, object, message, count and times. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                }
              },
              "required": ["environment"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "kubernetes.events",
            handling: .kubernetesJSON
        ),
        MCPToolDefinition(
            name: "k8s_restart",
            description: #"""
            Restart the pods of the Kubernetes deployment of an environment of this Go service project with kubectl rollout restart: Kubernetes replaces them as the deployment's rollout strategy says; follow it with k8s_status. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                }
              },
              "required": ["environment"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "kubernetes.restart",
            handling: .kubernetesText
        ),
        MCPToolDefinition(
            name: "k8s_scale",
            description: #"""
            Set the number of replicas of the Kubernetes deployment of an environment of this Go service project with kubectl scale; 0 stops every pod. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                },
                "replicas": {
                  "type": "integer",
                  "description": "Number of pods the deployment runs; 0 stops every pod.",
                  "minimum": 0,
                  "maximum": 2147483647
                }
              },
              "required": ["environment", "replicas"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "kubernetes.scale",
            handling: .kubernetesText
        ),
        MCPToolDefinition(
            name: "k8s_port_forward",
            description: #"""
            Forward a local port of this Mac to a port of the Kubernetes deployment of an environment of this Go service project with kubectl port-forward, to call the service in one of its pods. remotePort is the port in the pod; localPort is the port on 127.0.0.1, a free port when omitted. Returns the port forward's portForwardID and its url http://127.0.0.1:<localPort>. The forward lasts until k8s_stop_port_forward with its portForwardID, until kubectl ends it, or until this chat's Claude process exits. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file and namespace. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                },
                "remotePort": {
                  "type": "integer",
                  "description": "Port in the pod, for example 8080.",
                  "minimum": 1,
                  "maximum": 65535
                },
                "localPort": {
                  "type": "integer",
                  "description": "Port on 127.0.0.1 of this Mac; a free port when omitted.",
                  "minimum": 1,
                  "maximum": 65535
                }
              },
              "required": ["environment", "remotePort"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "kubernetes.forward",
            handling: .kubernetesJSON
        ),
        MCPToolDefinition(
            name: "k8s_stop_port_forward",
            description: #"""
            Stop a port forward that this chat started with k8s_port_forward. portForwardID is the portForwardID of its result. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "portForwardID": {
                  "type": "string",
                  "description": "Port forward id (a UUID): portForwardID of the k8s_port_forward result."
                }
              },
              "required": ["portForwardID"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "kubernetes.stopForward",
            handling: .kubernetesJSON
        ),
        MCPToolDefinition(
            name: "argocd_status",
            description: #"""
            Get the state of the Argo CD Application of an environment of this Go service project: its sync status, health status, synced revision and last operation, read with kubectl from the Application resource. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file, in the namespace of the Application. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                }
              },
              "required": ["environment"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "argoCD.status",
            handling: .kubernetesJSON
        ),
        MCPToolDefinition(
            name: "argocd_sync",
            description: #"""
            Start a sync of the Argo CD Application of an environment of this Go service project to its target revision, with Argo CD's default sync options, by setting the Application's sync operation with kubectl; follow it with argocd_status. Fails while the Application has an operation in progress. environment is the name of one of the project's environments, as get_project lists them; HephaestusV2 runs kubectl with that environment's kubeconfig file, in the namespace of the Application. Only available in projects of type Go service, in chats started by HephaestusV2.
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "environment": {
                  "type": "string",
                  "description": "Name of an environment of the project, for example staging."
                }
              },
              "required": ["environment"],
              "additionalProperties": false
            }
            """#),
            isDebug: false,
            engineMethod: "argoCD.sync",
            handling: .kubernetesText
        ),
    ]

    /// The 4 debug tools of docs/mcp.md › Debug tool catalogue, in the order `tools/list`
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
                      "enum": ["dashboard", "tickets", "bundles", "chats", "code", "docs", "web", "builds", "skills", "memories", "costs", "apiExplorer", "settings"]
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
        MCPToolDefinition(
            name: "debug_click",
            description: #"""
            Debug: click once with the left mouse button at a point of a HephaestusV2 window of this Mac, inside the app, without Accessibility permission, and return the windows as debug_ui_state does, 500 ms after the click. window is an id from debug_ui_state; x and y are points from the top-left corner of that window's debug_screenshot image (image pixels divided by the image width over the window's frame width).
            """#,
            inputSchema: schema(#"""
            {
              "type": "object",
              "properties": {
                "window": {
                  "type": "integer",
                  "description": "Window id from debug_ui_state."
                },
                "x": {
                  "type": "integer",
                  "description": "Points from the left edge of the window's debug_screenshot image.",
                  "minimum": 0
                },
                "y": {
                  "type": "integer",
                  "description": "Points from the top edge of the window's debug_screenshot image.",
                  "minimum": 0
                }
              },
              "required": ["window", "x", "y"],
              "additionalProperties": false
            }
            """#),
            isDebug: true,
            engineMethod: nil,
            handling: .debugUI
        ),
    ]
}
