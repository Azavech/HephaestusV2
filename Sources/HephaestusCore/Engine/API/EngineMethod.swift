import Foundation

/// One engine method: its wire name, its params and its result (docs/engine-api.md › EngineMethod).
/// Every method is declared up front as a caseless `enum` named by its Swift type.
public protocol EngineMethod {
    static var name: String { get }
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
}

/// One engine event: its name and its payload (docs/engine-api.md › EngineEvent).
public protocol EngineEvent {
    static var name: String { get }
    associatedtype Payload: Codable & Sendable
}

/// The params of a method without params and the result of a method without result. Encodes as
/// `{}` and decodes from any object (docs/engine-api.md › Empty).
public struct Empty: Codable, Sendable, Hashable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: AnyJSONKey.self)
    }

    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: AnyJSONKey.self)
    }
}

/// The Swift type of a clearable param (docs/engine-api.md › Patch): an absent key keeps the
/// value, `null` clears it, a value replaces it (JSON Merge Patch, RFC 7396).
public enum Patch<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case keep
    case clear
    case set(Value)

    /// Outside a keyed container a patch cannot be absent: `null` decodes as `clear`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = container.decodeNil() ? .clear : .set(try container.decode(Value.self))
    }

    /// Outside a keyed container `keep` and `clear` both encode as `null`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .keep, .clear: try container.encodeNil()
        case .set(let value): try container.encode(value)
        }
    }

    /// The value after applying the patch to `current`.
    public func applied(to current: Value?) -> Value? {
        switch self {
        case .keep: return current
        case .clear: return nil
        case .set(let value): return value
        }
    }

    /// True unless the patch is `keep`.
    public var isPresent: Bool {
        if case .keep = self { return false }
        return true
    }
}

extension KeyedDecodingContainer {
    public func decode<V>(_ type: Patch<V>.Type, forKey key: Key) throws -> Patch<V> {
        guard contains(key) else { return .keep }
        if try decodeNil(forKey: key) { return .clear }
        return .set(try decode(V.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<V>(_ value: Patch<V>, forKey key: Key) throws {
        switch value {
        case .keep: break
        case .clear: try encodeNil(forKey: key)
        case .set(let v): try encode(v, forKey: key)
        }
    }
}

/// Every method type of docs/engine-api.md › Method index, in the order of the index.
public enum EngineMethods {
    public static let all: [any EngineMethod.Type] = [
        DeviceInfoMethod.self, SnapshotGet.self,
        ProjectsList.self, ProjectsGet.self, ProjectsCreate.self, ProjectsOpen.self, ProjectsUpdate.self,
        ProjectsSetCurrentEnvironment.self, ProjectsRemove.self, ProjectsEnsureHephaestus.self,
        KubernetesStatus.self, KubernetesLogs.self, KubernetesEvents.self, KubernetesRestart.self, KubernetesScale.self,
        KubernetesForward.self, KubernetesStopForward.self, ArgoCDStatus.self, ArgoCDSync.self,
        KubernetesCheck.self, KubernetesNamespaces.self, KubernetesDeployments.self, KubernetesPods.self,
        APIOperations.self, APICall.self,
        GraphRead.self, GraphRequest.self,
        TicketsList.self, TicketsGet.self, TicketsCreate.self, TicketsUpdate.self, TicketsSetStatus.self,
        TicketsDelete.self, TicketsAddComment.self, TicketsUpdateComment.self, TicketsDeleteComment.self, TicketsRetryAnswer.self,
        TicketsAddAttachments.self, TicketsRemoveAttachment.self,
        AttachmentsRead.self,
        BundlesList.self, BundlesGet.self, BundlesCreate.self, BundlesUpdate.self, BundlesSetStatus.self,
        BundlesDelete.self,
        ChatsList.self, ChatsGet.self, ChatsCreate.self, ChatsSend.self, ChatsInterrupt.self,
        ChatsUpdateSettings.self, ChatsRename.self, ChatsDelete.self, ChatsClose.self, ChatsReopen.self, ChatsAnswerPermission.self,
        ChatsPostQuestions.self, ChatsAnswerQuestion.self, ChatsPostSymbol.self, ChatsAnswerSymbol.self,
        ChatsPostColor.self, ChatsAnswerColor.self, ChatsPostSound.self, ChatsAnswerSound.self,
        ChatsPostShortcut.self, ChatsAnswerShortcut.self,
        ChatsPostFont.self, ChatsAnswerFont.self,
        ChatsPostAnimation.self, ChatsAnswerAnimation.self, ChatsPostImages.self,
        ChatsImplementTicket.self, ChatsImplementBundle.self, ChatsWatchCI.self,
        ChatsCreateFeedback.self, ChatsListAgents.self, ChatsAgentTranscript.self, ChatsStopWorkflow.self,
        SoundsList.self, SoundsRead.self,
        ClaudeModels.self, ClaudeStatusMethod.self, ClaudePlanUsage.self, ClaudeReportPlanUsage.self,
        FilesList.self, FilesRead.self, FilesWrite.self, FilesCreate.self, FilesRename.self, FilesTrash.self, FilesFonts.self,
        DocsList.self,
        FSBrowse.self,
        WebTabsList.self, WebTabsOpen.self, WebTabsUpdate.self, WebTabsClose.self, WebTabsMove.self,
        SearchQuery.self,
        SkillsList.self, SkillsGet.self, SkillsCreate.self, SkillsUpdate.self, SkillsDelete.self,
        SkillsReadFile.self, SkillsWriteFile.self, SkillsDeleteFile.self, SkillsSetEnabled.self, SkillsRestoreDefault.self,
        MemoriesList.self, MemoriesGet.self, MemoriesCreate.self, MemoriesUpdate.self, MemoriesDelete.self,
        MemoriesReadIndex.self, MemoriesWriteIndex.self,
        BuildsListRuns.self, BuildsGetRun.self, BuildsRerunRun.self, BuildsCancelRun.self, BuildsListReleases.self,
        BuildsGetRelease.self, BuildsDownloadAsset.self,
        SettingsGet.self, SettingsUpdate.self,
        UIOpen.self,
    ]
}
