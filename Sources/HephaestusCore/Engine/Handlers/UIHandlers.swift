import Foundation

extension Engine {
    /// docs/engine-api.md › UI navigation.
    func registerUIHandlers() {
        register(UIOpen.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.uiOpen(params, actor)
        }
    }

    /// docs/engine-api.md › ui.open: checks that everything the target names exists, then emits
    /// `ui.open` for the device of the param (user and system actors), the chat's driving device
    /// (a claude actor with a chat id) or every client (the external token, or an unknown
    /// driving device).
    func uiOpen(_ params: UIOpen.Params, _ actor: Actor) async throws -> Empty {
        let target = try checkedTarget(params.target)
        let deviceID: String?
        switch actor {
        case .user, .system:
            deviceID = params.deviceID
        case .claude:
            deviceID = actor.chat.flatMap { chats.drivingDeviceID(of: $0) }
        }
        emit(UIOpenEvent.self, UIOpenEvent.Payload(target: target, deviceID: deviceID), origin: actor)
        return Empty()
    }

    /// The target with its ids in their stored uppercase form, after checking that every
    /// project, ticket, bundle, chat, skill, web tab, doc or virtual machine it names exists, that a `file` target
    /// names an existing file, or an existing folder when it has no `line`, and that `line` is at
    /// least 1.
    func checkedTarget(_ target: NavigationTarget) throws -> NavigationTarget {
        switch target {
        case .project(let projectID):
            return .project(projectID: try loadedProjectID(projectID))
        case .ticket(let ticketID):
            return .ticket(ticketID: try existingTicket(ticketID).id)
        case .bundle(let bundleID):
            return .bundle(bundleID: try existingBundle(bundleID).id)
        case .chat(let chatID):
            guard domain.chat(chatID) != nil else { throw EngineError.notFound("Chat", chatID.uuidString) }
            return target
        case .doc(let projectID, let path, let fragment):
            let id = try loadedProjectID(projectID)
            let checked = try existingProjectItem(path, in: id, kind: "Doc", folderAllowed: false)
            return .doc(projectID: id, path: checked, fragment: fragment)
        case .file(let projectID, let path, let line):
            if let line, line < 1 {
                throw EngineError.invalid("line", "use a line number of at least 1")
            }
            let id = try loadedProjectID(projectID)
            let checked = try existingProjectItem(path, in: id, kind: "File", folderAllowed: line == nil)
            return .file(projectID: id, path: checked, line: line)
        case .skill(let name):
            _ = try validated { try ModelRules.skillName(name) }
            let skillFile = skillsLibraryFolder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else {
                throw EngineError.notFound("Skill", name)
            }
            return target
        case .webTab(let projectID, let tabID):
            let id = try loadedProjectID(projectID)
            guard loaded(id).project.webTabs.contains(where: { $0.id == tabID }) else {
                throw Self.webTabNotFound(tabID)
            }
            return .webTab(projectID: id, tabID: tabID)
        case .section(let projectID, let section):
            return .section(projectID: try loadedProjectID(projectID), section: section)
        case .virtualMachine(let vmID):
            guard virtualMachines.machines[vmID] != nil else {
                throw EngineError.notFound("Virtual machine", vmID.uuidString)
            }
            return target
        }
    }

    /// A project path that names an existing file of a loaded project, or an existing folder
    /// when `folderAllowed`.
    private func existingProjectItem(_ path: String, in projectID: ProjectID, kind: String, folderAllowed: Bool) throws -> String {
        guard let checked = DomainPaths.projectPath(path), !checked.isEmpty else {
            throw EngineError.invalid("path", "use a project path with / separators and no empty, . or .. component")
        }
        let url = URL(fileURLWithPath: loaded(projectID).rootPath, isDirectory: true).appendingPathComponent(checked)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), folderAllowed || !isDirectory.boolValue else {
            throw EngineError.notFound(kind, checked)
        }
        return checked
    }
}
