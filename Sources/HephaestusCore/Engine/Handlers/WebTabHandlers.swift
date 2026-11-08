import Foundation

extension Engine {
    /// docs/engine-api.md › Web tabs.
    func registerWebTabHandlers() {
        register(WebTabsList.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsList(params, actor)
        }
        register(WebTabsOpen.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsOpen(params, actor)
        }
        register(WebTabsUpdate.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsUpdate(params, actor)
        }
        register(WebTabsClose.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsClose(params, actor)
        }
        register(WebTabsMove.self, actors: [.user, .claude]) { [unowned self] params, actor in
            try await self.webTabsMove(params, actor)
        }
    }

    /// docs/engine-api.md › webTabs.list: the project's tabs in tab order.
    func webTabsList(_ params: WebTabsList.Params, _ actor: Actor) async throws -> [WebTab] {
        let id = try loadedProjectID(params.projectID)
        return loaded(id).project.webTabs
    }

    /// docs/engine-api.md › webTabs.open: a new tab with a new UUID, the URL's host as default
    /// title, unlocked by default, at `index` clamped to the tab range or appended. A tab opened
    /// locked takes its URL as original URL.
    func webTabsOpen(_ params: WebTabsOpen.Params, _ actor: Actor) async throws -> WebTab {
        let id = try loadedProjectID(params.projectID)
        let url = try validated { try ModelRules.webTabURL(params.url) }
        let title = params.title.map(Self.webTabTitle) ?? (URLComponents(string: url)?.host ?? "")
        let locked = params.locked ?? false
        let tab = WebTab(id: UUID(), title: title, url: url, locked: locked, originalURL: locked ? url : nil)
        var project = loaded(id).project
        let index = min(max(params.index ?? project.webTabs.count, 0), project.webTabs.count)
        project.webTabs.insert(tab, at: index)
        try saveWebTabs(project, origin: actor)
        return tab
    }

    /// docs/engine-api.md › webTabs.update: a locked tab can be navigated, renamed and unlocked;
    /// Claude never unlocks a tab. Locking takes the tab's URL after the update as original URL,
    /// unlocking removes it, and a new URL keeps it (docs/web-tabs.md › Original URL).
    func webTabsUpdate(_ params: WebTabsUpdate.Params, _ actor: Actor) async throws -> WebTab {
        try ActorRules.requireNoUnlock(params.locked, actor)
        let id = try loadedProjectID(params.projectID)
        var project = loaded(id).project
        guard let index = project.webTabs.firstIndex(where: { $0.id == params.tabID }) else {
            throw Self.webTabNotFound(params.tabID)
        }
        let old = project.webTabs[index]
        var tab = old
        if let url = params.url {
            tab.url = try validated { try ModelRules.webTabURL(url) }
        }
        if let title = params.title {
            tab.title = Self.webTabTitle(title)
        }
        if let locked = params.locked {
            tab.locked = locked
        }
        if !tab.locked {
            tab.originalURL = nil
        } else if !old.locked || tab.originalURL == nil {
            tab.originalURL = tab.url
        }
        guard tab != old else { return tab }
        project.webTabs[index] = tab
        try saveWebTabs(project, origin: actor)
        return tab
    }

    /// docs/engine-api.md › webTabs.close: a locked tab cannot be closed, whoever calls.
    func webTabsClose(_ params: WebTabsClose.Params, _ actor: Actor) async throws -> Empty {
        let id = try loadedProjectID(params.projectID)
        var project = loaded(id).project
        guard let index = project.webTabs.firstIndex(where: { $0.id == params.tabID }) else {
            throw Self.webTabNotFound(params.tabID)
        }
        guard !project.webTabs[index].locked else {
            throw EngineError(.forbidden, "This tab is locked.")
        }
        project.webTabs.remove(at: index)
        try saveWebTabs(project, origin: actor)
        return Empty()
    }

    /// docs/engine-api.md › webTabs.move: `toIndex` is the final position, clamped to the tab
    /// range.
    func webTabsMove(_ params: WebTabsMove.Params, _ actor: Actor) async throws -> [WebTab] {
        let id = try loadedProjectID(params.projectID)
        var project = loaded(id).project
        guard let index = project.webTabs.firstIndex(where: { $0.id == params.tabID }) else {
            throw Self.webTabNotFound(params.tabID)
        }
        let target = min(max(params.toIndex, 0), project.webTabs.count - 1)
        guard target != index else { return project.webTabs }
        let tab = project.webTabs.remove(at: index)
        project.webTabs.insert(tab, at: target)
        try saveWebTabs(project, origin: actor)
        return project.webTabs
    }

    // MARK: Helpers

    /// Writes project.yml with changed tabs and emits `webTabs.updated`, then `project.updated`.
    private func saveWebTabs(_ project: Project, origin: Actor) throws {
        try saveProject(project)
        emitWebTabsUpdated(project.id, origin: origin)
        emitProjectUpdated(project.id, origin: origin)
    }

    /// A web tab title as stored: trimmed, line breaks replaced by spaces, at most 500
    /// characters (docs/data-model.md › Web tab).
    static func webTabTitle(_ value: String) -> String {
        ModelRules.normalizedWebTabTitle(value.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespaces)
    }

    /// `notFound` `Web tab <id> not found.`
    static func webTabNotFound(_ id: UUID) -> EngineError {
        EngineError.notFound("Web tab", id.uuidString)
    }
}
