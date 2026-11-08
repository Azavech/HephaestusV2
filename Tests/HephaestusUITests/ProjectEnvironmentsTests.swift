import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Environments and docs/openapi.md › Environment: the messages of the
/// environment sheets and the environment they send, and the Environment pop-up of a contract's
/// request form with the environment stored for the contract.
@MainActor @Suite("Project environments")
struct ProjectEnvironmentsTests {
    static let created = Date(timeIntervalSince1970: 1_793_448_000)

    static let contract = """
        openapi: 3.0.3
        info:
          title: Check
          version: 1.0.0
        paths:
          /pets/{petId}:
            get:
              parameters:
                - name: petId
                  in: path
                  required: true
              responses:
                '200':
                  description: OK

        """

    let local = ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080)
    let staging = ProjectEnvironment(name: "staging", url: "https://staging.example.com/")

    @Test func sheetMessages() {
        let name = "Enter a name of 1 to 100 characters."
        #expect(ProjectRules.environmentNameMessage("", otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage("   ", otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage("two\nlines", otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage(String(repeating: "x", count: 101), otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage(String(repeating: "x", count: 100), otherNames: []) == nil)
        #expect(ProjectRules.environmentNameMessage(" local ", otherNames: ["local"]) == "An environment named “local” already exists.")
        #expect(ProjectRules.environmentNameMessage("Local", otherNames: ["local"]) == nil)

        #expect(ProjectRules.environmentURLMessage("http://127.0.0.1") == nil)
        #expect(ProjectRules.environmentURLMessage(" https://staging.example.com/v1 ") == nil)
        for invalid in ["", "127.0.0.1:8080", "ftp://example.com", "/v1", "http://"] {
            #expect(ProjectRules.environmentURLMessage(invalid) == "Enter an http or https URL.", "\(invalid)")
        }

        for valid in ["", " ", "1", "8080", " 65535 "] {
            #expect(ProjectRules.environmentPortMessage(valid) == nil, "\(valid)")
        }
        for invalid in ["0", "65536", "80a", "-1", "+80", "8 080", "８０", "99999999999999999999999"] {
            #expect(ProjectRules.environmentPortMessage(invalid) == "Enter a port from 1 to 65535.", "\(invalid)")
        }
        #expect(ProjectRules.environmentPort(" 8080 ") == 8080)
        #expect(ProjectRules.environmentPort("") == nil)
    }

    @Test func kubernetesFieldMessages() {
        let application = "Enter <name> or <namespace>/<name>."
        for valid in ["", "  ", "orders-staging", " argocd/orders-staging ", "team-a/orders"] {
            #expect(ProjectRules.environmentArgoCDApplicationMessage(valid) == nil, "\(valid)")
        }
        for invalid in ["argocd/orders/staging", "/orders", "argocd/", "/", "a//b", "orders staging", "argocd/ orders",
                        "orders\tstaging", "two\nlines"] {
            #expect(ProjectRules.environmentArgoCDApplicationMessage(invalid) == application, "\(invalid)")
        }

        let kubeconfig = "Enter an absolute path or a path starting with ~/."
        for valid in ["", " ", "/Users/example/.kube/config", " ~/.kube/staging.yaml "] {
            #expect(ProjectRules.environmentKubeconfigMessage(valid) == nil, "\(valid)")
        }
        for invalid in ["~", "~/", ".kube/config", "kube/config", "~example/.kube/config", "/Users/example/.kube/a\n/b"] {
            #expect(ProjectRules.environmentKubeconfigMessage(invalid) == kubeconfig, "\(invalid)")
        }
    }

    @Test func editedEnvironmentKeepsItsOwnName() {
        let others = ProjectRules.otherEnvironmentNames([local, staging], editing: local)
        #expect(others == ["staging"])
        #expect(ProjectRules.environmentNameMessage("local", otherNames: others) == nil)
        #expect(ProjectRules.environmentNameMessage("staging", otherNames: others) == "An environment named “staging” already exists.")
        #expect(ProjectRules.otherEnvironmentNames([local, staging], editing: nil) == ["local", "staging"])
    }

    @Test func createSaveAndRemoveBuildTheList() {
        let dev = sheetEnvironment(name: " dev ", url: " http://localhost:3000/ ")
        #expect(dev == ProjectEnvironment(name: "dev", url: "http://localhost:3000/"))
        // Create appends.
        #expect(ProjectRules.environments([local, staging], saving: dev, replacing: nil) == [local, staging, dev])

        // Save replaces at its place, with the edited environment's unknown keys.
        var extended = local
        extended.unknownKeys = ["region": "eu-west-1"]
        let saved = sheetEnvironment(name: "local", url: "http://127.0.0.1", port: " 9090 ", editing: extended)
        #expect(saved == ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 9090, unknownKeys: ["region": "eu-west-1"]))
        #expect(ProjectRules.environments([extended, staging], saving: saved, replacing: "local") == [saved, staging])
        let renamed = sheetEnvironment(name: "stage", url: "https://staging.example.com", editing: staging)
        #expect(ProjectRules.environments([local, staging], saving: renamed, replacing: "staging")
            == [local, ProjectEnvironment(name: "stage", url: "https://staging.example.com")])

        // Renamed or removed meanwhile: Save appends.
        #expect(ProjectRules.environments([local], saving: renamed, replacing: "staging").map(\.name) == ["local", "stage"])

        // `−` removes the selected environment only.
        #expect(ProjectRules.environments([local, staging], removing: "local") == [staging])
        #expect(ProjectRules.environments([local, staging], removing: "dev") == nil)
    }

    @Test func kubernetesFieldsAreSentTrimmedAndEmptyFieldsGiveNoValue() {
        let created = sheetEnvironment(name: "staging", url: "https://staging.example.com", context: " staging-eks ",
                                       namespace: "orders", deployment: " orders-api", argoCDApplication: "argocd/orders-staging ",
                                       kubeconfig: " ~/.kube/staging.yaml ")
        let full = ProjectEnvironment(name: "staging", url: "https://staging.example.com", context: "staging-eks", namespace: "orders",
                                      deployment: "orders-api", argoCDApplication: "argocd/orders-staging",
                                      kubeconfig: "~/.kube/staging.yaml")
        #expect(created == full)
        let empty = sheetEnvironment(name: "local", url: "http://127.0.0.1", context: "", namespace: "  ", deployment: "\t",
                                     argoCDApplication: " ", kubeconfig: "")
        #expect(empty == ProjectEnvironment(name: "local", url: "http://127.0.0.1"))

        // Save starts from the edited environment: its unknown keys stay, and a cleared field
        // removes its value.
        var stored = full
        stored.unknownKeys = ["region": "eu-west-1"]
        let saved = sheetEnvironment(name: "staging", url: "https://staging.example.com", context: "staging-eks", namespace: "",
                                     deployment: "orders-api", argoCDApplication: "", kubeconfig: "/Users/example/.kube/config",
                                     editing: stored)
        #expect(saved == ProjectEnvironment(name: "staging", url: "https://staging.example.com", context: "staging-eks",
                                            deployment: "orders-api", kubeconfig: "/Users/example/.kube/config",
                                            unknownKeys: ["region": "eu-west-1"]))
        let cleared = sheetEnvironment(name: "staging", url: "https://staging.example.com", editing: stored)
        #expect(cleared == ProjectEnvironment(name: "staging", url: "https://staging.example.com", unknownKeys: ["region": "eu-west-1"]))
    }

    @Test func sheetBelongsToItsProject() {
        #expect(WindowSheet.environment(projectID: "API", name: nil).projectID == "API")
        #expect(WindowSheet.environment(projectID: "API", name: "local").projectID == "API")
    }

    @Test func popUpStartsOnTheStoredEnvironmentElseTheFirst() async throws {
        let (workspace, buffer, model) = try await contractModel(type: .goService, environments: [local, staging])
        defer { buffer.detach() }
        let contract = try #require(model.contract)
        let operation = try #require(contract.operations.first)
        #expect(model.environments == [local, staging])
        #expect(model.environment == local)
        #expect(model.stored?.environment == nil)
        #expect(model.canSend)
        #expect(model.requestInput(operation, contract: contract).baseURL == "http://127.0.0.1:8080")

        model.selectEnvironment("staging")
        #expect(model.stored?.environment == "staging")
        #expect(model.environment == staging)
        #expect(model.requestInput(operation, contract: contract).baseURL == "https://staging.example.com")

        // Renamed in Project Settings: the stored name is kept and the first environment shows. The
        // engine's ProjectDetail gives the environments that apply with the project's own.
        var detail = try #require(workspace.details["API"])
        detail.project.environments[1].name = "stage"
        detail.environments = detail.project.environments
        workspace.details["API"] = detail
        #expect(model.environment == local)
        #expect(model.stored?.environment == "staging")

        // Removed: no environment is left, Send is disabled.
        detail.project.environments = []
        detail.environments = []
        workspace.details["API"] = detail
        #expect(model.environment == nil)
        #expect(!model.canSend)
    }

    @Test func projectsOfOtherTypesHaveNoEnvironment() async throws {
        let cases: [(ProjectType, [ProjectEnvironment])] = [(.goService, []), (.none, [local]), (.swiftApplication, [local])]
        for (type, environments) in cases {
            // The buffer holds its workspace weakly: the test keeps it.
            let (workspace, buffer, model) = try await contractModel(type: type, environments: environments)
            #expect(workspace.details["API"]?.project.environments == environments)
            #expect(model.environments.isEmpty, "\(type)")
            #expect(model.environment == nil, "\(type)")
            #expect(!model.canSend, "\(type)")
            buffer.detach()
        }
    }

    @Test func inheritedNamesAreTakenByTheNameField() {
        let inherited = [ProjectEnvironment(name: "staging", url: "https://staging.example.com")]
        let own = [ProjectEnvironment(name: "local", url: "http://127.0.0.1")]
        let names = ProjectRules.otherEnvironmentNames(own, inherited: inherited, editing: nil)
        #expect(names == ["local", "staging"])
        #expect(ProjectRules.environmentNameMessage(" staging ", otherNames: names) == "An environment named “staging” already exists.")
        #expect(ProjectRules.environmentNameMessage("Staging", otherNames: names) == nil)
        #expect(ProjectRules.otherEnvironmentNames(own, inherited: inherited, editing: own[0]) == ["staging"])
    }

    @Test func changeOfAnInheritedEnvironment() {
        #expect(ProjectRules.inheritedEnvironmentURLMessage("") == nil)
        #expect(ProjectRules.inheritedEnvironmentURLMessage("  ") == nil)
        #expect(ProjectRules.inheritedEnvironmentURLMessage("localhost:8080") == "Enter an http or https URL.")
        #expect(ProjectRules.inheritedEnvironmentURLMessage(" https://worker.example.com ") == nil)
        let stored = EnvironmentOverride(port: 8081, unknownKeys: ["region": "eu-west-1"])
        let change = ProjectRules.environmentOverride(url: " https://worker.example.com ", port: " ", deployment: " orders-worker ",
                                                      argoCDApplication: "", stored: stored)
        #expect(change == EnvironmentOverride(url: "https://worker.example.com", deployment: "orders-worker", unknownKeys: ["region": "eu-west-1"]))
        #expect(ProjectRules.environmentOverride(url: "", port: "9000", deployment: "", argoCDApplication: " argocd/w ", stored: nil)
            == EnvironmentOverride(port: 9000, argoCDApplication: "argocd/w"))
        // Four empty fields remove the change: the parent's values apply again.
        #expect(ProjectRules.environmentOverride(url: " ", port: "", deployment: "", argoCDApplication: "", stored: stored) == nil)
        let gone = EnvironmentOverride(port: 7000)
        let overrides = ["staging": stored, "gone": gone]
        #expect(ProjectRules.environmentOverrides(overrides, saving: change, for: "staging") == ["staging": change!, "gone": gone])
        #expect(ProjectRules.environmentOverrides(overrides, saving: nil, for: "staging") == ["gone": gone])
        #expect(ProjectRules.environmentOverrides([:], saving: gone, for: "local") == ["local": gone])
    }

    @Test func contractEnvironmentsAreTheEnvironmentsThatApply() async throws {
        let own = ProjectEnvironment(name: "replay", url: "http://127.0.0.1", port: 9090)
        let (workspace, buffer, model) = try await contractModel(type: .goService, environments: [own])
        defer { buffer.detach() }
        #expect(model.environments == [own])
        let inherited = ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080)
        var changed = inherited
        changed.port = 8081
        workspace.details["API"]?.environments = [changed, own]
        workspace.details["API"]?.inheritedEnvironments = [inherited]
        #expect(model.environments == [changed, own])
        #expect(model.environment == changed)
        #expect(model.canSend)
    }

    @Test func environmentWrittenByHandWithAnInvalidURLCannotSend() async throws {
        let (workspace, buffer, model) = try await contractModel(type: .goService,
                                                                environments: [ProjectEnvironment(name: "files", url: "ftp://example.com")])
        defer { buffer.detach() }
        #expect(model.environment?.name == "files")
        #expect(!model.canSend)
        #expect(workspace.details["API"] != nil)
    }

    /// `ProjectRules.environment` with the sheet's fields, the ones not given empty.
    private func sheetEnvironment(name: String, url: String, port: String = "", context: String = "", namespace: String = "",
                                  deployment: String = "", argoCDApplication: String = "", kubeconfig: String = "",
                                  editing original: ProjectEnvironment? = nil) -> ProjectEnvironment {
        ProjectRules.environment(name: name, url: url, port: port, context: context, namespace: namespace, deployment: deployment,
                                 argoCDApplication: argoCDApplication, kubeconfig: kubeconfig, editing: original)
    }

    /// The Contract view model of a contract tab of the project `API` in an offline workspace,
    /// once the contract is parsed. Without a window, the stored values stay in memory.
    private func contractModel(type: ProjectType, environments: [ProjectEnvironment]) async throws
        -> (DeviceWorkspace, EditorBuffer, OpenAPIContractModel) {
        let workspace = DeviceWorkspace(deviceID: "device", connection: OfflineConnection(), isLocal: true)
        let project = Project(id: "API", name: "Api", created: Self.created, type: type, environments: environments)
        workspace.details["API"] = ProjectDetail(project: project, rootPath: "/Users/example/Api")
        let buffer = EditorBuffer(path: "api/openapi.yaml")
        buffer.takeNewFile(text: Self.contract, modified: Self.created, workspace: workspace, projectID: "API", window: nil)
        let model = buffer.contractModel
        model.appear()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.contract == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.contract != nil)
        return (workspace, buffer, model)
    }
}
