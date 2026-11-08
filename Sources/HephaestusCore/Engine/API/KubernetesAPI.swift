import Foundation

// docs/engine-api.md › Kubernetes and Argo CD: the methods behind the Kubernetes and Argo CD tools
// of the MCP server (docs/mcp.md › Kubernetes and Argo CD tools), each acting for the chat
// `chatID`, which must be the actor's; and the kubeconfig methods that the Environments section of
// Project Settings calls (docs/engine-api.md › Kubeconfig methods), and the method that the
// Dashboard's Instances widget calls (docs/engine-api.md › kubernetes.pods).

/// `kubernetes.status`: the state of the Deployment of an environment and of its pods. Actors:
/// claude (the chat's own Claude only).
public enum KubernetesStatus: EngineMethod {
    public static let name = "kubernetes.status"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String

        public init(chatID: ChatID, environment: String) {
            self.chatID = chatID
            self.environment = environment
        }
    }
    public typealias Result = DeploymentStatus
}

/// `kubernetes.logs`: the last log lines of one pod, or of every pod of the Deployment of an
/// environment. Actors: claude (the chat's own Claude only).
public enum KubernetesLogs: EngineMethod {
    public static let name = "kubernetes.logs"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String
        /// The pod, the container, the number of lines, the time span and previous.
        public var options: LogOptions?

        public init(chatID: ChatID, environment: String, options: LogOptions? = nil) {
            self.chatID = chatID
            self.environment = environment
            self.options = options
        }
    }
    public typealias Result = KubectlOutput
}

/// `kubernetes.events`: the events of the Deployment of an environment, of its ReplicaSets and of
/// their pods, newest first. Actors: claude (the chat's own Claude only).
public enum KubernetesEvents: EngineMethod {
    public static let name = "kubernetes.events"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String

        public init(chatID: ChatID, environment: String) {
            self.chatID = chatID
            self.environment = environment
        }
    }
    public typealias Result = [ClusterEvent]
}

/// `kubernetes.restart`: `kubectl rollout restart` of the Deployment of an environment. Actors:
/// claude (the chat's own Claude only).
public enum KubernetesRestart: EngineMethod {
    public static let name = "kubernetes.restart"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String

        public init(chatID: ChatID, environment: String) {
            self.chatID = chatID
            self.environment = environment
        }
    }
    public typealias Result = KubectlOutput
}

/// `kubernetes.scale`: sets the replicas of the Deployment of an environment. Actors: claude (the
/// chat's own Claude only).
public enum KubernetesScale: EngineMethod {
    public static let name = "kubernetes.scale"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String
        /// 0 to 2,147,483,647.
        public var replicas: Int

        public init(chatID: ChatID, environment: String, replicas: Int) {
            self.chatID = chatID
            self.environment = environment
            self.replicas = replicas
        }
    }
    public typealias Result = KubectlOutput
}

/// `kubernetes.forward`: starts a port forward from 127.0.0.1 to the Deployment of an environment,
/// kept with the chat. Actors: claude (the chat's own Claude only).
public enum KubernetesForward: EngineMethod {
    public static let name = "kubernetes.forward"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String
        /// Port in the pod, 1–65535.
        public var remotePort: Int
        /// Port on 127.0.0.1, 1–65535; kubectl picks a free one when nil.
        public var localPort: Int?

        public init(chatID: ChatID, environment: String, remotePort: Int, localPort: Int? = nil) {
            self.chatID = chatID
            self.environment = environment
            self.remotePort = remotePort
            self.localPort = localPort
        }
    }
    public typealias Result = PortForward
}

/// `kubernetes.stopForward`: stops a port forward of the chat. Actors: claude (the chat's own
/// Claude only).
public enum KubernetesStopForward: EngineMethod {
    public static let name = "kubernetes.stopForward"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// `portForwardID` of a PortForward of this chat.
        public var portForwardID: UUID

        public init(chatID: ChatID, portForwardID: UUID) {
            self.chatID = chatID
            self.portForwardID = portForwardID
        }
    }
    public typealias Result = Empty
}

/// `argoCD.status`: the state of the Argo CD Application of an environment. Actors: claude (the
/// chat's own Claude only).
public enum ArgoCDStatus: EngineMethod {
    public static let name = "argoCD.status"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String

        public init(chatID: ChatID, environment: String) {
            self.chatID = chatID
            self.environment = environment
        }
    }
    public typealias Result = ArgoCDAppStatus
}

/// `argoCD.sync`: starts a sync of the Argo CD Application of an environment by setting its sync
/// operation. Actors: claude (the chat's own Claude only).
public enum ArgoCDSync: EngineMethod {
    public static let name = "argoCD.sync"
    public struct Params: Codable, Sendable, Hashable {
        /// Must be the actor's chatID.
        public var chatID: ChatID
        /// Name of an environment of the chat's project.
        public var environment: String

        public init(chatID: ChatID, environment: String) {
            self.chatID = chatID
            self.environment = environment
        }
    }
    public typealias Result = KubectlOutput
}

/// `kubernetes.check`: checks that kubectl reaches the cluster of a kubeconfig file, in the file's
/// current context. Actors: user.
public enum KubernetesCheck: EngineMethod {
    public static let name = "kubernetes.check"
    public struct Params: Codable, Sendable, Hashable {
        /// The project in whose root kubectl runs.
        public var projectID: ProjectID
        /// The kubeconfig file on the main device: an absolute path or a path starting with `~/`.
        public var kubeconfig: String

        public init(projectID: ProjectID, kubeconfig: String) {
            self.projectID = projectID
            self.kubeconfig = kubeconfig
        }
    }
    public typealias Result = Empty
}

/// `kubernetes.namespaces`: the names of the namespaces of the cluster of a kubeconfig file, in
/// kubectl's order. Actors: user.
public enum KubernetesNamespaces: EngineMethod {
    public static let name = "kubernetes.namespaces"
    public struct Params: Codable, Sendable, Hashable {
        /// The project in whose root kubectl runs.
        public var projectID: ProjectID
        /// The kubeconfig file on the main device: an absolute path or a path starting with `~/`.
        public var kubeconfig: String

        public init(projectID: ProjectID, kubeconfig: String) {
            self.projectID = projectID
            self.kubeconfig = kubeconfig
        }
    }
    public typealias Result = [String]
}

/// `kubernetes.deployments`: the names of the deployments of a namespace of the cluster of a
/// kubeconfig file, in kubectl's order. Actors: user.
public enum KubernetesDeployments: EngineMethod {
    public static let name = "kubernetes.deployments"
    public struct Params: Codable, Sendable, Hashable {
        /// The project in whose root kubectl runs.
        public var projectID: ProjectID
        /// The kubeconfig file on the main device: an absolute path or a path starting with `~/`.
        public var kubeconfig: String
        /// The namespace, trimmed, empty counting as absent; nil: the namespace of the file's
        /// current context.
        public var namespace: String?

        public init(projectID: ProjectID, kubeconfig: String, namespace: String? = nil) {
            self.projectID = projectID
            self.kubeconfig = kubeconfig
            self.namespace = namespace
        }
    }
    public typealias Result = [String]
}

/// `kubernetes.pods`: the pods of the Deployment of an environment of a project, for the
/// Dashboard's Instances widget. Actors: user.
public enum KubernetesPods: EngineMethod {
    public static let name = "kubernetes.pods"
    public struct Params: Codable, Sendable, Hashable {
        /// Project identifier.
        public var projectID: ProjectID
        /// Name of an environment of the project as they apply, inherited ones included.
        public var environment: String

        public init(projectID: ProjectID, environment: String) {
            self.projectID = projectID
            self.environment = environment
        }
    }
    public typealias Result = [PodStatus]

    /// The message of an environment without a deployment, which the Instances widget also shows
    /// without calling the method (docs/dashboard.md › Instances widget).
    public static func noDeploymentMessage(environment: String) -> String {
        "Environment “\(environment)” has no deployment."
    }
}
