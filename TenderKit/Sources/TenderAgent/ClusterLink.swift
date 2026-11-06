import Distributed
import Foundation
import Logging
import LogTail
import ProcessMetrics
import ServiceLifecycle
import TenderActorSystem
import TenderCore
import TenderPKI
import TenderProtocol

/// What a node needs to take part in the cluster. Key material is in the secret store.
public struct ClusterConfig: Codable, Sendable, Equatable {
    public var nodeID: NodeID
    public var headNode: NodeID
    /// `host:port` of the head's agent listener.
    public var headAgentAddress: String

    public init(nodeID: NodeID, headNode: NodeID, headAgentAddress: String) {
        self.nodeID = nodeID
        self.headNode = headNode
        self.headAgentAddress = headAgentAddress
    }
}

public enum ClusterSecrets {
    public static let nodeKey = "node.key"
    public static let nodeCertificate = "node.crt"
    public static let caCertificate = "ca.crt"
    public static let caKey = "ca.key"
    public static let all = [nodeKey, nodeCertificate, caCertificate, caKey]
}

public struct ClusterOptions: Sendable {
    public var listenHost: String?
    public var advertiseHost: String?
    public var agentPort: Int
    public var identityMode: IdentityMode
    public var requiredTags: [String]
    public var heartbeatInterval: Duration
    /// Adds IOReport power readings (CPU, GPU, Neural Engine, DRAM) to heartbeats. Private API.
    public var experimentalPower: Bool
    /// Finds the address to listen on and notices when it changes. Share one with the head.
    public var network: NetworkMonitor
    /// How long to wait for a Tailscale address at start before exiting, so launchd restarts
    /// the daemon. Nil waits forever.
    public var addressTimeout: Duration?

    public init(listenHost: String? = nil, advertiseHost: String? = nil, agentPort: Int = 7070,
                identityMode: IdentityMode = .enforce, requiredTags: [String] = [],
                heartbeatInterval: Duration = .seconds(5), experimentalPower: Bool = false,
                network: NetworkMonitor? = nil, addressTimeout: Duration? = .seconds(300)) {
        self.network = network ?? NetworkMonitor(explicitHost: listenHost)
        self.addressTimeout = addressTimeout
        self.experimentalPower = experimentalPower
        self.listenHost = listenHost
        self.advertiseHost = advertiseHost
        self.agentPort = agentPort
        self.identityMode = identityMode
        self.requiredTags = requiredTags
        self.heartbeatInterval = heartbeatInterval
    }
}

/// Reads and writes a node's cluster identity.
public struct ClusterIdentityStore: Sendable {
    public let environment: TenderEnvironment
    public let secrets: any SecretStore

    public init(environment: TenderEnvironment, secrets: any SecretStore) {
        self.environment = environment
        self.secrets = secrets
    }

    private var configURL: URL { environment.configDirectory.appending(path: "node.json") }

    public func config() throws -> ClusterConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try JSONDecoder().decode(ClusterConfig.self, from: data)
    }

    public func save(_ config: ClusterConfig) throws {
        try FileManager.default.createDirectory(at: environment.configDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
    }

    public func forget() throws {
        try? FileManager.default.removeItem(at: configURL)
        for name in [ClusterSecrets.nodeKey, ClusterSecrets.nodeCertificate, ClusterSecrets.caCertificate] {
            try secrets.delete(name)
        }
    }

    /// The node's mTLS material, once it has joined.
    public func tls() throws -> TransportTLS? {
        guard let certificate = try secrets.read(ClusterSecrets.nodeCertificate),
              let key = try secrets.read(ClusterSecrets.nodeKey),
              let authority = try secrets.read(ClusterSecrets.caCertificate) else { return nil }
        return TransportTLS(certificatePEM: String(decoding: certificate, as: UTF8.self),
                            privateKeyPEM: String(decoding: key, as: UTF8.self),
                            trustRootPEM: String(decoding: authority, as: UTF8.self))
    }
}

/// Combines the Tailscale check with anything else the node wants to refuse.
public struct NodePeerVerifier: PeerVerifier {
    private let identity: TailscaleIdentityCheck
    private let additional: (any PeerVerifier)?

    public init(identity: TailscaleIdentityCheck, additional: (any PeerVerifier)? = nil) {
        self.identity = identity
        self.additional = additional
    }

    public func verify(certificateNode: NodeID, remoteIP: String?) async throws {
        try await additional?.verify(certificateNode: certificateNode, remoteIP: remoteIP)
        try await identity.verify(certificateNode: certificateNode, remoteIP: remoteIP ?? "")
    }
}

public func splitHostPort(_ address: String, defaultPort: Int) -> (host: String, port: Int) {
    if let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) {
        return (String(address[..<colon]), port)
    }
    return (address, defaultPort)
}

/// Once the node has an identity: listens for peers, serves `NodeAgent`, and sends the
/// head a heartbeat. Everything keeps running if the head is away; this just retries.
struct ClusterLink: Service {
    let identities: ClusterIdentityStore
    let options: ClusterOptions
    let controller: ProcessController
    let hooks: ClusterHooks?
    let logger: Logger

    func run() async throws {
        let monitor = options.network
        try await cancelWhenGracefulShutdown {
            var openSpool: LogSpool?
            var timeout = options.addressTimeout
            while !Task.isCancelled {
                guard (try? identities.tls()) != nil, let config = try? identities.config() else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                // Nothing binds until there's a real address: falling back to loopback would
                // leave the node unreachable with no sign of it. Past the first address, a lost
                // one is waited for without giving up: the listeners rebind when it returns.
                guard let host = try await monitor.waitForHost(timeout: timeout, logger: logger) else { return }
                timeout = nil
                await hooks?.addressReady(host)
                do {
                    guard let tls = try identities.tls() else {
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    let (system, _) = try await start(config: config, tls: tls, host: host)
                    let spool = try openSpool ?? LogSpool(directory: identities.environment.spoolDirectory)
                    openSpool = spool
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await heartbeats(config: config, system: system, spool: spool) }
                        group.addTask { await tailLogs(spool: spool) }
                        group.addTask { await shipLogs(config: config, system: system, spool: spool) }
                        // The workers only end when cancelled, so this finishing first means
                        // the address changed (or we're shutting down).
                        group.addTask { _ = await monitor.waitForChange(from: host) }
                        _ = await group.next()
                        group.cancelAll()
                        await group.waitForAll()
                    }
                    await system.shutdown()
                    if !Task.isCancelled { logger.notice("tailnet address changed, rebinding listeners", metadata: ["was": "\(host)"]) }
                } catch {
                    logger.error("cluster link failed to start", metadata: ["error": "\(error)"])
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func start(config: ClusterConfig, tls: TransportTLS, host listen: String) async throws -> (TenderActorSystem, NodeAgent) {
        let (host, port) = splitHostPort(config.headAgentAddress, defaultPort: options.agentPort)
        let logger = self.logger
        let check = TailscaleIdentityCheck(mode: options.identityMode, requiredTags: options.requiredTags,
                                           pins: PeerPins.standard(identities.environment)) { message in
            logger.warning("\(message)")
        }
        let system = TenderActorSystem(
            localNode: config.nodeID,
            tls: tls,
            resolver: hooks?.resolver ?? StaticNodeResolver([config.headNode: NodeAddress(host: host, port: port)]),
            verifier: NodePeerVerifier(identity: check, additional: hooks?.verifier)
        )
        let agent = TenderActorSystem.$wellKnownName.withValue(ActorNames.agent) {
            NodeAgent(controller: controller, headNode: config.headNode, actorSystem: system)
        }
        hooks?.systemReady(system)
        let bound = try await system.listen(host: listen, port: options.agentPort)
        logger.info("cluster transport listening", metadata: ["node": "\(config.nodeID)", "address": "\(listen):\(bound)"])
        return (system, agent)
    }

    private func nodeInfo(config: ClusterConfig) async -> NodeInfo {
        let process = ProcessInfo.processInfo
        var hardware = [CChar](repeating: 0, count: 64)
        var size = hardware.count
        sysctlbyname("hw.model", &hardware, &size, nil, 0)
        let advertised = await advertisedHost()
        return NodeInfo(
            id: config.nodeID,
            version: TenderVersion.current,
            macOS: process.operatingSystemVersionString,
            hardware: String(decoding: hardware.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            address: advertised.map { "\($0):\(options.agentPort)" },
            labels: config.nodeID == config.headNode ? [NodeInfo.roleLabel: NodeInfo.headRole] : [:],
            network: options.network.state,
            hostname: NodeIdentity.hostname()
        )
    }

    private func advertisedHost() async -> String? {
        if let host = options.advertiseHost { return host }
        return await options.network.resolve()
    }

    /// Copies new lines from log files into the spool, with their offsets in one transaction.
    private func tailLogs(spool: LogSpool) async {
        var followers: [URL: LogFollower] = [:]
        var lastLimitCheck = ContinuousClock.now
        while !Task.isCancelled {
            do {
                var pending: [LogSpool.Pending] = []
                let sources = try controller.allLogSources()
                for source in sources {
                    var follower = try followers[source.url] ?? LogFollower(url: source.url, resumingFrom: spool.position(of: source.url))
                    let lines = (try? follower.poll()) ?? []
                    followers[source.url] = follower
                    if !lines.isEmpty {
                        pending.append(LogSpool.Pending(service: source.service, instance: source.instance, stream: source.stream,
                                                        lines: lines, file: source.url, position: follower.position))
                    }
                }
                if !pending.isEmpty { try spool.append(pending) }
                let current = Set(sources.map(\.url))
                followers = followers.filter { current.contains($0.key) }
                if ContinuousClock.now - lastLimitCheck > .seconds(30) {
                    lastLimitCheck = .now
                    let dropped = try spool.enforceLimits()
                    if dropped > 0 { logger.warning("log spool over its limits", metadata: ["dropped": "\(dropped)"]) }
                }
            } catch {
                logger.error("log tailing failed", metadata: ["error": "\(error)"])
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Sends one batch at a time. A batch goes out as soon as there are lines; when there
    /// are none or the head is away, it waits.
    private func shipLogs(config: ClusterConfig, system: TenderActorSystem, spool: LogSpool) async {
        while !Task.isCancelled {
            var delay: Duration = .milliseconds(250)
            do {
                let batch = try spool.nextBatch(node: config.nodeID)
                if !batch.records.isEmpty || !batch.gaps.isEmpty {
                    let registry = try $HeadRegistryProtocol.resolve(
                        id: ActorIdentity(node: config.headNode, name: ActorNames.registry), using: system)
                    let acked = try await registry.ingest(batch)
                    if let last = batch.records.last?.seq ?? batch.gaps.last?.throughSeq, acked < last, acked < batch.previousSeq {
                        try spool.rewind(to: acked)
                    } else {
                        try spool.acknowledge(through: acked)
                    }
                    // No progress: the head refused, so back off instead of spinning.
                    if !batch.records.isEmpty, acked >= (batch.records.last?.seq ?? 0) {
                        delay = .zero
                    } else if !batch.records.isEmpty {
                        delay = .seconds(5)
                    }
                }
            } catch {
                delay = .seconds(2)
                logger.debug("log shipping failed", metadata: ["error": "\(error)"])
            }
            try? await Task.sleep(for: delay)
        }
    }

    private func heartbeats(config: ClusterConfig, system: TenderActorSystem, spool: LogSpool) async {
        var registered = false
        var roundTrip: TimeInterval?
        var info = await nodeInfo(config: config)
        let machine = SystemSampler(experimentalPower: options.experimentalPower)
        while !Task.isCancelled {
            do {
                let registry = try $HeadRegistryProtocol.resolve(
                    id: ActorIdentity(node: config.headNode, name: ActorNames.registry), using: system)
                // The head learns of a change in the node's network (waiting, loopback, listening).
                if info.network != options.network.state || info.hostname != NodeIdentity.hostname() {
                    info = await nodeInfo(config: config)
                    registered = false
                }
                if !registered {
                    try await registry.register(info)
                    registered = true
                    logger.info("registered with head", metadata: ["head": "\(config.headNode)"])
                }
                let list = try await controller.list()
                let stats = await machine.sample()
                let start = ContinuousClock.now
                try await registry.heartbeat(Heartbeat(
                    node: config.nodeID, nodeClock: Date(), processes: list.processes, orphans: list.orphans,
                    previousRoundTrip: roundTrip, spoolBacklog: (try? spool.backlog()) ?? 0,
                    spoolDropped: (try? spool.droppedTotal()) ?? 0,
                    secretFetchErrors: await controller.gcp?.fetchErrors ?? 0, stats: stats))
                let elapsed = (ContinuousClock.now - start).components
                roundTrip = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            } catch {
                // The head restarted, or is away. Re-registering on reconnect rebuilds its registry.
                registered = false
                logger.debug("heartbeat failed", metadata: ["error": "\(error)"])
            }
            try? await Task.sleep(for: options.heartbeatInterval)
        }
    }
}
