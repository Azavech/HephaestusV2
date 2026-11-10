import Foundation
import Testing
@testable import HephaestusCore

/// docs/skills.md › System prompt skills, docs/chats.md › Composition and rendering: the system
/// prompts come from internal skills read from the library at every launch and call, each filled
/// with its own placeholders, with the app's default text when a skill cannot be read.
@Suite("System prompt skills")
struct SystemPromptSkillsTests {
    /// The SHA-256 of the text of each prompt resource of the release before the system prompt
    /// skills (`Resources/prompts/<name>.md` without its final newline).
    static let previousReleaseDigests: [PromptSkill: String] = [
        .bundle: "cccb49a461b9c681148a758555061682b5285f62817698cf4944ccfc7dd4e8de",
        .ci: "464a3831f78f9cf578d8a2a2a8e0a013f6acc677c6a21e8d6676427570f6b5db",
        .commentAnswer: "03a00b81d62305867367d562e637ed1a55a6d981df84604faff38bc94a34725b",
        .common: "a5e8f320d8c2090fcd1e364eb3521744b5092746542c6f02ef76d52127827d0d",
        .namingBundle: "6c60f060f180a98c2b248962efde58e5a71eb5212f931f4a0bd7364f72566bf4",
        .namingChat: "e5f03ce0503b32b49b3fccf4baf76b9d32146d88449cb8867979326fd2d95eb1",
        .namingTicket: "08b9e1ed9dd54b9d1f5639f2997b8a1f303bb64a7b8a177bf45dc5bb193d0116",
        .notificationSummary: "c95a18c598d4737efa68748c87c5496a79d2f8df7b8a7fc8714dd71bcf16f16e",
        .project: "a7175042da78247a5508f2405e429c527424ace152bf6b4a62d587afc68ddef5",
        .ticket: "44085b9358cd845f1c343ef6b5430c5233976cce3b8ef744fd1471012cb18871",
    ]

    /// The text the common default gained since that release: the API tools (HEPH-128), then the
    /// VM tools (HEPH-145) with the guest account (HEPH-157).
    static let commonAdditions = [
        "- The API of a Go service project: api_operations (lists the operations of its OpenAPI contract openapi/contract.yaml), "
            + "api_call (calls one of them on an environment of the project, with the credentials and headers stored in the API Explorer).\n",
        " When the project root holds openapi/contract.yaml, read and change the service through its API with api_operations and api_call "
            + "and the environment's name, never with curl and a guessed URL, certificate flags or credentials: api_call uses the environment's "
            + "URL and certificate setting and the credentials and headers stored in the API Explorer.",
        "- Virtual machines: vm_list_images, vm_set_account, vm_list, vm_start, vm_stop, vm_screenshot, vm_click, vm_drag, vm_scroll, vm_type, vm_key, "
            + "vm_ui_tree, vm_shell, vm_copy_in, vm_copy_out (macOS virtual machines of this Mac that you start, drive and stop for your checks).\n",
        "# Virtual machines\n\nStart a virtual machine with vm_start freely, without asking, whenever a check needs one, for example a check of "
            + "menus, typed text, list rows, scrolling, system dialogs or permission prompts. Without image, vm_start uses the default image; "
            + "when a virtual machine that Claude started runs from the same image, your chat joins it instead of starting another. Drive it "
            + "with vm_screenshot, vm_click, vm_drag, vm_scroll, vm_type, vm_key, vm_ui_tree and vm_shell, and copy files with vm_copy_in and "
            + "vm_copy_out; x and y are pixels of the last vm_screenshot. The actions of every chat on one virtual machine run one at a time. "
            + "A virtual machine that Claude started stops by itself after some minutes without an action; vm_stop stops it at once, also "
            + "for the other chats that joined it. A virtual machine that the user started, Started by You in vm_list, is the user's: act on "
            + "it only when the user names it in this chat, by its name or with its linked item, and never stop it. vm_list_images gives "
            + "the userName and password of the guests' account of each image that has them stored: whenever a guest asks for the password "
            + "of its account, for example for sudo in Terminal or in a dialog of macOS, type that password with vm_type, without asking. "
            + "Store the account of an image with vm_set_account when the user gives it to you, or when you create the account in Setup "
            + "Assistant of an image's setup.\n\n",
    ]

    /// The text of the common default that changed since that release, each as its current text and
    /// the text it replaced: the User rule and the virtual machine of the Testing bullet, and the VM
    /// checks of HephaestusV2 (HEPH-147).
    static let commonReplacements = [
        ("- Claude: <test> for a check you run, on an isolated instance or in a virtual machine, or - User: <test> for a check the user "
            + "performs. Write a User bullet only for a check that needs the user's own accounts, data or hardware; every other check is a "
            + "Claude bullet. Never write a code test there:",
         "- Claude: <test> for a check you run, for example on an isolated instance, or - User: <test> for a check the user performs. "
            + "Never write a code test there:"),
        ("- To check the user interface, use a second, isolated instance of the app and the debug MCP tools, and a virtual machine for "
            + "what those tools cannot do, as docs/development.md › VM checks describes; never use the app the user is running.",
         "- To check the user interface, use a second, isolated instance of the app and the debug MCP tools, never the app the user is running."),
    ]

    @Test("The text of each unedited default is the prompt of the previous release, byte for byte, but for the text the common default gained or changed since")
    func defaultsAreThePreviousPrompts() throws {
        for skill in PromptSkill.allCases {
            var text = Prompts.text(skill)
            if skill == .common {
                for addition in Self.commonAdditions {
                    #expect(text.contains(addition))
                    text = text.replacingOccurrences(of: addition, with: "")
                }
                for (current, previous) in Self.commonReplacements {
                    #expect(text.contains(current))
                    text = text.replacingOccurrences(of: current, with: previous)
                }
            }
            #expect(AtomicFile.sha256(Data(text.utf8)) == Self.previousReleaseDigests[skill], "\(skill.rawValue)")
            // The default's body is a blank line, the text and a final newline.
            let data = try #require(InternalSkills.defaultContent(skill.rawValue))
            #expect(try SkillDocument.parse(data, folderName: skill.rawValue).body == "\n" + Prompts.text(skill) + "\n")
        }
    }

    @Test("The text of a body is the body without the white space and line breaks at both ends")
    func bodyText() {
        #expect(Prompts.text(ofBody: "\n\n  # Rules\n\nKeep {{projectName}}.  \n\n") == "# Rules\n\nKeep {{projectName}}.")
        #expect(Prompts.text(ofBody: "") == "")
    }

    @Test("Each skill is filled with its own placeholders only; the naming and summary skills are passed unchanged")
    func ownPlaceholders() {
        let values = ["projectName": "Demo", "projectID": "DEMO", "projectRoot": "/r", "workingDirectory": "W", "parentMemories": "",
                      "deviceName": "Studio", "docsPath": "docs", "projectType": "None", "environments": "", "globalMemories": "G",
                      "ticketID": "DEMO-1", "ticket": "T", "bundleID": "DEMO-B1", "bundle": "B", "githubRepository": "o/n"]
        let template = "{{projectName}} {{workingDirectory}} {{ticketID}} {{ticket}} {{bundle}} {{githubRepository}} {{other}}"
        #expect(Prompts.render(.common, template, values) == "Demo W {{ticketID}} {{ticket}} {{bundle}} {{githubRepository}} {{other}}")
        #expect(Prompts.render(.project, template, values) == "Demo W {{ticketID}} {{ticket}} {{bundle}} {{githubRepository}} {{other}}")
        #expect(Prompts.render(.ticket, template, values) == "Demo W DEMO-1 T {{bundle}} {{githubRepository}} {{other}}")
        #expect(Prompts.render(.bundle, template, values) == "Demo W {{ticketID}} {{ticket}} B {{githubRepository}} {{other}}")
        #expect(Prompts.render(.ci, template, values) == "Demo W {{ticketID}} {{ticket}} {{bundle}} o/n {{other}}")
        #expect(Prompts.render(.commentAnswer, template, values) == "Demo {{workingDirectory}} DEMO-1 {{ticket}} {{bundle}} {{githubRepository}} {{other}}")
        for skill in [PromptSkill.namingTicket, .namingChat, .namingBundle, .notificationSummary] {
            #expect(skill.placeholders.isEmpty)
            #expect(Prompts.render(skill, template, values) == template)
        }
        // A chat's system prompt: each skill of its kind rendered with its own set.
        let texts: [PromptSkill: String] = [.common: "C {{ticket}}", .ticket: "T {{ticket}}", .ci: "CI {{ticket}} {{githubRepository}}"]
        #expect(Prompts.systemPrompt(kind: .ticket, values: values, texts: texts) == "C {{ticket}}\n\nT T")
        #expect(Prompts.systemPrompt(kind: .feedback, values: values, texts: texts) == "C {{ticket}}")
        #expect(Prompts.systemPrompt(kind: .ci, values: values, texts: texts) == "CI {{ticket}} o/n")
    }

    @Test("The unsupported placeholders of a body: once each, in order of first appearance, as the rendering reads them")
    func unsupportedPlaceholders() {
        #expect(PromptSkill.namingChat.unsupportedPlaceholders(in: "{{ticket}} and {{bundle}}, {{ticket}} again, {{open")
            == ["{{ticket}}", "{{bundle}}"])
        #expect(PromptSkill.namingChat.unsupportedPlaceholdersLine(in: "Name {{ticket}}.") == "Unsupported placeholders, sent as written: {{ticket}}")
        #expect(PromptSkill.project.unsupportedPlaceholdersLine(in: "{{ticket}}, {{bundle}} of {{projectName}}")
            == "Unsupported placeholders, sent as written: {{ticket}}, {{bundle}}")
        #expect(PromptSkill.ticket.unsupportedPlaceholdersLine(in: "{{ticket}} of {{projectName}}") == nil)
        #expect(PromptSkill.common.unsupportedPlaceholders(in: "{{ projectName }}") == ["{{ projectName }}"])
        // The defaults use only their own placeholders.
        for skill in PromptSkill.allCases {
            #expect(skill.unsupportedPlaceholdersLine(in: Prompts.text(skill)) == nil, "\(skill.rawValue)")
        }
    }

    @Test("The editor captions of the system prompt skills")
    func captions() {
        #expect(PromptSkill.common.caption == "HephaestusV2 puts this skill in the system prompt of every chat except CI chats")
        #expect(PromptSkill.allCases.map(\.use) == ["bundle chats", "CI chats", "every chat except CI chats", "comment answers", "bundle naming calls",
                                                    "chat naming calls", "ticket naming calls", "notification summary calls", "project chats",
                                                    "ticket chats"])
        #expect(PromptSkill.allCases.allSatisfy { InternalSkills.isInternal($0.rawValue) && !InternalSkills.calledNames.contains($0.rawValue) })
    }

    // MARK: Read at every launch and call

    @Test("An edited body is used at the next launch of a chat and at the next comment answer, naming call and summary call")
    func editedBodies() async throws {
        let launcher = FakeClaudeLauncher()
        launcher.chatScript = FakeClaudeLauncher.silentChat()
        try await withChatEngine(launcher: launcher) { bed in
            let before = try await bed.createChat(message: "Plan")
            let first = try #require(await ChatWorktreeTests.process(bed, before.id))
            let defaultPrompt = try #require(ChatWorktreeTests.systemPrompt(first))
            #expect(defaultPrompt.hasPrefix("You are Claude, working inside HephaestusV2, a macOS app that coordinates the work on many projects. "
                + "The user talks to you in a chat of the project Demo (identifier DEMO)."))
            #expect(defaultPrompt.contains("\n\n# This chat\n\nThis is a project chat of Demo (DEMO)."))

            _ = try await bed.connection.call(SkillsUpdate.self, .init(name: "project", body: "\n# Changed\n\nProject {{projectName}}, ticket {{ticket}}.\n"))
            let after = try await bed.createChat(message: "Plan")
            let second = try #require(await ChatWorktreeTests.process(bed, after.id))
            let changed = try #require(ChatWorktreeTests.systemPrompt(second))
            #expect(changed.hasSuffix("finish-implementation describes.\n\n# Changed\n\nProject Demo, ticket {{ticket}}."))

            _ = try await bed.connection.call(SkillsUpdate.self, .init(name: "comment-answer", body: "Answer {{ticketID}} of {{projectName}} {{workingDirectory}}.\n"))
            let project = try #require(await bed.engine.domain.project("DEMO"))
            #expect(await bed.engine.commentAnswerPrompt(ticketID: "DEMO-1", project: project, root: bed.root) == "Answer DEMO-1 of Demo {{workingDirectory}}.")

            for skill in [PromptSkill.namingTicket, .namingChat, .namingBundle, .notificationSummary] {
                #expect(await bed.engine.namingContext("test", prompt: skill)?.prompt == Prompts.text(skill))
                _ = try await bed.connection.call(SkillsUpdate.self, .init(name: skill.rawValue, body: "\nName it {{projectName}}, \(skill.rawValue).\n"))
                #expect(await bed.engine.namingContext("test", prompt: skill)?.prompt == "Name it {{projectName}}, \(skill.rawValue).")
            }
        }
    }

    @Test("A skill that cannot be read gives the app's default text and a warning; a missing one is written again before it is read")
    func unreadableSkill() async throws {
        try await withChatEngine { bed in
            let library = bed.dataDirectory.skillsFolder
            try Data("---\nname: ci\n".utf8).write(to: library.appendingPathComponent("ci/SKILL.md"))
            #expect(await bed.engine.promptSkillTexts([.ci]) == [.ci: Prompts.text(.ci)])
            let namingChat = library.appendingPathComponent("naming-chat")
            try FileManager.default.removeItem(at: namingChat)
            try Data("not a folder".utf8).write(to: namingChat)
            #expect(await bed.engine.promptSkillTexts([.namingChat]) == [.namingChat: Prompts.text(.namingChat)])
            let log = try String(contentsOf: bed.dataDirectory.engineLogFile, encoding: .utf8)
            #expect(log.contains("the internal skill ci cannot be read: "))
            #expect(log.contains("; the app's default text is used"))
            #expect(log.contains("the internal skill naming-chat cannot be read: ") && log.contains("naming-chat is not a folder"))

            try FileManager.default.removeItem(at: library.appendingPathComponent("project"))
            #expect(await bed.engine.promptSkillTexts([.project]) == [.project: Prompts.text(.project)])
            #expect(try Data(contentsOf: library.appendingPathComponent("project/SKILL.md")) == InternalSkills.defaultContent("project"))
            #expect(!(try String(contentsOf: bed.dataDirectory.engineLogFile, encoding: .utf8)).contains("the internal skill project cannot be read"))
        }
    }

    @Test("The generated plugin links the called internal skills and the project's skills, never a system prompt skill, also when the project's list names one")
    func pluginLinksNoSystemPromptSkill() async throws {
        try await withChatEngine { bed in
            _ = try await bed.connection.call(SkillsCreate.self, .init(name: "release-notes", description: "Writes release notes."))
            let folder = try SkillsPluginGenerator().preparePlugin(projectID: "DEMO", skills: ["common", "naming-chat", "release-notes"],
                                                                   library: bed.dataDirectory.skillsFolder, dataDirectory: bed.dataDirectory)
            let links = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("hephaestus-skills/skills").path)
            #expect(links.sorted() == InternalSkills.calledNames + ["release-notes"])
        }
    }
}
