import Foundation

/// A named secrets source in a node's `cloud.json`, under `secrets.sources`. It has its own
/// credentials (`tender credentials set --source <name>`), so a service can read secrets
/// through an account that no other service on the node can use.
public struct SecretSourceConfig: Codable, Sendable, Equatable {
    public static let gcpKind = "gcp"

    /// Only `gcp` so far. A string, not an enum, so that a kind this tenderd doesn't know
    /// fails that one source instead of the whole of `cloud.json`.
    public var kind: String?
    /// The project of references that name none, as in `${secret:billing:NAME}`.
    public var project: String?
    /// The services allowed to use it. Nil allows every service on the node.
    public var services: [String]?

    public init(kind: String? = nil, project: String? = nil, services: [String]? = nil) {
        self.kind = kind
        self.project = project
        self.services = services
    }

    public var resolvedKind: String { kind ?? Self.gcpKind }
}

/// Why a reference can't be resolved on a node. Names the reference, never a value.
public enum SecretSourceError: Error, Equatable, CustomStringConvertible {
    case noProject(source: String?, secret: String)
    case unknownSource(String)
    case unsupportedKind(source: String, kind: String)
    case notAllowed(source: String, service: String)

    public var description: String {
        switch self {
        case .noProject(nil, let secret):
            "gcp:\(secret) names no project and this node has no default one. Set secrets.project in cloud.json, or write gcp:projects/<project>/secrets/\(secret)."
        case .noProject(let source?, let secret):
            "\(source):\(secret) names no project and the source '\(source)' has none. Set secrets.sources.\(source).project in cloud.json, or write \(source):projects/<project>/secrets/\(secret)."
        case .unknownSource(let source):
            "This node has no secrets source named '\(source)'. Add it under secrets.sources in cloud.json, then run `tender credentials set --source \(source) --file <key.json>` on the node."
        case .unsupportedKind(let source, let kind):
            "The secrets source '\(source)' is of kind '\(kind)', which this tenderd can't use. Only 'gcp' is supported."
        case .notAllowed(let source, let service):
            "The secrets source '\(source)' doesn't allow \(service). Add it to secrets.sources.\(source).services in the node's cloud.json."
        }
    }
}

/// A node's secrets sources: the default one, which `${secret:gcp:…}` uses, and the named
/// ones in `cloud.json`. Decides which references a service may use, and what they fetch.
public struct SecretSources: Sendable, Equatable {
    /// The default source's name in references and listings.
    public static let defaultName = "gcp"

    public var defaultProject: String?
    public var named: [String: SecretSourceConfig]

    public init(defaultProject: String? = nil, named: [String: SecretSourceConfig] = [:]) {
        self.defaultProject = defaultProject
        self.named = named
    }

    /// The version `ref` stands for when `service` uses it.
    public func resolve(_ ref: GCPSecretRef, service: String) -> Result<GCPSecretVersion, SecretSourceError> {
        var project = defaultProject
        if let source = ref.source {
            guard let config = named[source] else { return .failure(.unknownSource(source)) }
            guard config.resolvedKind == SecretSourceConfig.gcpKind else {
                return .failure(.unsupportedKind(source: source, kind: config.resolvedKind))
            }
            if let services = config.services, !services.contains(service) {
                return .failure(.notAllowed(source: source, service: service))
            }
            project = config.project
        }
        guard let version = ref.resolved(defaultProject: project) else {
            return .failure(.noProject(source: ref.source, secret: ref.description))
        }
        return .success(version)
    }

    /// Where a source's service account key is kept in the node's `SecretStore`. The
    /// default source's is also what release fetching and log offload use.
    public static func credentialsItem(_ source: String?) -> String {
        source.map { "credentials.\($0).json" } ?? "gcp.json"
    }

    /// Lowercase letters, digits and `-`, starting with a letter, up to 32 characters, and
    /// neither `gcp` nor `shared`. No `.`, `:`, `/` or `@`, so it can't be confused with
    /// the rest of a reference or of a cache item.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...32).contains(name.count), name != defaultName, name != "shared", name.last != "-",
              let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "0"..."9", "-": true
            default: false
            }
        }
    }
}

/// One secrets source as a node reports it, for `tender credentials show`, `tender nodes`
/// and the app. Never carries a key or a value.
public struct SecretSourceStatus: Codable, Sendable, Equatable {
    /// `gcp` for the default source.
    public var name: String
    public var kind: String
    public var project: String?
    /// Nil when every service may use it.
    public var services: [String]?
    /// The service account's email, when the node holds a usable key.
    public var account: String?
    /// Why the source can't be used at all: no key, an unreadable one, an unknown kind,
    /// or a reference to a source `cloud.json` doesn't define.
    public var problem: String?
    /// Services on the node with references through it.
    public var usedBy: [String]
    /// Distinct secret versions referenced through it.
    public var references: Int
    /// Of those, the ones whose last fetch failed.
    public var failing: Int
    /// The most recent of those failures.
    public var lastError: String?

    public init(name: String, kind: String = SecretSourceConfig.gcpKind, project: String? = nil, services: [String]? = nil,
                account: String? = nil, problem: String? = nil, usedBy: [String] = [], references: Int = 0,
                failing: Int = 0, lastError: String? = nil) {
        self.name = name
        self.kind = kind
        self.project = project
        self.services = services
        self.account = account
        self.problem = problem
        self.usedBy = usedBy
        self.references = references
        self.failing = failing
        self.lastError = lastError
    }

    public var isDefault: Bool { name == SecretSources.defaultName }
    /// Usable, and every reference through it fetched last time.
    public var isHealthy: Bool { problem == nil && failing == 0 }
}

/// What a node has for secrets: how many it holds itself, and where it fetches the rest.
public struct NodeSecretsStatus: Codable, Sendable, Equatable {
    /// Secrets set on the node with `tender secret set`.
    public var localSecrets: Int
    /// Configured or referenced sources, the default one first.
    public var sources: [SecretSourceStatus]

    public init(localSecrets: Int = 0, sources: [SecretSourceStatus] = []) {
        self.localSecrets = localSecrets
        self.sources = sources
    }

    /// Whether any source can be used: what "has a secrets manager attached" means.
    public var hasSource: Bool { sources.contains { $0.account != nil && $0.problem == nil } }
}
