import Foundation
import TenderClient
import TenderCore

/// What the MCP tools need from a cluster. The head implements it by calling its own
/// services, and `tender mcp` over `TenderClient`, so the tools are the same either way.
public protocol ClusterBackend: Sendable {
    func nodes() async throws -> NodeList
    func processes() async throws -> ProcessList
    func searchLogs(_ query: LogQuery) async throws -> LogSearchResult
    func releases(service: String) async throws -> ClusterReleases
    func start(service: String, node: String?) async throws -> ProcessList
    func stop(service: String, node: String?) async throws -> ProcessList
    func restart(service: String, node: String?) async throws -> ProcessList
    func deploy(_ request: DeployRequest) async throws -> DeployResponse
    func rollback(service: String, to sha12: String?, node: String?) async throws -> ProcessList
    /// Names, nodes and revisions. No backend ever returns a secret's value.
    func secrets() async throws -> SecretList
}

/// For `tender mcp`: every call goes to the head (or the local daemon) through its
/// API, so the token's scope and the head's audit log apply as for the CLI.
public struct ClientBackend: ClusterBackend {
    let client: TenderClient

    public init(client: TenderClient) { self.client = client }

    public func nodes() async throws -> NodeList { try await client.nodes() }
    public func processes() async throws -> ProcessList { try await client.list() }
    public func searchLogs(_ query: LogQuery) async throws -> LogSearchResult { try await client.searchLogs(query) }
    public func releases(service: String) async throws -> ClusterReleases { try await client.clusterReleases(service: service) }
    public func start(service: String, node: String?) async throws -> ProcessList {
        try await client.start(service: service, node: node)
    }
    public func stop(service: String, node: String?) async throws -> ProcessList {
        try await client.stop(service: service, node: node)
    }
    public func restart(service: String, node: String?) async throws -> ProcessList {
        try await client.restart(service: service, node: node)
    }
    public func deploy(_ request: DeployRequest) async throws -> DeployResponse {
        try await client.deploy(service: request.service, version: request.version, node: request.node)
    }
    public func rollback(service: String, to sha12: String?, node: String?) async throws -> ProcessList {
        try await client.rollback(service: service, to: sha12, node: node)
    }
    public func secrets() async throws -> SecretList { try await client.secrets() }
}
