import Foundation

extension Engine {
    /// docs/engine-api.md › Settings.
    func registerSettingsHandlers() {
        register(SettingsGet.self, actors: [.user]) { [unowned self] _, _ in
            await self.settings
        }
        register(SettingsUpdate.self, actors: [.user]) { [unowned self] params, actor in
            try await self.updateSettings(params, actor)
        }
    }

    /// `settings.update` (docs/engine-api.md › settings.update): applies the present params,
    /// checks the HostSettings rules, the default image and the skills folder, writes
    /// settings.yml, emits `settings.updated`, then applies the effects of the changed keys.
    /// A call that changes nothing writes nothing and emits nothing.
    func updateSettings(_ params: SettingsUpdate.Params, _ actor: Actor) async throws -> HostSettings {
        let old = settings
        let new = params.applied(to: old)
        do {
            try new.validate()
        } catch let error as ValidationError {
            throw EngineError(error)
        }
        try checkDefaultVMImage(new, old: old)
        let newSkillsFolder = new.skillsLibraryURL(dataDirectory: dataDirectory)
        let skillsFolderChanged = newSkillsFolder != old.skillsLibraryURL(dataDirectory: dataDirectory)
        if skillsFolderChanged {
            // docs/engine-api.md › settings.update, errors
            do {
                try FileManager.default.createDirectory(at: newSkillsFolder, withIntermediateDirectories: true)
            } catch {
                throw EngineError.invalid("skillsLibraryPath", "\(newSkillsFolder.path) cannot be created")
            }
        }
        guard new != old else { return old }

        do {
            let digest = try DeviceFileStore.write(new, to: dataDirectory)
            ownWrites.recordWrite(path: dataDirectory.settingsFile.standardizedFileURL.path, sha256: digest)
        } catch let error as StorageError {
            throw EngineError.storage(error)
        }
        settings = new
        emit(SettingsUpdatedEvent.self, new, origin: actor)
        await applySettingsEffects(old: old, new: new, skillsFolderChanged: skillsFolderChanged, origin: actor)
        return new
    }

    /// The effects of the changed keys (docs/engine-api.md › settings.update), after settings.yml
    /// was written by `settings.update` or changed outside the engine.
    func applySettingsEffects(old: HostSettings, new: HostSettings, skillsFolderChanged: Bool, origin actor: Actor) async {
        if new.claudePath != old.claudePath {
            await claudePathDidChange()
        }
        if new.mcpPort != old.mcpPort, configuration.mcpPort == nil {
            await moveMCPServer()
            await mcpPortDidChange()
        }
        if new.syncEnabled != old.syncEnabled || new.syncPort != old.syncPort {
            await syncSettingsDidChange(from: old)
        }
        if skillsFolderChanged {
            await skillsLibraryFolderDidChange()
            emit(SkillsChangedEvent.self, skillSummaries(), origin: actor)
        }
        if new.showHephaestusProject != old.showHephaestusProject {
            hephaestusVisibilityDidChange(shown: new.showHephaestusProject, origin: actor)
        }
    }
}
