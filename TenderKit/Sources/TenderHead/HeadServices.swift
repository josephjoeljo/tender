import Crypto
import Distributed
import Foundation
import Hummingbird
import HummingbirdTLS
import Logging
import NIOConcurrencyHelpers
import NIOSSL
import ServiceLifecycle
import TenderActorSystem
import TenderAgent
import TenderCore
import TenderLogStore
import TenderMCP
import TenderMetrics
import TenderPKI
import TenderProtocol

public struct HeadOptions: Sendable {
    public var nodeID: NodeID
    public var apiHost: String?
    public var apiPort: Int
    public var agentPort: Int
    /// Hostnames and IPs the head is reached by, for its certificate.
    public var advertisedNames: [String]
    /// Plain HTTP on the tailnet, for Prometheus. Nil turns it off.
    public var metricsPort: Int?

    public init(nodeID: NodeID, apiHost: String? = nil, apiPort: Int = 7071, agentPort: Int = 7070,
                advertisedNames: [String] = [], metricsPort: Int? = 7072) {
        self.metricsPort = metricsPort
        self.nodeID = nodeID
        self.apiHost = apiHost
        self.apiPort = apiPort
        self.agentPort = agentPort
        self.advertisedNames = advertisedNames
    }
}

public enum AuthorityStoreError: Error, Equatable, CustomStringConvertible {
    case incomplete(missing: String)
    case differentAuthority(backup: String)

    public var description: String {
        switch self {
        case .incomplete(let missing):
            "This node has part of a CA, but \(missing) is missing. Restore a backup with `tenderd ca-import`, "
                + "or see docs/ops/cluster.md if there's no backup or this node used to be a worker."
        case .differentAuthority(let backup):
            "This node holds a different CA from the backup (\(backup)). "
                + "Pass --replace to overwrite it. Nodes that joined the current CA will have to join again."
        }
    }
}

/// Everything only the head does: CA, registry, command routing, public API.
public final class HeadServices: Sendable {
    public let options: HeadOptions
    public let store: HeadStore
    public let state: RegistryState
    public let logs: LogStore
    public let audit: AuditLog
    private let deploys = DeployCounter()
    /// One instance, so that the write rate limit holds across requests.
    let mcpTools = NIOLockedValueBox<TenderTools?>(nil)
    private let environment: TenderEnvironment
    private let secrets: any SecretStore
    private let authority: CertificateAuthority
    private let holder = NIOLockedValueBox<(system: TenderActorSystem?, registry: HeadRegistry?)>((nil, nil))
    private let logger: Logger

    public init(environment: TenderEnvironment, secrets: any SecretStore, options: HeadOptions,
                logger: Logger = Logger(label: "tender.head")) throws {
        self.environment = environment
        self.secrets = secrets
        self.options = options
        self.logger = logger
        store = try HeadStore(environment: environment)
        state = RegistryState(store: store)
        logs = try LogStore(directory: environment.root.appending(path: "logstore"))
        audit = try AuditLog(directory: environment.root.appending(path: "logstore"))
        authority = try Self.loadOrCreateAuthority(secrets: secrets)
        try Self.issueOwnIdentity(environment: environment, secrets: secrets, authority: authority, options: options)
    }

    /// Creates the CA on first start. Losing it means every node has to re-join, so
    /// it's printed nowhere and leaves only through `tender ca export`. Half a CA is
    /// refused: creating a new one would overwrite the half that's left.
    static func loadOrCreateAuthority(secrets: any SecretStore) throws -> CertificateAuthority {
        let certificate = try secrets.read(ClusterSecrets.caCertificate)
        let key = try secrets.read(ClusterSecrets.caKey)
        switch (certificate, key) {
        case (let certificate?, let key?):
            return try CertificateAuthority(certificatePEM: String(decoding: certificate, as: UTF8.self),
                                            privateKeyPEM: String(decoding: key, as: UTF8.self))
        case (nil, nil):
            let created = try CertificateAuthority.create()
            try secrets.write(ClusterSecrets.caKey, Data(created.privateKeyPEM.utf8))
            try secrets.write(ClusterSecrets.caCertificate, Data(created.certificatePEM.utf8))
            return created
        case (_?, nil):
            throw AuthorityStoreError.incomplete(missing: ClusterSecrets.caKey)
        case (nil, _?):
            throw AuthorityStoreError.incomplete(missing: ClusterSecrets.caCertificate)
        }
    }

    /// Puts a `tender ca export` backup back. The caller restarts the daemon, which
    /// reads the CA once at start. Without `replace`, a different CA is left alone.
    @discardableResult
    public static func restoreAuthority(backupPEM: String, secrets: any SecretStore, replace: Bool) throws -> CertificateAuthority {
        let backup = try CertificateAuthority(backupPEM: backupPEM)
        if !replace {
            let certificate = try secrets.read(ClusterSecrets.caCertificate)
            let key = try secrets.read(ClusterSecrets.caKey)
            let sameCertificate = certificate.map {
                CertificateAuthority.fingerprint(ofPEM: String(decoding: $0, as: UTF8.self)) == backup.fingerprint
            }
            let sameKey = key.map { String(decoding: $0, as: UTF8.self) == backup.privateKeyPEM }
            guard sameCertificate != false, sameKey != false else {
                throw AuthorityStoreError.differentAuthority(backup: backup.fingerprint)
            }
        }
        try secrets.write(ClusterSecrets.caKey, Data(backup.privateKeyPEM.utf8))
        try secrets.write(ClusterSecrets.caCertificate, Data(backup.certificatePEM.utf8))
        return backup
    }

    /// The head is a node too. Its certificate is reissued at each start so that it
    /// always names the current addresses, while its key stays the same.
    private static func issueOwnIdentity(environment: TenderEnvironment, secrets: any SecretStore,
                                         authority: CertificateAuthority, options: HeadOptions) throws {
        let key: NodeKey
        if let existing = try secrets.read(ClusterSecrets.nodeKey) {
            key = NodeKey(privateKeyPEM: String(decoding: existing, as: UTF8.self))
        } else {
            key = .generate()
            try secrets.write(ClusterSecrets.nodeKey, Data(key.privateKeyPEM.utf8))
        }
        var names = options.advertisedNames
        if let host = options.apiHost { names.append(host) }
        names.append("127.0.0.1")
        let ips = names.filter { $0.first?.isNumber == true || $0.contains(":") }
        let dns = names.filter { !ips.contains($0) }
        let certificate = try authority.sign(csrPEM: try key.makeCSR(nodeID: options.nodeID), nodeID: options.nodeID,
                                             dnsNames: dns, ipAddresses: ips)
        try secrets.write(ClusterSecrets.nodeCertificate, Data(certificate.utf8))
        let host = options.advertisedNames.first ?? options.apiHost ?? "127.0.0.1"
        try ClusterIdentityStore(environment: environment, secrets: secrets).save(
            ClusterConfig(nodeID: options.nodeID, headNode: options.nodeID, headAgentAddress: "\(host):\(options.agentPort)"))
    }

    public var caFingerprint: String { authority.fingerprint }

    // MARK: Wiring into the agent

    public func hooks() -> ClusterHooks {
        ClusterHooks(
            resolver: RegistryResolver(state: state, defaultPort: options.agentPort),
            verifier: RevocationVerifier(store: store),
            systemReady: { [self] system in
                let registry = TenderActorSystem.$wellKnownName.withValue(ActorNames.registry) {
                    HeadRegistry(state: state, logs: logs, actorSystem: system)
                }
                holder.withLockedValue { $0 = (system, registry) }
            },
            installRoutes: { [self] router in installSocketRoutes(on: router) },
            services: { [self] in
                let cloud = CloudServices(environment: environment, secrets: secrets)
                var services: [any Service] = [
                    try makePublicAPI(),
                    LogRetentionService(logs: logs, logger: logger),
                    NightlyOffload(logs: logs, audit: audit, uploader: { try cloud.uploader() }),
                ]
                if let metrics = makeMetricsServer() { services.append(metrics) }
                return services
            }
        )
    }

    var system: TenderActorSystem? { holder.withLockedValue { $0.system } }

    private func agent(on node: NodeID) throws -> $NodeAgentProtocol<TenderActorSystem> {
        guard let system else {
            throw NodeCallError(code: "not_ready", message: "The cluster transport isn't up yet.", httpStatus: 503)
        }
        return try $NodeAgentProtocol.resolve(id: ActorIdentity(node: node, name: ActorNames.agent), using: system)
    }

    // MARK: Command routing

    /// Asks every node that's up, in parallel. A node that doesn't answer is listed,
    /// rather than failing the whole request.
    func clusterStatus() async -> ProcessList {
        let up = await state.upNodes()
        var combined = ProcessList(processes: [])
        combined.unreachableNodes = await state.downNodes().map(\.rawValue)
        await withTaskGroup(of: (NodeID, ProcessList?).self) { group in
            for node in Set(up + [options.nodeID]) {
                group.addTask { [self] in
                    (node, try? await agent(on: node).status())
                }
            }
            for await (node, list) in group {
                if let list {
                    combined.processes += list.processes
                    combined.orphans += list.orphans
                } else if !combined.unreachableNodes.contains(node.rawValue) {
                    combined.unreachableNodes.append(node.rawValue)
                }
            }
        }
        combined.processes.sort { ($0.service, $0.node.rawValue, $0.instance) < ($1.service, $1.node.rawValue, $1.instance) }
        combined.unreachableNodes.sort()
        return combined
    }

    /// Which nodes a by-name command means: the one asked for, or everywhere the service runs.
    func targets(service: String, node: String?) async -> [NodeID] {
        if let node { return [NodeID(node)] }
        let running = await state.nodes(running: service)
        return running.isEmpty ? [options.nodeID] : running
    }

    func command(_ build: (String) -> AgentCommand, service: String, node: String?) async throws -> ProcessList {
        for target in await targets(service: service, node: node) {
            _ = try await translatingTransport(target) { try await agent(on: target).apply(build(service)) }
        }
        return await clusterStatus()
    }

    func translatingTransport<T: Sendable>(_ node: NodeID, _ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as TransportError {
            throw NodeCallError(code: "node_unreachable", message: error.description, httpStatus: 503)
        }
    }

    func rollback(service: String, to sha12: String?, node: String?) async throws -> ProcessList {
        for target in await targets(service: service, node: node) {
            _ = try await translatingTransport(target) { try await agent(on: target).rollback(service: service, to: sha12) }
        }
        return await clusterStatus()
    }

    /// Each node fetches and verifies on its own, in parallel. One node failing doesn't
    /// stop the others, and the response says how each one went.
    func deploy(_ request: DeployRequest) async -> DeployResponse {
        let nodes = await targets(service: request.service, node: request.node)
        var outcomes: [DeployOutcome] = []
        await withTaskGroup(of: DeployOutcome.self) { group in
            for node in nodes {
                group.addTask { [self] in
                    do {
                        let sha12 = try await translatingTransport(node) {
                            try await agent(on: node).deploy(service: request.service, version: request.version)
                        }
                        return DeployOutcome(node: node, sha12: sha12)
                    } catch {
                        return DeployOutcome(node: node, error: "\(error)")
                    }
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
                deploys.add(service: request.service, result: outcome.error == nil ? "success" : "failure")
            }
        }
        return DeployResponse(outcomes: outcomes.sorted { $0.node.rawValue < $1.node.rawValue })
    }

    func clusterReleases(service: String) async -> ClusterReleases {
        let up = await state.upNodes()
        var nodes: [NodeReleases] = []
        await withTaskGroup(of: NodeReleases?.self) { group in
            for node in Set(up + [options.nodeID]) {
                group.addTask { [self] in
                    guard let releases = try? await agent(on: node).releases(service: service) else { return nil }
                    return NodeReleases(node: node, releases: releases)
                }
            }
            for await item in group {
                if let item, !item.releases.releases.isEmpty { nodes.append(item) }
            }
        }
        return ClusterReleases(service: service, nodes: nodes.sorted { $0.node.rawValue < $1.node.rawValue })
    }

    /// Plain HTTP with no auth, like most Prometheus targets. It binds only to the tailnet
    /// address, and Tailscale ACLs decide who reaches it. It carries no log lines or secrets.
    func makeMetricsServer() -> (any Service)? {
        guard let port = options.metricsPort else { return nil }
        let router = Router()
        router.get("/metrics") { [self] _, _ in
            Response(status: .ok, headers: [.contentType: "text/plain; version=0.0.4"],
                     body: ResponseBody(byteBuffer: ByteBuffer(string: await metricsText())))
        }
        return Application(router: router,
                           configuration: .init(address: .hostname(options.apiHost ?? "127.0.0.1", port: port), serverName: nil),
                           logger: logger)
    }

    func metricsText() async -> String {
        MetricsRenderer.render(MetricsSnapshot(
            nodes: await state.summaries(),
            processes: await state.allProcesses(),
            linesIngested: await logs.ingestedLines(),
            deploys: deploys.snapshot))
    }

    // MARK: Tokens

    func createJoinToken(ttl: TimeInterval) throws -> JoinTokenResponse {
        let secret = JoinToken.randomSecret()
        let expiry = Date().addingTimeInterval(ttl)
        try store.addJoinToken(secret: secret, expiresAt: expiry)
        return JoinTokenResponse(token: JoinToken(secret: secret, caFingerprint: authority.fingerprint).text, expiresAt: expiry)
    }

    func handleJoin(_ request: JoinRequest) async throws -> JoinResponse {
        guard let token = JoinToken(parsing: request.token), token.caFingerprint == authority.fingerprint else {
            throw NodeCallError(code: "invalid_token", message: "Invalid join token.", httpStatus: 401)
        }
        guard CertificateAuthority.isValidNodeID(request.nodeID.rawValue) else {
            throw NodeCallError(code: "invalid_node", message: "'\(request.nodeID)' isn't a valid node ID.", httpStatus: 400)
        }
        // A certificate's SAN is its node ID, so a joiner must not be able to pick a name
        // the head answers to, or take over a node that already exists.
        guard request.nodeID != options.nodeID,
              !options.advertisedNames.contains(request.nodeID.rawValue),
              options.apiHost != request.nodeID.rawValue,
              request.nodeID.rawValue != "127.0.0.1", request.nodeID.rawValue.lowercased() != "localhost" else {
            throw NodeCallError(code: "invalid_node", message: "'\(request.nodeID)' is a name of the head.", httpStatus: 409)
        }
        guard await state.address(of: request.nodeID) == nil else {
            throw NodeCallError(code: "node_exists",
                                message: "Node '\(request.nodeID)' already exists. Run `tender node revoke \(request.nodeID)` first if it's being replaced.",
                                httpStatus: 409)
        }
        // Validate the CSR before spending the token, so that a typo doesn't burn it.
        let certificate: String
        do {
            certificate = try authority.sign(csrPEM: request.csrPEM, nodeID: request.nodeID)
        } catch {
            throw NodeCallError(code: "invalid_csr", message: "\(error)", httpStatus: 400)
        }
        guard try store.consumeJoinToken(secret: token.secret) else {
            throw NodeCallError(code: "invalid_token", message: "That join token is expired or already used.", httpStatus: 401)
        }
        try store.clearRevocation(node: request.nodeID)
        let host = options.advertisedNames.first ?? options.apiHost ?? "127.0.0.1"
        logger.info("node joined", metadata: ["node": "\(request.nodeID)"])
        return JoinResponse(certificatePEM: certificate, caPEM: authority.certificatePEM, headNode: options.nodeID,
                            headAgentAddress: "\(host):\(options.agentPort)")
    }

    func revoke(node: NodeID) async throws {
        guard node != options.nodeID else {
            throw NodeCallError(code: "invalid_node", message: "The head can't revoke itself.", httpStatus: 409)
        }
        try store.revoke(node: node)
        await state.remove(node)
        system?.disconnect(node)
    }

    func createAPIToken(_ request: APITokenCreateRequest) throws -> APITokenCreated {
        guard !request.name.isEmpty else {
            throw NodeCallError(code: "invalid_name", message: "A token needs a name.", httpStatus: 400)
        }
        let secret = JoinToken.randomSecret()
        guard let info = try store.addAPIToken(secret: secret, name: request.name, scope: request.scope) else {
            throw NodeCallError(code: "name_taken", message: "A token named '\(request.name)' exists.", httpStatus: 409)
        }
        // The fingerprint travels with the token so that a client can pin the CA from it.
        return APITokenCreated(info: info, token: JoinToken(secret: secret, caFingerprint: authority.fingerprint).text)
    }

    // MARK: Routes

    /// Shared by the Unix socket and the public listener.
    private func installClusterRoutes(on router: Router<BasicRequestContext>) {
        router.get("/v1/logs") { [self] request, _ in
            await respond { try await logs.search(try logQuery(from: request)) }
        }
        router.get("/v1/logs/follow") { [self] request, _ in
            let query: LogQuery
            do {
                query = try logQuery(from: request)
            } catch let error as NodeCallError {
                return errorResponse(error)
            } catch {
                return errorResponse(NodeCallError(code: "internal", message: "\(error)"))
            }
            return await followResponse(query: query)
        }
        router.post("/v1/deploy") { [self] request, _ in
            await respond {
                let deploy = try await decode(DeployRequest.self, from: request)
                return await self.deploy(deploy)
            }
        }
        router.get("/v1/releases") { [self] request, _ in
            await respond {
                guard let service = request.uri.queryParameters.get("service") else {
                    throw NodeCallError(code: "invalid_query", message: "service is required.", httpStatus: 400)
                }
                return await clusterReleases(service: service)
            }
        }
        router.get("/v1/nodes") { [self] _, _ in
            await respond { NodeList(nodes: await state.summaries()) }
        }
        router.get("/v1/processes") { [self] _, _ in
            await respond { await clusterStatus() }
        }
        router.post("/v1/processes") { [self] request, _ in
            await respond {
                let spec = try await decode(ServiceSpec.self, from: request)
                let target = spec.node ?? options.nodeID
                _ = try await translatingTransport(target) { try await agent(on: target).apply(.start(spec)) }
                return await clusterStatus()
            }
        }
        router.post("/v1/processes/:name/:action") { [self] request, context in
            await respond {
                let name = try context.parameters.require("name")
                let node = request.uri.queryParameters.get("node")
                switch try context.parameters.require("action") {
                case "start": return try await command({ .startExisting(service: $0) }, service: name, node: node)
                case "stop": return try await command({ .stop(service: $0) }, service: name, node: node)
                case "restart": return try await command({ .restart(service: $0) }, service: name, node: node)
                case let action:
                    throw NodeCallError(code: "unknown_action", message: "Unknown action '\(action)'.", httpStatus: 404)
                }
            }
        }
        router.delete("/v1/processes/:name") { [self] request, context in
            await respond {
                try await command({ .delete(service: $0) }, service: try context.parameters.require("name"),
                                  node: request.uri.queryParameters.get("node"))
            }
        }
        router.get("/v1/releases/:service") { [self] request, context in
            await respond {
                let target = request.uri.queryParameters.get("node").map { NodeID($0) } ?? options.nodeID
                let service = try context.parameters.require("service")
                return try await translatingTransport(target) { try await agent(on: target).releases(service: service) }
            }
        }
        router.post("/v1/releases/:service/rollback") { [self] request, context in
            await respond {
                let service = try context.parameters.require("service")
                let rollback = try await decodeOptional(RollbackRequest.self, from: request) ?? RollbackRequest()
                return try await self.rollback(service: service, to: rollback.to, node: request.uri.queryParameters.get("node"))
            }
        }
        router.delete("/v1/adopt/:label") { [self] request, context in
            await respond {
                let label = try context.parameters.require("label")
                let target = request.uri.queryParameters.get("node").map { NodeID($0) } ?? options.nodeID
                _ = try await translatingTransport(target) { try await agent(on: target).forgetAdopted(label: label) }
                return await clusterStatus()
            }
        }
        router.post("/v1/gc") { [self] request, _ in
            await respond {
                let target = request.uri.queryParameters.get("node").map { NodeID($0) } ?? options.nodeID
                _ = try await translatingTransport(target) { try await agent(on: target).apply(.collectGarbage) }
                return await clusterStatus()
            }
        }
    }

    private func logQuery(from request: Request) throws -> LogQuery {
        let parameters = request.uri.queryParameters
        func date(_ name: Substring) throws -> Date? {
            guard let raw = parameters.get(String(name)) else { return nil }
            guard let seconds = Double(raw) else {
                throw NodeCallError(code: "invalid_query", message: "\(name) must be Unix seconds.", httpStatus: 400)
            }
            return Date(timeIntervalSince1970: seconds)
        }
        var stream: LogLine.Stream?
        if let raw = parameters.get("stream") {
            guard let parsed = LogLine.Stream(rawValue: raw) else {
                throw NodeCallError(code: "invalid_query", message: "stream must be out or err.", httpStatus: 400)
            }
            stream = parsed
        }
        return LogQuery(service: parameters.get("service"), node: parameters.get("node"), stream: stream,
                        since: try date("since"), until: try date("until"), text: parameters.get("query"),
                        limit: parameters.get("limit").flatMap { Int($0) } ?? 200)
    }

    /// Server-Sent Events: one JSON `LogEntry` per event, plus a comment as a heartbeat
    /// so that a closed connection is noticed even when no lines arrive.
    private func followResponse(query: LogQuery) async -> Response {
        let stream = await logs.subscribe(query)
        return Response(
            status: .ok,
            headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
            body: ResponseBody { writer in
                let encoder = JSONEncoder()
                // Lines and heartbeats merge into one sequence, because an AsyncStream
                // iterator can't be raced against a timer without losing lines.
                let (events, continuation) = AsyncStream.makeStream(of: LogEntry?.self)
                let forward = Task {
                    for await entry in stream { continuation.yield(entry) }
                    continuation.finish()
                }
                let beat = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(5))
                        continuation.yield(nil)
                    }
                }
                defer {
                    forward.cancel()
                    beat.cancel()
                }
                for await event in events {
                    if Task.isCancelled || Task.isShuttingDownGracefully { break }
                    if let event {
                        try await writer.write(ByteBuffer(bytes: Data("data: ".utf8) + (try encoder.encode(event)) + Data("\n\n".utf8)))
                    } else {
                        try await writer.write(ByteBuffer(string: ": keep-alive\n\n"))
                    }
                }
                try await writer.finish(nil)
            }
        )
    }

    /// Administration stays on the socket: file permissions are its authentication.
    func installSocketRoutes(on router: Router<BasicRequestContext>) {
        router.add(middleware: AuditMiddleware(audit: audit, who: { _ in "local-socket" }))
        installClusterRoutes(on: router)
        // Socket only: `--log-path` makes the daemon, which runs as root, read a file of the
        // caller's choosing, so a remote token could use it to read any file on any node.
        router.post("/v1/adopt") { [self] request, _ in
            await respond {
                let adopt = try await decode(AdoptRequest.self, from: request)
                let target = request.uri.queryParameters.get("node").map { NodeID($0) } ?? options.nodeID
                _ = try await translatingTransport(target) { try await agent(on: target).adopt(adopt) }
                return await clusterStatus()
            }
        }
        router.post("/v1/tokens") { [self] request, _ in
            await respond {
                let body = try await decodeOptional(JoinTokenRequest.self, from: request)
                let ttl = TimeInterval(body?.ttlSeconds ?? 15 * 60)
                guard ttl > 0, ttl <= 86400 else {
                    throw NodeCallError(code: "invalid_ttl", message: "ttl must be between 1 second and 1 day.", httpStatus: 400)
                }
                return try createJoinToken(ttl: ttl)
            }
        }
        router.post("/v1/nodes/:id/revoke") { [self] _, context in
            await respond {
                try await revoke(node: NodeID(try context.parameters.require("id")))
                return NodeList(nodes: await state.summaries())
            }
        }
        router.get("/v1/ca/export") { [self] _, _ in
            await respond {
                CertificateExport(certificatePEM: authority.certificatePEM, privateKeyPEM: authority.privateKeyPEM)
            }
        }
        router.post("/v1/api-tokens") { [self] request, _ in
            await respond { try createAPIToken(try await decode(APITokenCreateRequest.self, from: request)) }
        }
        router.get("/v1/api-tokens") { [self] _, _ in
            await respond { APITokenList(tokens: try store.apiTokens()) }
        }
        router.delete("/v1/api-tokens/:name") { [self] _, context in
            await respond {
                try store.removeAPIToken(name: try context.parameters.require("name"))
                return APITokenList(tokens: try store.apiTokens())
            }
        }
    }

    /// The router for the public listener. `/v1/ca` and `/v1/join` need no token: a
    /// joining node has none, and its join token is checked in the handler.
    func makePublicRouter() -> Router<BasicRequestContext> {
        let router = Router()
        let store = self.store
        router.add(middleware: AuditMiddleware(audit: audit, who: { request in
            guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
                  let secret = header.dropFirst(7).split(separator: ".").first,
                  let token = try? store.apiToken(secret: String(secret)) else { return "unauthenticated" }
            return token.name
        }))
        router.add(middleware: BearerAuthMiddleware(store: store))
        let authority = self.authority
        router.get("/v1/ca") { _, _ in
            Response(status: .ok, headers: [.contentType: "application/x-pem-file"],
                     body: ResponseBody(byteBuffer: ByteBuffer(string: authority.certificatePEM)))
        }
        router.post("/v1/join") { [self] request, _ in
            await respond { try await handleJoin(try await decode(JoinRequest.self, from: request)) }
        }
        installClusterRoutes(on: router)
        installMCPRoute(on: router)
        return router
    }

    func makePublicAPI() throws -> any Service {
        guard let certificate = try secrets.read(ClusterSecrets.nodeCertificate),
              let key = try secrets.read(ClusterSecrets.nodeKey) else {
            throw NodeCallError(code: "not_ready", message: "The head has no certificate.")
        }
        let host = options.apiHost ?? "127.0.0.1"
        let tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(certificate)).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key), format: .pem))
        )
        return Application(
            router: makePublicRouter(),
            server: try .tls(.http1(), tlsConfiguration: tls),
            configuration: .init(address: .hostname(host, port: options.apiPort), serverName: nil),
            logger: logger
        )
    }
}

/// `Authorization: Bearer <token>`. `GET` needs read scope, everything else write.
struct BearerAuthMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    static let publicPaths: Set<String> = ["/v1/ca", "/v1/join"]
    let store: HeadStore

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        if Self.publicPaths.contains(request.uri.path) { return try await next(request, context) }
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else {
            return errorResponse(NodeCallError(code: "unauthorized", message: "A bearer token is required.", httpStatus: 401))
        }
        // Clients may present the full `<secret>.<fingerprint>`; only the secret is stored.
        let presented = header.dropFirst("Bearer ".count).split(separator: ".").first.map(String.init) ?? ""
        guard let token = try? store.apiToken(secret: presented) else {
            return errorResponse(NodeCallError(code: "unauthorized", message: "Unknown token.", httpStatus: 401))
        }
        // MCP is always POST; its tools check the scope one by one.
        if request.method != .get, token.scope != .write, request.uri.path != TenderMCPRoute.path {
            return errorResponse(NodeCallError(code: "forbidden", message: "This token is read-only.", httpStatus: 403))
        }
        return try await next(request, context)
    }
}

func decode<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
    var request = request
    let body = try await request.collectBody(upTo: 1 << 20)
    do {
        return try JSONDecoder().decode(type, from: Data(body.readableBytesView))
    } catch {
        throw NodeCallError(code: "invalid_body", message: "Expected a \(type): \(error)", httpStatus: 400)
    }
}

func decodeOptional<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T? {
    var request = request
    let body = try await request.collectBody(upTo: 1 << 20)
    guard body.readableBytes > 0 else { return nil }
    do {
        return try JSONDecoder().decode(type, from: Data(body.readableBytesView))
    } catch {
        throw NodeCallError(code: "invalid_body", message: "Expected a \(type): \(error)", httpStatus: 400)
    }
}

func errorResponse(_ error: NodeCallError) -> Response {
    let data = (try? JSONEncoder().encode(APIErrorBody(code: error.code, message: error.message))) ?? Data()
    return Response(status: HTTPResponse.Status(code: error.httpStatus),
                    headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}

func respond(_ operation: () async throws -> some Encodable) async -> Response {
    do {
        let data = try JSONEncoder().encode(try await operation())
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    } catch let error as NodeCallError {
        return errorResponse(error)
    } catch {
        return errorResponse(NodeCallError(code: "internal", message: "\(error)"))
    }
}

/// Applies the head's log retention every 5 minutes.
struct LogRetentionService: Service {
    let logs: LogStore
    let logger: Logger

    func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do {
                    let removed = try await logs.enforceRetention()
                    if !removed.isEmpty { logger.info("log retention removed days", metadata: ["days": "\(removed)"]) }
                } catch {
                    logger.error("log retention failed", metadata: ["error": "\(error)"])
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}
