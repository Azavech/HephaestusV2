// OWNER: ui-shell — whether the API Explorer row shows: the workspace follows the contract
// `openapi/contract.yaml` of the Go service projects its main windows show (docs/openapi.md ›
// Availability).
import Foundation
import HephaestusCore

extension DeviceWorkspace {
    /// The contract the API Explorer shows, a project path.
    static let apiContractPath = "openapi/contract.yaml"

    /// Whether a project's sidebar shows the API Explorer row: the project's type is `goService`
    /// and its `openapi/contract.yaml` holds an OpenAPI 3.x contract. Nil while the first read of
    /// the contract runs.
    func showsAPIExplorer(_ projectID: String) -> Bool? {
        guard project(projectID)?.type == .goService else { return false }
        return apiContracts[projectID]
    }

    /// Starts following the contract of a Go service project: it is read now, then again after each
    /// `files.changed` event that names it and after each reconnection.
    func followAPIContract(of projectID: String) {
        guard apiContractReads[projectID] == nil, project(projectID)?.type == .goService else { return }
        readAPIContract(of: projectID)
    }

    /// A `files.changed` event of a followed project whose paths name the contract, a folder above
    /// it or the whole project reads the contract again.
    func apiContractFilesChanged(_ payload: FilesChangedEvent.Payload) {
        guard apiContractReads[payload.projectID] != nil, payload.paths.contains(where: Self.namesAPIContract) else { return }
        readAPIContract(of: payload.projectID)
    }

    /// Reads every followed contract again, after a reconnection.
    func readFollowedAPIContracts() {
        for projectID in apiContractReads.keys.sorted() {
            readAPIContract(of: projectID)
        }
    }

    /// True for a `files.changed` path that is the contract, a folder above it, or `""`.
    static func namesAPIContract(_ path: String) -> Bool {
        path.isEmpty || path == apiContractPath || apiContractPath.hasPrefix(path + "/")
    }

    /// Whether a read of the contract found an OpenAPI 3.x contract, by the rules of
    /// docs/openapi.md › Detection for a `yaml` file; a file read without text holds none.
    static func holdsAPIContract(_ file: FileContent) -> Bool {
        guard let text = file.text else { return false }
        return OpenAPIDetection.isContract(text: text, isJSON: false)
    }

    /// Reads the contract; only the result of the last read is kept. A missing file, a failed read
    /// and a text that is not a contract count as no contract; a read that fails because the device
    /// is not connected keeps the previous result.
    private func readAPIContract(of projectID: String) {
        let read = (apiContractReads[projectID] ?? 0) + 1
        apiContractReads[projectID] = read
        Task { [weak self] in
            guard let self else { return }
            let holdsContract: Bool?
            do {
                let file = try await call(FilesRead.self, FilesRead.Params(projectID: projectID, path: Self.apiContractPath))
                holdsContract = Self.holdsAPIContract(file)
            } catch let error as EngineError where error.code == .unavailable {
                holdsContract = nil
            } catch {
                holdsContract = false
            }
            guard apiContractReads[projectID] == read, let holdsContract, apiContracts[projectID] != holdsContract else { return }
            apiContracts[projectID] = holdsContract
        }
    }
}
