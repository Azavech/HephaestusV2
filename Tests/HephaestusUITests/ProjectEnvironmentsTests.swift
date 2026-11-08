import Foundation
import HephaestusCore
import Testing
@testable import HephaestusUI

/// docs/projects.md › Environments and docs/openapi.md › Environment: the messages of the fields
/// of the Environments section and the lists they apply, and the Environment pop-up of a
/// contract's request form with the environment stored for the contract.
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

    @Test func fieldMessages() {
        let name = "Enter a name of 1 to 100 characters."
        #expect(ProjectRules.environmentNameMessage("", otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage("   ", otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage("two\nlines", otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage(String(repeating: "x", count: 101), otherNames: []) == name)
        #expect(ProjectRules.environmentNameMessage(String(repeating: "x", count: 100), otherNames: []) == nil)
        #expect(ProjectRules.environmentNameMessage(" local ", otherNames: ["local"]) == "An environment named “local” already exists.")
        #expect(ProjectRules.environmentNameMessage("Local", otherNames: ["local"]) == nil)

        // The URL is optional: an empty field removes it.
        for valid in ["", "  ", "http://127.0.0.1", " https://staging.example.com/v1 "] {
            #expect(ProjectRules.environmentURLMessage(valid) == nil, "\(valid)")
        }
        for invalid in ["127.0.0.1:8080", "ftp://example.com", "/v1", "http://", "localhost:8080"] {
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
        #expect(ProjectRules.normalizedEnvironmentPort(" 08080 ") == "8080")
        #expect(ProjectRules.normalizedEnvironmentPort(" ") == "")
        #expect(ProjectRules.normalizedEnvironmentPort("80a") == "80a")
    }

    @Test func kubeconfigFieldMessage() {
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

    @Test func plusNamesTheNewEnvironment() {
        #expect(ProjectRules.newEnvironmentName(taken: []) == "New Environment")
        #expect(ProjectRules.newEnvironmentName(taken: ["local", "staging"]) == "New Environment")
        #expect(ProjectRules.newEnvironmentName(taken: ["New Environment"]) == "New Environment 2")
        #expect(ProjectRules.newEnvironmentName(taken: ["New Environment", "New Environment 2"]) == "New Environment 3")
        // The first free number: a gap is used again.
        #expect(ProjectRules.newEnvironmentName(taken: ["New Environment", "New Environment 3"]) == "New Environment 2")
        // Letter case counts: `new environment` is another name.
        #expect(ProjectRules.newEnvironmentName(taken: ["new environment"]) == "New Environment")
        // `+` appends an environment with every other field empty.
        #expect(ProjectRules.environments([local, staging], adding: "New Environment")
            == [local, staging, ProjectEnvironment(name: "New Environment")])
    }

    @Test func eachFieldAppliesTheWholeListWithItsChange() {
        // A field changes its environment only; the others, and its other keys, stay as stored.
        var stored = ProjectEnvironment(name: "staging", url: "https://staging.example.com", namespace: "orders",
                                        deployment: "orders-api", argoCDApplication: "argocd/orders-staging",
                                        kubeconfig: "~/.kube/staging.yaml", unknownKeys: ["context": "staging-eks"])
        let renamed = ProjectRules.environments([local, stored], changing: "staging") { $0.name = "stage" }
        stored.name = "stage"
        #expect(renamed == [local, stored])
        let cleared = ProjectRules.environments([local, stored], changing: "stage") { $0.url = nil; $0.port = nil }
        #expect(cleared?[1] == ProjectEnvironment(name: "stage", namespace: "orders", deployment: "orders-api",
                                                  argoCDApplication: "argocd/orders-staging", kubeconfig: "~/.kube/staging.yaml",
                                                  unknownKeys: ["context": "staging-eks"]))
        #expect(cleared?[0] == local)
        let browsed = ProjectRules.environments([local], changing: "local") { $0.kubeconfig = "/Users/example/.kube/config" }
        #expect(browsed == [ProjectEnvironment(name: "local", url: "http://127.0.0.1", port: 8080, kubeconfig: "/Users/example/.kube/config")])
        // Renamed or removed meanwhile: nothing applies.
        #expect(ProjectRules.environments([local], changing: "staging") { $0.deployment = "x" } == nil)

        // `−` removes the selected environment only.
        #expect(ProjectRules.environments([local, staging], removing: "local") == [staging])
        #expect(ProjectRules.environments([local, staging], removing: "dev") == nil)
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
        // Each field changes its value of the stored change, which keeps its Argo CD application
        // and unknown keys.
        let stored = EnvironmentOverride(port: 8081, argoCDApplication: "argocd/w", unknownKeys: ["region": "eu-west-1"])
        let gone = EnvironmentOverride(port: 7000)
        let overrides = ["staging": stored, "gone": gone]
        let url = ProjectRules.environmentOverrides(overrides, changing: "staging") { $0.url = "https://worker.example.com" }
        #expect(url == ["staging": EnvironmentOverride(url: "https://worker.example.com", port: 8081, argoCDApplication: "argocd/w",
                                                       unknownKeys: ["region": "eu-west-1"]),
                        "gone": gone])
        #expect(ProjectRules.environmentOverrides([:], changing: "local") { $0.deployment = "orders-worker" }
            == ["local": EnvironmentOverride(deployment: "orders-worker")])
        // A change that no longer sets any value is removed: the parent's values apply again.
        #expect(ProjectRules.environmentOverrides(["local": gone], changing: "local") { $0.port = nil } == [:])
        #expect(ProjectRules.environmentOverrides(overrides, changing: "staging") { $0.port = nil }
            == ["staging": EnvironmentOverride(argoCDApplication: "argocd/w", unknownKeys: ["region": "eu-west-1"]), "gone": gone])
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

    @Test func environmentWithoutURLIsListedByNameAndCannotSend() async throws {
        let replay = ProjectEnvironment(name: "replay", namespace: "orders")
        let (workspace, buffer, model) = try await contractModel(type: .goService, environments: [replay, local])
        defer { buffer.detach() }
        let contract = try #require(model.contract)
        let operation = try #require(contract.operations.first)
        #expect(OpenAPIRequestFormView.itemTitle(replay) == "replay")
        #expect(OpenAPIRequestFormView.itemTitle(local) == "local · http://127.0.0.1:8080")
        #expect(OpenAPIRequestFormView.noURLNote == "Set the API Access of this environment in Project Settings.")
        #expect(model.environment == replay)
        #expect(!model.canSend)
        #expect(model.requestInput(operation, contract: contract).baseURL == "")
        model.selectEnvironment("local")
        #expect(model.canSend)
        #expect(workspace.details["API"] != nil)
    }

    @Test func environmentWrittenByHandWithAnInvalidURLCannotSend() async throws {
        let (workspace, buffer, model) = try await contractModel(type: .goService,
                                                                environments: [ProjectEnvironment(name: "files", url: "ftp://example.com")])
        defer { buffer.detach() }
        #expect(model.environment?.name == "files")
        #expect(!model.canSend)
        #expect(workspace.details["API"] != nil)
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
