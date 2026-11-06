import Foundation

extension TenderVersion {
    /// Exact match required at handshake. Add new `distributed func`s rather than
    /// changing shipped ones, and bump this when a node can't serve an older peer.
    /// 3: secrets (`setSecret`, `deleteSecret`, `listSecrets`).
    /// 4: service files (`specs`, `applyManifest`) and GCP secrets
    /// (`Heartbeat.secretFetchErrors`, `SecretList.gcp`).
    public static let protocolVersion = 4
}

/// How a failed call on a node is reported, locally and across the wire.
public struct NodeCallError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var httpStatus: Int

    public init(code: String, message: String, httpStatus: Int = 500) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
    }

    public var description: String { message }
}

/// What a node tells the head about itself.
public struct NodeInfo: Codable, Sendable, Equatable {
    public var id: NodeID
    public var version: String
    public var macOS: String
    public var hardware: String
    public var address: String?
    public var labels: [String: String]
    /// Whether the node is listening for peers. Nil from nodes running an older tenderd.
    public var network: NetworkState?
    /// What people call the machine. A label only: the ID is what identifies the node.
    public var hostname: String?

    public init(id: NodeID, version: String, macOS: String, hardware: String,
                address: String? = nil, labels: [String: String] = [:], network: NetworkState? = nil, hostname: String? = nil) {
        self.hostname = hostname
        self.network = network
        self.id = id
        self.version = version
        self.macOS = macOS
        self.hardware = hardware
        self.address = address
        self.labels = labels
    }

    public static let roleLabel = "role"
    public static let headRole = "head"

    /// The hostname if there is one, else the ID.
    public var displayName: String { hostname ?? id.rawValue }

    public var isHead: Bool { labels[Self.roleLabel] == Self.headRole }
}

/// A node as the head sees it, for `tender nodes` and the app.
public struct NodeSummary: Codable, Sendable, Equatable {
    public var info: NodeInfo
    public var up: Bool
    /// Seconds since the last heartbeat. Nil if none arrived since the head started.
    public var lastHeartbeatAge: TimeInterval?
    public var instanceCount: Int
    public var crashedCount: Int
    /// Head clock minus node clock. Positive means the node is behind.
    public var clockSkew: TimeInterval?
    public var spoolBacklog: Int
    public var spoolDropped: Int
    /// Failed GCP Secret Manager fetches since the node's daemon started.
    public var secretFetchErrors: Int
    /// From the latest heartbeat. Nil from nodes running an older tenderd.
    public var stats: NodeStats?

    public init(info: NodeInfo, up: Bool, lastHeartbeatAge: TimeInterval?, instanceCount: Int, crashedCount: Int,
                clockSkew: TimeInterval? = nil, spoolBacklog: Int = 0, spoolDropped: Int = 0, secretFetchErrors: Int = 0,
                stats: NodeStats? = nil) {
        self.stats = stats
        self.secretFetchErrors = secretFetchErrors
        self.clockSkew = clockSkew
        self.spoolBacklog = spoolBacklog
        self.spoolDropped = spoolDropped
        self.info = info
        self.up = up
        self.lastHeartbeatAge = lastHeartbeatAge
        self.instanceCount = instanceCount
        self.crashedCount = crashedCount
    }
}

public struct NodeList: Codable, Sendable, Equatable {
    public var nodes: [NodeSummary]
    public init(nodes: [NodeSummary]) { self.nodes = nodes }
}

/// An action on a process, optionally limited to one node.
public struct ClusterSpecRequest: Codable, Sendable, Equatable {
    public var spec: ServiceSpec
    public init(spec: ServiceSpec) { self.spec = spec }
}

public struct JoinTokenResponse: Codable, Sendable, Equatable {
    public var token: String
    public var expiresAt: Date
    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public struct JoinTokenRequest: Codable, Sendable, Equatable {
    public var ttlSeconds: Int?
    public init(ttlSeconds: Int? = nil) { self.ttlSeconds = ttlSeconds }
}

/// Sent to the head's public API to obtain a certificate.
public struct JoinRequest: Codable, Sendable, Equatable {
    public var token: String
    public var nodeID: NodeID
    public var csrPEM: String
    public init(token: String, nodeID: NodeID, csrPEM: String) {
        self.token = token
        self.nodeID = nodeID
        self.csrPEM = csrPEM
    }
}

public struct JoinResponse: Codable, Sendable, Equatable {
    public var certificatePEM: String
    public var caPEM: String
    public var headNode: NodeID
    public var headAgentAddress: String
    public init(certificatePEM: String, caPEM: String, headNode: NodeID, headAgentAddress: String) {
        self.certificatePEM = certificatePEM
        self.caPEM = caPEM
        self.headNode = headNode
        self.headAgentAddress = headAgentAddress
    }
}

/// Sent to the local daemon by `tender join`.
public struct LocalJoinRequest: Codable, Sendable, Equatable {
    public var head: String
    public var token: String
    public var nodeID: String?
    public init(head: String, token: String, nodeID: String? = nil) {
        self.head = head
        self.token = token
        self.nodeID = nodeID
    }
}

public struct CertificateExport: Codable, Sendable, Equatable {
    public var certificatePEM: String
    public var privateKeyPEM: String
    public init(certificatePEM: String, privateKeyPEM: String) {
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
    }
}

public enum APIScope: String, Codable, Sendable {
    case read, write
}

public struct APITokenCreateRequest: Codable, Sendable, Equatable {
    public var name: String
    public var scope: APIScope
    public init(name: String, scope: APIScope) {
        self.name = name
        self.scope = scope
    }
}

public struct APITokenInfo: Codable, Sendable, Equatable {
    public var name: String
    public var scope: APIScope
    public var createdAt: Date
    public init(name: String, scope: APIScope, createdAt: Date) {
        self.name = name
        self.scope = scope
        self.createdAt = createdAt
    }
}

public struct APITokenCreated: Codable, Sendable, Equatable {
    public var info: APITokenInfo
    /// Shown once. Only its hash is stored.
    public var token: String
    public init(info: APITokenInfo, token: String) {
        self.info = info
        self.token = token
    }
}

public struct APITokenList: Codable, Sendable, Equatable {
    public var tokens: [APITokenInfo]
    public init(tokens: [APITokenInfo]) { self.tokens = tokens }
}

public struct JoinStatus: Codable, Sendable, Equatable {
    public var nodeID: NodeID
    public var headNode: NodeID
    public init(nodeID: NodeID, headNode: NodeID) {
        self.nodeID = nodeID
        self.headNode = headNode
    }
}
