import Foundation

/// User messages, the composed first messages (implement, feedback, answers), the system prompt
/// of a launch and the naming of chats (docs/chats.md › User messages, › Implement and feedback
/// chats, › Answering, › System prompts, › Haiku naming).
extension Engine {
    // MARK: Senders

    /// The `sender` of a user message (docs/data-model.md › User item): the name of the device of
    /// a user actor (`userDeviceName(deviceID:)`), `Claude` for a claude actor, and this (the
    /// main) device's name for the system actor (docs/chats.md › User messages).
    func senderName(_ actor: Actor) -> String {
        switch actor {
        case .claude: return "Claude"
        case .system: return deviceInfo.name
        case .user(let deviceID): return userDeviceName(deviceID: deviceID)
        }
    }

    /// Records the driving device of a chat for a user actor.
    func recordDrivingDevice(_ chatID: ChatID, _ actor: Actor) {
        if let deviceID = actor.deviceID {
            chats.drivingDevices[chatID] = deviceID
        }
    }

    // MARK: Sending

    /// The checks of a `ChatMessageInput` (docs/engine-api.md › chats.send): the text is not
    /// empty after trimming unless there is an attachment; the uploads are checked and read.
    func prepareMessage(_ message: ChatMessageInput, projectRoot: URL) throws -> [ChatAttachments.Prepared] {
        let uploads = message.attachments ?? []
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !uploads.isEmpty else {
            // docs/engine-api.md › chats.send, errors
            throw EngineError.invalid("message", "write a text or attach a file")
        }
        return try ChatAttachments.prepare(uploads, projectRoot: projectRoot)
    }

    /// Stores the uploads of a message in the chat's attachment folder, in order.
    func storeChatAttachments(_ prepared: [ChatAttachments.Prepared], chatID: ChatID) throws -> [(Attachment, Data)] {
        let folder = try chatFolder(try requireChat(chatID))
        return try prepared.map { upload in
            do {
                let attachment = try ChatAttachments.store(name: upload.name, contentType: upload.contentType, data: upload.data,
                                                           chatID: chatID, folder: folder, ownWrites: ownWrites)
                return (attachment, upload.data)
            } catch let error as StorageError {
                throw EngineError.storage(error)
            }
        }
    }

    /// Appends the `user` item with the stored attachments and `sender`, delivers the message to
    /// the chat's Claude process, writes the metadata (`chat.updated`) with `closed` false, and
    /// starts the naming when this is the chat's first user message with text (docs/chats.md ›
    /// User messages, › Closing a chat).
    func sendChatMessage(_ chatID: ChatID, text: String, attachments stored: [(Attachment, Data)], sender: String,
                         origin: Actor) throws {
        let meta = try requireChat(chatID)
        let folder = try chatFolder(meta)
        let text = ModelRules.normalizedLineBreaks(text)
        var images: [ControlLines.Image] = []
        var files: [String] = []
        for (attachment, data) in stored {
            if ChatAttachments.imageBlockTypes.contains(attachment.contentType), attachment.size <= ChatAttachments.maximumImageBlockSize {
                images.append(ControlLines.Image(mediaType: attachment.contentType, base64: data.base64EncodedString()))
            } else {
                files.append(folder.attachmentFile(path: attachment.path).path)
            }
        }
        let attachments = stored.map(\.0)
        var sent = text
        if !files.isEmpty {
            if !sent.isEmpty { sent += "\n\n" }
            sent += "Attached files:\n" + files.map { "- \($0)" }.joined(separator: "\n")
        }
        try? ensureChatScanned(chatID)
        let startsNaming = !text.isEmpty && chats.hasTextMessage[chatID] != true
        let itemID = RandomIDs.uuidString()
        try appendChatItem(.user(UserItem(id: itemID, created: ISODate.now(), text: text, attachments: attachments, sender: sender)),
                           chatID: chatID, origin: origin)
        if !text.isEmpty { chats.hasTextMessage[chatID] = true }
        deliverChatMessage(chatID, ChatMessageLine(data: ControlLines.userMessage(text: sent, images: images, uuid: itemID), uuid: itemID))
        var current = domain.chat(chatID) ?? meta
        // A message reopens a closed chat (docs/chats.md › Closing a chat).
        current.closed = false
        try saveChatMeta(current, origin: origin)
        if startsNaming { startChatNaming(chatID, firstMessage: text) }
    }

    // MARK: Naming

    /// Names the chat with Haiku from its first user message with text; the title is applied only
    /// while the chat is still titled `New Chat` (docs/chats.md › Applying the title).
    private func startChatNaming(_ chatID: ChatID, firstMessage: String) {
        let namer = titleNamer
        Task {
            let title = await namer.title(for: .chat(firstMessage: firstMessage))
            self.applyChatTitle(chatID, title)
        }
    }

    private func applyChatTitle(_ chatID: ChatID, _ title: String?) {
        guard let title, !chats.deleting.contains(chatID), var meta = domain.chat(chatID), meta.title == ChatMeta.defaultTitle,
              let valid = try? ModelRules.chatTitle(title)
        else { return }
        meta.title = valid
        saveChatMetaLogging(meta, origin: .system)
    }

    // MARK: Composed messages

    /// docs/chats.md › Feedback message.
    static func feedbackMessage(comment: String, context: FeedbackContext, projectName: String?, screenshotPath: String) -> String {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [trimmed.isEmpty ? "(no comment)" : ModelRules.normalizedLineBreaks(trimmed), "", "Feedback context:"]
        lines.append("- App: HephaestusV2 v\(context.appVersion)(\(context.build))")
        let device = context.deviceName == context.mainDeviceName
            ? context.deviceName : "\(context.deviceName), connected to \(context.mainDeviceName)"
        lines.append("- Device: \(device)")
        if let projectID = context.projectID {
            // A project that is not loaded is named by its identifier (docs/chats.md › Feedback message).
            lines.append("- Project: \(projectName ?? projectID) (\(projectID))")
        }
        if let section = context.section { lines.append("- Section: \(section.rawValue)") }
        if let item = context.item { lines.append("- Item: \(item)") }
        lines.append("- Screenshot: \(screenshotPath)")
        return lines.joined(separator: "\n")
    }

    /// docs/chats.md › Answering: `Answers:`, then `<label>: <answer>` per question in label order.
    static func answersMessage(_ set: QuestionsItem) -> String {
        (["Answers:"] + set.questions.map { "\($0.label): \(set.answers[$0.label] ?? "")" }).joined(separator: "\n")
    }

    // MARK: System prompt

    /// The value of `--append-system-prompt` for a launch (docs/chats.md › Composition and
    /// rendering): rendered at every launch with the current project, ticket and bundle data.
    func chatSystemPrompt(meta: ChatMeta, project: Project, root: URL, items: [ChatItem]) -> String {
        var values: [String: String] = [
            "projectName": project.name,
            "projectID": project.id,
            "projectRoot": root.path,
            "deviceName": deviceInfo.name,
            "docsPath": project.docsPath,
            "projectCommands": Prompts.projectCommands(project.commands),
        ]
        switch meta.kind {
        case .project:
            break
        case .ticket:
            let ticketID = meta.ticketID ?? ""
            values["ticketID"] = ticketID
            values["ticket"] = domain.ticket(ticketID).map { renderTicket($0, excluding: meta.id) } ?? Prompts.deletedTicket
        case .bundle:
            let bundleID = meta.bundleID ?? ""
            values["bundleID"] = bundleID
            guard let bundle = domain.bundle(bundleID) else {
                values["bundle"] = Prompts.deletedBundle
                break
            }
            let tickets = bundle.ticketIDs.map { id -> Prompts.BundleTicket in
                let ticket = domain.ticket(id)
                return Prompts.BundleTicket(id: id, title: ticket?.title, rendering: ticket.map { renderTicket($0, excluding: meta.id) })
            }
            var fullCount = tickets.count
            while true {
                values["bundle"] = Prompts.bundle(id: bundle.id, title: bundle.title, tickets: tickets, fullCount: fullCount)
                let prompt = Prompts.systemPrompt(kind: meta.kind, values: values)
                if prompt.utf8.count <= Prompts.systemPromptLimit || fullCount == 0 { return prompt }
                fullCount -= 1
            }
        case .feedback:
            let first = items.lazy.compactMap { item -> UserItem? in
                if case .user(let user) = item { return user }
                return nil
            }.first
            values["feedbackContext"] = Prompts.feedbackContext(fromFirstMessage: first?.text)
            // `none` without an attachment (docs/chats.md › Placeholders).
            values["screenshotPath"] = first?.attachments.first.map { root.appendingPathComponent(".hephaestus/" + $0.path).path } ?? "none"
        }
        return Prompts.systemPrompt(kind: meta.kind, values: values)
    }

    /// `{{ticket}}` of a ticket, listing its chats other than `chatID` that have metadata.
    private func renderTicket(_ ticket: Ticket, excluding chatID: ChatID) -> String {
        guard let projectID = ticket.projectID, let root = domain.projectRoot(projectID) else {
            return Prompts.deletedTicket
        }
        let chatLines = ticket.chatIDs.filter { $0 != chatID }.compactMap { id -> String? in
            guard let meta = domain.chat(id) else { return nil }
            return "- \(id.uuidString) (\(meta.kind.rawValue)): \(meta.title)"
        }
        return Prompts.ticket(ticket, projectRoot: root.path, chatLines: chatLines)
    }
}
