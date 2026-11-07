import Crypto
import Foundation
import LaunchdKit
import Synchronization
import Testing
import TenderActorSystem
import TenderAgent
import TenderClient
import TenderCore
import TenderLogStore
import TenderPKI
import TenderProtocol
@testable import TenderHead

actor MemoryLaunchd: LaunchdControlling {
    var loaded: Set<String> = []
    /// Every start, so that tests can tell an untouched job from a restarted one.
    var bootstraps = 0
    func bootstrap(plistURL: URL) async throws {
        bootstraps += 1
        loaded.insert(plistURL.deletingPathExtension().lastPathComponent)
    }
    func bootout(label: String) async throws {
        guard loaded.remove(label) != nil else { throw LaunchctlError.notFound(label) }
    }
    func kickstart(label: String, kill: Bool) async throws {}
    func enable(label: String) async throws {}
    func disable(label: String) async throws {}
    func print(label: String) async throws -> JobInfo? {
        loaded.contains(label) ? JobInfo(output: "x/\(label) = {\n\tstate = running\n\tpid = 42\n\truns = 1\n}\n") : nil
    }
    func listLabels(prefix: String) async throws -> [String] { loaded.filter { $0.hasPrefix(prefix) }.sorted() }
}

func makeEnvironment() throws -> TenderEnvironment {
    let root = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return TenderEnvironment(mode: .development, root: root, logsDirectory: root.appending(path: "logs"),
                             plistDirectory: root.appending(path: "agents"),
                             serviceLabelPrefix: "com.olympsis.tender.test.svc.\(UUID().uuidString.prefix(8))")
}

/// Asks the kernel for a free port by binding port 0.
func freePort() -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    return Int(UInt16(bigEndian: address.sin_port))
}

func eventually<T>(timeout: Duration = .seconds(15), _ check: () async throws -> T?) async throws -> T? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = try? await check() { return value }
        try await Task.sleep(for: .milliseconds(50))
    }
    return nil
}

/// A daemon in this process: real sockets, real mTLS, in-memory launchd.
final class Daemon: @unchecked Sendable {
    let env: TenderEnvironment
    let agentPort: Int
    let apiPort: Int
    let launchd = MemoryLaunchd()
    private var task: Task<Void, Error>?
    let isHead: Bool
    let nodeName: String

    let metricsPort = freePort()
    let source: (any ReleaseSource)?

    /// With this, the daemon has no `--listen` and finds its address from the monitor, like
    /// a daemon that starts before Tailscale does.
    let network: NetworkMonitor?

    init(node: String, head: Bool, env: TenderEnvironment? = nil, agentPort: Int? = nil, apiPort: Int? = nil,
         source: (any ReleaseSource)? = nil, network: NetworkMonitor? = nil) throws {
        self.network = network
        self.source = source
        self.env = try env ?? makeEnvironment()
        self.agentPort = agentPort ?? freePort()
        self.apiPort = apiPort ?? freePort()
        isHead = head
        nodeName = node
    }

    func start() async throws {
        let secrets = env.makeSecretStore()
        let cluster = ClusterOptions(listenHost: network == nil ? "127.0.0.1" : nil, advertiseHost: "127.0.0.1", agentPort: agentPort,
                                     identityMode: .off, heartbeatInterval: .milliseconds(100), network: network, addressTimeout: nil)
        var hooks: ClusterHooks?
        if isHead {
            let options = HeadOptions(nodeID: NodeID(nodeName), apiHost: network == nil ? "127.0.0.1" : nil, apiPort: apiPort,
                                      agentPort: agentPort, advertisedNames: ["127.0.0.1"], metricsPort: metricsPort)
            hooks = try HeadServices(environment: env, secrets: secrets, options: options, network: network).hooks()
        }
        let runtime = AgentRuntime(environment: env, secrets: secrets, cluster: cluster, hooks: hooks, launchd: launchd, releaseSource: source, shutdownSignals: [])
        task = Task { try await runtime.run() }
        let socket = env.socketPath.path(percentEncoded: false)
        _ = try await eventually { FileManager.default.fileExists(atPath: socket) ? true : nil }
    }

    func stop() async {
        task?.cancel()
        _ = try? await task?.value
        task = nil
    }

    var client: TenderClient { TenderClient(socketPath: env.socketPath.path(percentEncoded: false)) }
    func cleanup() { try? FileManager.default.removeItem(at: env.root) }
}

private let sleeper = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1000"])

/// Starts a head and a joined worker.
func withCluster(_ body: (Daemon, Daemon) async throws -> Void) async throws {
    let head = try Daemon(node: "head", head: true)
    let worker = try Daemon(node: "worker", head: false)
    try await head.start()
    try await worker.start()
    defer { head.cleanup(); worker.cleanup() }
    let token = try #require(try await eventually { try await head.client.createJoinToken() })
    _ = try await worker.client.join(head: "127.0.0.1:\(head.apiPort)", token: token.token, nodeID: "worker")
    let joined = try await eventually { () -> Bool? in
        let nodes = try await head.client.nodes().nodes
        return nodes.count == 2 && nodes.allSatisfy(\.up) ? true : nil
    }
    #expect(joined == true)
    try await body(head, worker)
    await worker.stop()
    await head.stop()
}

@Test func headWaitsForTailscaleThenListensAndRebindsWhenTheAddressChanges() async throws {
    let address = Mutex<String?>(nil)
    let network = NetworkMonitor(pollInterval: .milliseconds(50)) { address.withLock { $0 } }
    let head = try Daemon(node: "head", head: true, network: network)
    try await head.start()
    defer { head.cleanup() }

    // No address yet: the socket works, and says why nothing else does.
    #expect(try await head.client.network().kind == .waitingForTailscale)
    do {
        _ = try await head.client.start(sleeper)
        Issue.record("a head with no address can't run commands through its transport")
    } catch let error as TenderClientError {
        #expect(error.code == "not_ready")
        #expect(error.description.contains("waiting for Tailscale"))
    }
    #expect(try await head.client.nodes().nodes.isEmpty)

    // Tailscale comes up.
    address.withLock { $0 = "127.0.0.1" }
    let up = try await eventually { () -> Bool? in
        let nodes = try await head.client.nodes().nodes
        return nodes.count == 1 && nodes[0].up && nodes[0].info.network?.kind == .loopbackOnly ? true : nil
    }
    #expect(up == true)
    #expect(try await head.client.network() == NetworkState(kind: .loopbackOnly, address: "127.0.0.1"))
    #expect(try await head.client.start(sleeper).processes.first?.state == .running)

    // The address changes: the listeners rebind and the node registers again.
    address.withLock { $0 = "localhost" }
    let moved = try await eventually { () -> Bool? in
        let nodes = try await head.client.nodes().nodes
        return try await head.client.network().address == "localhost" && nodes.count == 1 && nodes[0].up ? true : nil
    }
    #expect(moved == true)
    #expect(try await head.client.list().processes.count == 1)
    await head.stop()
}

@Test func workerJoinsAndCommandsReachIt() async throws {
    try await withCluster { head, worker async throws in
        var spec = sleeper
        spec.node = NodeID("worker")
        let list = try await head.client.start(spec)
        let process = try #require(list.processes.first)
        #expect(process.node == NodeID("worker"))
        #expect(process.state == .running)
        #expect(await worker.launchd.loaded.count == 1)
        #expect(await head.launchd.loaded.isEmpty)

        // Without --node, by-name commands find where the service runs.
        let found = try await eventually { () -> Bool? in
            try await head.client.nodes().nodes.first { $0.info.id == NodeID("worker") }?.instanceCount == 1 ? true : nil
        }
        #expect(found == true)
        #expect(try await head.client.stop(service: "api").processes.first?.state == .stopped)
        #expect(await worker.launchd.loaded.isEmpty)
        #expect(try await head.client.start(service: "api", node: "worker").processes.first?.state == .running)
        _ = try await head.client.delete(service: "api", node: "worker")
        #expect(try await head.client.list().processes.isEmpty)
    }
}

@Test func headRunsItsOwnWorkerThroughTheSameContract() async throws {
    try await withCluster { head, worker async throws in
        let list = try await head.client.start(sleeper)
        #expect(list.processes.first?.node == NodeID("head"))
        #expect(await head.launchd.loaded.count == 1)
        #expect(await worker.launchd.loaded.isEmpty)
        var other = sleeper
        other.name = "web"
        other.node = NodeID("worker")
        let both = try await head.client.start(other)
        #expect(Set(both.processes.map(\.node)) == [NodeID("head"), NodeID("worker")])
    }
}

@Test func workerErrorsReachTheCaller() async throws {
    try await withCluster { head, _ async throws in
        var bad = sleeper
        bad.node = NodeID("worker")
        bad.program = .executable("/does/not/exist")
        do {
            _ = try await head.client.start(bad)
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_executable")
        }
        do {
            _ = try await head.client.stop(service: "nope", node: "worker")
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "service_not_found")
        }
        do {
            _ = try await head.client.stop(service: "api", node: "ghost")
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "node_unreachable")
        }
    }
}

@Test func workerKeepsRunningWithoutTheHeadAndTheRegistryRebuilds() async throws {
    let head = try Daemon(node: "head", head: true)
    let worker = try Daemon(node: "worker", head: false)
    try await head.start()
    try await worker.start()
    defer { head.cleanup(); worker.cleanup() }
    let token = try #require(try await eventually { try await head.client.createJoinToken() })
    _ = try await worker.client.join(head: "127.0.0.1:\(head.apiPort)", token: token.token, nodeID: "worker")
    _ = try await eventually { try await head.client.nodes().nodes.count == 2 ? true : nil }
    var spec = sleeper
    spec.node = NodeID("worker")
    _ = try await head.client.start(spec)

    await head.stop()
    // Local control and workloads don't depend on the head.
    #expect(try await worker.client.list().processes.first?.state == .running)
    #expect(try await worker.client.stop(service: "api").processes.first?.state == .stopped)
    #expect(try await worker.client.start(service: "api").processes.first?.state == .running)

    // Same identity and ports: the worker's retry loop re-registers on its own.
    let restarted = try Daemon(node: "head", head: true, env: head.env, agentPort: head.agentPort, apiPort: head.apiPort)
    try await restarted.start()
    let rebuilt = try await eventually { () -> Bool? in
        try await restarted.client.nodes().nodes.first { $0.info.id == NodeID("worker") }?.up == true ? true : nil
    }
    #expect(rebuilt == true)
    #expect(try await restarted.client.list().processes.contains { $0.node == NodeID("worker") })
    await worker.stop()
    await restarted.stop()
}

// MARK: Join

@Test func joinTokensAreSingleUse() async throws {
    let head = try Daemon(node: "head", head: true)
    let first = try Daemon(node: "w1", head: false)
    let second = try Daemon(node: "w2", head: false)
    try await head.start()
    try await first.start()
    try await second.start()
    defer { head.cleanup(); first.cleanup(); second.cleanup() }
    let token = try #require(try await eventually { try await head.client.createJoinToken() })
    let address = "127.0.0.1:\(head.apiPort)"
    _ = try await first.client.join(head: address, token: token.token, nodeID: "w1")

    do {
        _ = try await second.client.join(head: address, token: token.token, nodeID: "w2")
        Issue.record("a used token must not work")
    } catch let error as TenderClientError {
        #expect(error.description.contains("expired or already used"))
    }
    await first.stop()
    await second.stop()
    await head.stop()
}

@Test func joinRejectsWrongFingerprintAndTamperedSecret() async throws {
    let head = try Daemon(node: "head", head: true)
    let worker = try Daemon(node: "w1", head: false)
    try await head.start()
    try await worker.start()
    defer { head.cleanup(); worker.cleanup() }
    let token = try #require(try await eventually { try await head.client.createJoinToken() })
    let address = "127.0.0.1:\(head.apiPort)"
    let parts = token.token.split(separator: ".")

    let wrongCA = "\(parts[0]).\(String(repeating: "0", count: 64))"
    do {
        _ = try await worker.client.join(head: address, token: wrongCA)
        Issue.record("wrong fingerprint must fail")
    } catch let error as TenderClientError {
        #expect(error.description.contains("may not be your head"))
    }
    let wrongSecret = "deadbeef.\(parts[1])"
    do {
        _ = try await worker.client.join(head: address, token: wrongSecret, nodeID: "w1")
        Issue.record("wrong secret must fail")
    } catch let error as TenderClientError {
        #expect(error.description.contains("expired or already used"))
    }
    do {
        _ = try await worker.client.join(head: address, token: "garbage")
        Issue.record("garbage must fail")
    } catch let error as TenderClientError {
        #expect(error.description.contains("isn't valid"))
    }
    // The failures didn't spend the real token, or leave the node half-joined.
    let status = try await worker.client.join(head: address, token: token.token, nodeID: "w1")
    #expect(status.nodeID == NodeID("w1"))
    await worker.stop()
    await head.stop()
}

@Test func joinCantTakeAnExistingNameOrAHeadName() async throws {
    try await withCluster { head, _ async throws in
        let second = try Daemon(node: "other", head: false)
        try await second.start()
        defer { second.cleanup() }
        let address = "127.0.0.1:\(head.apiPort)"
        for (name, code) in [("worker", "node_exists"), ("head", "invalid_node"), ("127.0.0.1", "invalid_node"), ("localhost", "invalid_node")] {
            let token = try await head.client.createJoinToken()
            do {
                _ = try await second.client.join(head: address, token: token.token, nodeID: name)
                Issue.record("\(name) must be refused")
            } catch let error as TenderClientError {
                #expect(error.description.contains(code == "node_exists" ? "already exists" : "name of the head"))
            }
        }
        // A revoked name is free again.
        _ = try await head.client.revokeNode("worker")
        let token = try await head.client.createJoinToken()
        #expect(try await second.client.join(head: address, token: token.token, nodeID: "worker").nodeID == NodeID("worker"))
        await second.stop()
    }
}

@Test func joinTwiceIsRefused() async throws {
    try await withCluster { head, worker async throws in
        let token = try await head.client.createJoinToken()
        do {
            _ = try await worker.client.join(head: "127.0.0.1:\(head.apiPort)", token: token.token)
            Issue.record("expected a refusal")
        } catch let error as TenderClientError {
            #expect(error.code == "already_joined")
        }
    }
}

@Test func revokedNodeIsDroppedAndCantReconnect() async throws {
    try await withCluster { head, worker async throws in
        _ = try await head.client.revokeNode("worker")
        #expect(try await head.client.nodes().nodes.map(\.info.id) == [NodeID("head")])
        // Heartbeats keep trying, and each attempt is refused at the handshake.
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await head.client.nodes().nodes.map(\.info.id) == [NodeID("head")])
        #expect(try await worker.client.list().processes.isEmpty)

        do {
            _ = try await head.client.revokeNode("head")
            Issue.record("the head can't revoke itself")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_node")
        }
    }
}

@Test func removingANodeDeletesItsRecordsAndRefusesLiveOnesWithoutForce() async throws {
    try await withCluster { head, worker async throws in
        // Up, so it needs --force.
        do {
            _ = try await head.client.removeNode("worker")
            Issue.record("an up node must not be removed without force")
        } catch let error as TenderClientError {
            #expect(error.code == "node_up")
        }
        #expect(try await head.client.nodes().nodes.count == 2)

        _ = try await head.client.removeNode("worker", force: true, purgeLogs: true)
        #expect(try await head.client.nodes().nodes.map(\.info.id) == [NodeID("head")])

        // Unknown IDs and the head itself are refused. A repeat removal is fine: it is revoked, so still known.
        for (id, code) in [("nope", "unknown_node"), ("head", "invalid_node")] {
            do {
                _ = try await head.client.removeNode(id, force: true)
                Issue.record("\(id) must be refused")
            } catch let error as TenderClientError {
                #expect(error.code == code)
            }
        }
        _ = try await head.client.removeNode("worker", force: true)
    }
}

// MARK: Public API

@Test func publicAPIRequiresTokensAndHonorsScopes() async throws {
    try await withCluster { head, _ async throws in
        let reader = try await head.client.createAPIToken(name: "reader", scope: .read)
        let writer = try await head.client.createAPIToken(name: "writer", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let caPEM = try await ClientPinning.fetchCA(head: address, credential: reader.token)
        #expect(caPEM.contains("BEGIN CERTIFICATE"))

        let readClient = TenderClient(head: address, caPEM: caPEM, token: reader.token)
        #expect(try await readClient.nodes().nodes.count == 2)
        #expect(try await readClient.list().processes.isEmpty)
        do {
            _ = try await readClient.start(sleeper)
            Issue.record("read tokens can't write")
        } catch let error as TenderClientError {
            #expect(error.code == "forbidden")
        }

        let writeClient = TenderClient(head: address, caPEM: caPEM, token: writer.token)
        #expect(try await writeClient.start(sleeper).processes.count == 1)
        _ = try await writeClient.delete(service: "api")

        // The app's Remove button: write scope only, and a node that is up needs force.
        do {
            _ = try await readClient.removeNode("worker", force: true)
            Issue.record("read tokens can't remove nodes")
        } catch let error as TenderClientError {
            #expect(error.code == "forbidden")
        }
        do {
            _ = try await writeClient.removeNode("worker")
            Issue.record("an up node needs force")
        } catch let error as TenderClientError {
            #expect(error.code == "node_up")
        }
        #expect(try await writeClient.removeNode("worker", force: true).nodes.map(\.info.id) == [NodeID("head")])

        do {
            _ = try await TenderClient(head: address, caPEM: caPEM, token: "nonsense").nodes()
            Issue.record("unknown tokens are refused")
        } catch let error as TenderClientError {
            #expect(error.code == "unauthorized")
        }

        // Revocation applies at once, and admin routes aren't on the public listener at all.
        _ = try await head.client.revokeAPIToken(name: "reader")
        do {
            _ = try await readClient.nodes()
            Issue.record("revoked tokens are refused")
        } catch let error as TenderClientError {
            #expect(error.code == "unauthorized")
        }
        for call in [{ _ = try await writeClient.createJoinToken() },
                     { _ = try await writeClient.exportCA() },
                     { _ = try await writeClient.createAPIToken(name: "x", scope: .write) }] as [@Sendable () async throws -> Void] {
            do {
                try await call()
                Issue.record("admin routes must not be public")
            } catch let error as TenderClientError {
                #expect(error.code == "http_404")
            }
        }
    }
}

@Test func clientRefusesAHeadWithAnotherCA() async throws {
    try await withCluster { head, _ async throws in
        let address = "127.0.0.1:\(head.apiPort)"
        let token = try await head.client.createAPIToken(name: "t", scope: .read)
        let other = try CertificateAuthority.create()
        do {
            _ = try await TenderClient(head: address, caPEM: other.certificatePEM, token: token.token).nodes()
            Issue.record("must refuse a certificate from another CA")
        } catch let error as TenderClientError {
            #expect(error.code == "daemon_unreachable")
        }
        await #expect(throws: ClientPinningError.self) {
            _ = try await ClientPinning.fetchCA(head: address, credential: "secret.\(other.fingerprint)")
        }
        await #expect(throws: ClientPinningError.invalidCredential) {
            _ = try await ClientPinning.fetchCA(head: address, credential: "nofingerprint")
        }
    }
}

@Test func caExportMatchesTheFingerprintAndPersists() async throws {
    let head = try Daemon(node: "head", head: true)
    try await head.start()
    defer { head.cleanup() }
    let exported = try await head.client.exportCA()
    let authority = try CertificateAuthority(certificatePEM: exported.certificatePEM, privateKeyPEM: exported.privateKeyPEM)
    let token = try await head.client.createJoinToken()
    #expect(JoinToken(parsing: token.token)?.caFingerprint == authority.fingerprint)
    await head.stop()

    let restarted = try Daemon(node: "head", head: true, env: head.env, agentPort: head.agentPort, apiPort: head.apiPort)
    try await restarted.start()
    #expect(try await restarted.client.exportCA() == exported)
    await restarted.stop()
}

// MARK: Store and registry

@Test func storeExpiresTokensAndHashesSecrets() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = try HeadStore(environment: env)
    let now = Date()
    try store.addJoinToken(secret: "live", expiresAt: now.addingTimeInterval(60))
    try store.addJoinToken(secret: "dead", expiresAt: now.addingTimeInterval(-1))
    #expect(try store.consumeJoinToken(secret: "dead", now: now) == false)
    #expect(try store.consumeJoinToken(secret: "unknown", now: now) == false)
    #expect(try store.consumeJoinToken(secret: "live", now: now) == true)
    #expect(try store.consumeJoinToken(secret: "live", now: now) == false)

    #expect(try store.addAPIToken(secret: "s3cret", name: "n", scope: .write) != nil)
    #expect(try store.addAPIToken(secret: "other", name: "n", scope: .read) == nil)
    #expect(try store.apiToken(secret: "s3cret")?.scope == .write)
    let file = try Data(contentsOf: env.root.appending(path: "head.db"))
    let wal = (try? Data(contentsOf: env.root.appending(path: "head.db-wal"))) ?? Data()
    #expect(file.range(of: Data("s3cret".utf8)) == nil)
    #expect(wal.range(of: Data("s3cret".utf8)) == nil)
}

@Test func nodeGoesDownAfterTheTimeout() async {
    let state = RegistryState(store: nil, downAfter: 20)
    let info = NodeInfo(id: NodeID("n"), version: "1", macOS: "x", hardware: "y", address: "1.2.3.4:7070")
    try? await state.register(info)
    let start = Date()
    #expect(await !state.isUp(NodeID("n"), now: start))
    #expect(await state.heartbeat(Heartbeat(node: NodeID("n"), nodeClock: start, processes: []), registeredThisRun: true, now: start))
    #expect(await state.isUp(NodeID("n"), now: start.addingTimeInterval(19)))
    #expect(await !state.isUp(NodeID("n"), now: start.addingTimeInterval(21)))
    #expect(await state.downNodes(now: start.addingTimeInterval(21)) == [NodeID("n")])
    #expect(await !state.heartbeat(Heartbeat(node: NodeID("n"), nodeClock: start, processes: []), registeredThisRun: false, now: start))
    #expect(await !state.heartbeat(Heartbeat(node: NodeID("x"), nodeClock: start, processes: []), registeredThisRun: true, now: start))
}

@Test func nodesAreFoundByIDOrByAnUnambiguousHostname() async throws {
    let state = RegistryState(store: nil)
    let a = NodeID("0b6f1c9e-0000-4000-8000-00000000000a"), b = NodeID("0b6f1c9e-0000-4000-8000-00000000000b")
    try await state.register(NodeInfo(id: a, version: "1", macOS: "x", hardware: "y", hostname: "mac-mini"))
    try await state.register(NodeInfo(id: b, version: "1", macOS: "x", hardware: "y", hostname: "macbook"))
    #expect(await state.resolve(a.rawValue) == a)
    #expect(await state.resolve("MacBook") == b)
    #expect(await state.resolve("nope") == nil)
    // A hostname two nodes share can't pick one.
    try await state.register(NodeInfo(id: NodeID("c"), version: "1", macOS: "x", hardware: "y", hostname: "macbook"))
    #expect(await state.resolve("macbook") == nil)
}

@Test func lastKnownNodesLoadAsDown() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = try HeadStore(environment: env)
    try store.saveNode(NodeInfo(id: NodeID("old"), version: "1", macOS: "x", hardware: "y"))
    let state = RegistryState(store: store)
    let summaries = await state.summaries()
    #expect(summaries.map(\.info.id) == [NodeID("old")])
    #expect(summaries.first?.up == false)
}

// MARK: Logs

/// The plan's definition of done: lines written while the head is away arrive after it
/// returns, in order, with none lost and none duplicated.
@Test func logsShipAcrossAHeadOutageWithoutLossOrDuplicates() async throws {
    let head = try Daemon(node: "head", head: true)
    let worker = try Daemon(node: "worker", head: false)
    try await head.start()
    try await worker.start()
    defer { head.cleanup(); worker.cleanup() }
    let token = try #require(try await eventually { try await head.client.createJoinToken() })
    _ = try await worker.client.join(head: "127.0.0.1:\(head.apiPort)", token: token.token, nodeID: "worker")
    var spec = sleeper
    spec.node = NodeID("worker")
    _ = try await eventually { try await head.client.nodes().nodes.count == 2 ? true : nil }
    _ = try await head.client.start(spec)

    let log = worker.env.stdoutLog(service: "api", instance: 0)
    FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
    func write(_ range: ClosedRange<Int>) throws {
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(range.map { "line \($0)\n" }.joined().utf8))
        try handle.close()
    }
    func received(from client: TenderClient) async throws -> [String] {
        try await client.searchLogs(LogQuery(service: "api", limit: 5000)).entries.map(\.line)
    }

    try write(1...100)
    #expect(try await eventually { try await received(from: head.client).count == 100 ? true : nil } == true)

    await head.stop()
    try write(101...300)
    try await Task.sleep(for: .milliseconds(600))
    await worker.stop() // A restart while disconnected: offsets and spool must both survive.
    let workerAgain = try Daemon(node: "worker", head: false, env: worker.env, agentPort: worker.agentPort)
    try await workerAgain.start()
    try write(301...400)

    let back = try Daemon(node: "head", head: true, env: head.env, agentPort: head.agentPort, apiPort: head.apiPort)
    try await back.start()
    #expect(try await eventually { try await received(from: back.client).count >= 400 ? true : nil } == true)
    let lines = try await received(from: back.client)
    #expect(lines == (1...400).map { "line \($0)" })
    let result = try await back.client.searchLogs(LogQuery(service: "api", text: "399"))
    #expect(result.entries.map(\.line) == ["line 399"])
    await workerAgain.stop()
    await back.stop()
}

@Test func followStreamsLinesFromEveryNode() async throws {
    try await withCluster { head, worker async throws in
        var spec = sleeper
        spec.node = NodeID("worker")
        _ = try await head.client.start(spec)
        let log = worker.env.stdoutLog(service: "api", instance: 0)
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)

        var iterator = head.client.followClusterLogs(LogQuery(service: "api")).makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(200))
        let handle = try FileHandle(forWritingTo: log)
        try handle.write(contentsOf: Data("live line\n".utf8))
        try handle.close()
        let entry = try await iterator.next()
        #expect(entry?.line == "live line")
        #expect(entry?.node == NodeID("worker"))
    }
}

@Test func skewSpoolAndSecretFetchStatsReachTheSummary() async throws {
    let store = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let summaryState = RegistryState(store: nil)
    let info = NodeInfo(id: NodeID("n"), version: "1", macOS: "x", hardware: "y")
    try await summaryState.register(info)
    let now = Date()
    _ = await summaryState.heartbeat(Heartbeat(node: NodeID("n"), nodeClock: now.addingTimeInterval(-5), processes: [],
                                               previousRoundTrip: 2, spoolBacklog: 3, spoolDropped: 4, secretFetchErrors: 6),
                                     registeredThisRun: true, now: now)
    let summary = try #require(await summaryState.summaries(now: now).first)
    #expect(abs((summary.clockSkew ?? 0) - 4) < 0.001)
    #expect(summary.spoolBacklog == 3)
    #expect(summary.spoolDropped == 4)
    #expect(summary.secretFetchErrors == 6)
}

@Test func nodeHistoryIsServedBoundedAndPerNode() async throws {
    try await withCluster { head, _ async throws in
        let history = try #require(try await eventually { () -> NodeStatsHistory? in
            let history = try await head.client.nodeHistory(node: "worker")
            return history.points.count >= 5 ? history : nil
        })
        #expect(history.node == NodeID("worker"))
        #expect(history.points.map(\.date) == history.points.map(\.date).sorted())
        #expect(try await head.client.nodeHistory(node: "worker", limit: 2).points.count == 2)
        let later = try #require(history.points.last?.date)
        #expect(try await head.client.nodeHistory(node: "worker", since: later).points.allSatisfy { $0.date >= later })
        for (node, limit, code) in [("nope", nil, "node_not_found"), ("worker", 0, "invalid_query")] as [(String, Int?, String)] {
            do {
                _ = try await head.client.nodeHistory(node: node, limit: limit)
                Issue.record("expected \(code)")
            } catch let error as TenderClientError {
                #expect(error.code == code)
            }
        }
    }
}

@Test func processHistoryIsServedPerInstance() async throws {
    try await withCluster { head, _ async throws in
        var spec = sleeper
        spec.node = NodeID("worker")
        _ = try await head.client.start(spec)
        let history = try #require(try await eventually { () -> ProcessStatsHistory? in
            let history = try await head.client.processHistory(service: "api")
            return history.points.count >= 2 ? history : nil
        })
        #expect(history.node == NodeID("worker"), "found on the one node running it")
        #expect(history.instance == 0)
        #expect(try await head.client.processHistory(service: "api", node: "worker", instance: 0, limit: 1).points.count == 1)
        #expect(try await head.client.processHistory(service: "api", node: "worker", instance: 7).points.isEmpty)
        for (node, limit, code) in [("nope", nil, "node_not_found"), ("worker", 0, "invalid_query")] as [(String, Int?, String)] {
            do {
                _ = try await head.client.processHistory(service: "api", node: node, limit: limit)
                Issue.record("expected \(code)")
            } catch let error as TenderClientError {
                #expect(error.code == code)
            }
        }
        _ = try await head.client.delete(service: "api", node: "worker")
    }
}

@Test func historyRetentionIsReadByAnyTokenAndChangedOnlyWithWrite() async throws {
    try await withCluster { head, _ async throws in
        #expect(try await head.client.historyRetention() == HistoryRetention())
        let reader = try await head.client.createAPIToken(name: "reader", scope: .read)
        let writer = try await head.client.createAPIToken(name: "writer", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let caPEM = try await ClientPinning.fetchCA(head: address, credential: reader.token)
        let readClient = TenderClient(head: address, caPEM: caPEM, token: reader.token)
        #expect(try await readClient.historyRetention().processDays == HistoryRetention.defaultDays)
        do {
            _ = try await readClient.setHistoryRetention(HistoryRetentionUpdate(processDays: 7))
            Issue.record("read tokens can't change retention")
        } catch let error as TenderClientError {
            #expect(error.code == "forbidden")
        }
        let writeClient = TenderClient(head: address, caPEM: caPEM, token: writer.token)
        let changed = try await writeClient.setHistoryRetention(HistoryRetentionUpdate(processDays: 7))
        #expect(changed == HistoryRetention(nodeDays: HistoryRetention.defaultDays, processDays: 7))
        #expect(try await readClient.historyRetention() == changed)
        do {
            _ = try await writeClient.setHistoryRetention(HistoryRetentionUpdate(nodeDays: 0))
            Issue.record("expected invalid_retention")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_retention")
        }
    }
}

// MARK: Security

@Test func aWorkerCantCommandAnotherNode() async throws {
    try await withCluster { head, worker async throws in
        // A real certificate for the cluster, as a compromised worker holds.
        let exported = try await head.client.exportCA()
        let authority = try CertificateAuthority(certificatePEM: exported.certificatePEM, privateKeyPEM: exported.privateKeyPEM)
        let key = NodeKey.generate()
        let tls = TransportTLS(certificatePEM: try authority.sign(csrPEM: try key.makeCSR(nodeID: NodeID("rogue")), nodeID: NodeID("rogue")),
                               privateKeyPEM: key.privateKeyPEM, trustRootPEM: exported.certificatePEM)
        let resolver = StaticNodeResolver([NodeID("head"): NodeAddress(host: "127.0.0.1", port: head.agentPort),
                                           NodeID("worker"): NodeAddress(host: "127.0.0.1", port: worker.agentPort)])
        let rogue = TenderActorSystem(localNode: NodeID("rogue"), tls: tls, resolver: resolver)
        defer { Task { await rogue.shutdown() } }
        for target in ["head", "worker"] {
            let agent = try $NodeAgentProtocol.resolve(id: ActorIdentity(node: NodeID(target), name: ActorNames.agent), using: rogue)
            await #expect(throws: NodeCallError(code: "forbidden", message: "Only the head can command this node.", httpStatus: 403)) {
                _ = try await agent.apply(.start(sleeper))
            }
            await #expect(throws: NodeCallError.self) { _ = try await agent.status() }
            await #expect(throws: NodeCallError.self) { _ = try await agent.releases(service: "api") }
            await #expect(throws: NodeCallError.self) { _ = try await agent.deploy(service: "api", version: "1") }
        }
        // Nor can it speak for another node to the head.
        let registry = try $HeadRegistryProtocol.resolve(id: ActorIdentity(node: NodeID("head"), name: ActorNames.registry), using: rogue)
        await #expect(throws: NodeCallError.self) {
            _ = try await registry.ingest(LogBatch(node: NodeID("worker"), previousSeq: 0, records: []))
        }
        await #expect(throws: NodeCallError.self) {
            try await registry.heartbeat(Heartbeat(node: NodeID("worker"), nodeClock: Date(), processes: []))
        }
        #expect(await head.launchd.loaded.isEmpty)
        #expect(await worker.launchd.loaded.isEmpty)
    }
}

@Test func adoptIsNotAvailableRemotely() async throws {
    try await withCluster { head, _ async throws in
        let writer = try await head.client.createAPIToken(name: "w", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let caPEM = try await ClientPinning.fetchCA(head: address, credential: writer.token)
        do {
            _ = try await TenderClient(head: address, caPEM: caPEM, token: writer.token).adopt(label: "x.y", logPath: "/etc/master.passwd")
            Issue.record("remote adopt would read any file as root")
        } catch let error as TenderClientError {
            #expect(error.code == "http_404")
        }
    }
}

/// Adoption is socket-only, so the job is adopted on the worker itself. Abandoning
/// it through the head without `--node` must reach the worker, not the head's own node.
@Test func abandonThroughTheHeadReachesTheNodeThatAdoptedIt() async throws {
    try await withCluster { head, worker async throws in
        let label = "homebrew.mxcl.postgresql@18"
        try await worker.launchd.bootstrap(plistURL: URL(filePath: "/tmp/\(label).plist"))
        _ = try await worker.client.adopt(label: label)
        // The head finds the node from heartbeats, not from a live list.
        let reported = try await eventually { () -> Bool? in
            try await head.client.nodes().nodes.first { $0.info.id == NodeID("worker") }?.instanceCount == 1 ? true : nil
        }
        #expect(reported == true)

        let list = try await head.client.forget(label: label)
        #expect(!list.processes.contains { $0.service == label })
        #expect(try await worker.client.list().processes.isEmpty)
        #expect(await worker.launchd.loaded == [label], "abandon must leave the job running")
    }
}

@Test func abandoningAnUnknownLabelIsNotAdopted() async throws {
    try await withCluster { head, _ async throws in
        for node in [nil, "worker"] {
            do {
                _ = try await head.client.forget(label: "no.such.job", node: node)
                Issue.record("expected not_adopted")
            } catch let error as TenderClientError {
                #expect(error.code == "not_adopted")
                #expect(error.description.contains("no.such.job"))
            }
        }
    }
}

@Test func systemJobsCantBeAdopted() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let adoption = Adoption(environment: env, store: try StateStore(environment: env), launchd: MemoryLaunchd())
    await #expect(throws: AdoptionError.systemJob("com.apple.syslogd")) { try await adoption.adopt(label: "com.apple.syslogd") }
}

@Test func uidZeroAliasesAreRefused() async throws {
    try await withCluster { head, _ async throws in
        var spec = sleeper
        spec.user = "root"
        do {
            _ = try await head.client.start(spec)
            Issue.record("root must be refused")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_user")
        }
    }
}

@Test func terminalControlCharactersAreNeutralized() {
    let safe = terminalSafe("a\u{1B}[2Jb\tc\u{7F}d\u{9B}é")
    #expect(!safe.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x7F || $0.value == 0x9B })
    #expect(safe.contains("\t"))
    #expect(safe.contains("é"))
}

// MARK: Operations

@Test func auditRecordsWritesWithoutSecrets() async throws {
    try await withCluster { head, _ async throws in
        let writer = try await head.client.createAPIToken(name: "alice", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let caPEM = try await ClientPinning.fetchCA(head: address, credential: writer.token)
        let remote = TenderClient(head: address, caPEM: caPEM, token: writer.token)
        _ = try await remote.start(sleeper)
        _ = try await remote.list()
        let file = head.env.root.appending(path: "logstore/audit-\(TenderLogStore.LogStore.dayName(Date())).jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        let records = text.split(separator: "\n")
        #expect(records.contains { $0.contains(#""who":"alice""#) && $0.contains(#""path":"\/v1\/processes""#) && $0.contains(#""status":200"#) })
        #expect(records.contains { $0.contains(#""who":"local-socket""#) && $0.contains("api-tokens") })
        #expect(!records.contains { $0.contains(#""method":"GET""#) }, "reads aren't audited")
        let secret = String(writer.token.split(separator: ".")[0])
        #expect(!text.contains(secret), "tokens must never reach the audit log")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

private final class RecordingUploader: BlobUploader, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var failing = false
    var names: [String] { lock.withLock { stored } }
    func upload(file: URL, as name: String) async throws {
        if failing { throw NodeCallError(code: "x", message: "down") }
        lock.withLock { stored.append(name) }
    }
}

@Test func offloadUploadsClosedDaysOnceAndRetriesFailures() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let logs = try LogStore(directory: env.root.appending(path: "logstore"))
    let audit = try AuditLog(directory: env.root.appending(path: "logstore"))
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await logs.ingest(LogBatch(node: NodeID("n"), previousSeq: 0, records: [
        LogRecord(seq: 1, nodeTime: day, service: "a", instance: 0, stream: .out, line: "x")]), now: day)
    audit.record(.init(time: day, who: "w", method: "POST", path: "/p", status: 200))
    let uploader = RecordingUploader()
    let offload = NightlyOffload(logs: logs, audit: audit, uploader: { uploader })

    #expect(try await offload.runOnce(now: day) == 0, "today's files stay open")
    let tomorrow = day.addingTimeInterval(86400)
    uploader.failing = true
    await #expect(throws: (any Error).self) { try await offload.runOnce(now: tomorrow) }
    uploader.failing = false
    #expect(try await offload.runOnce(now: tomorrow) == 2)
    let name = LogStore.dayName(day)
    #expect(Set(uploader.names) == ["logs/logs-\(name).db", "audit/audit-\(name).jsonl"])
    #expect(try await offload.runOnce(now: tomorrow) == 0, "each file goes up once")

    let disabled = NightlyOffload(logs: logs, audit: audit, uploader: { nil })
    #expect(try await disabled.runOnce(now: tomorrow) == 0)
}

private struct FakeSource: ReleaseSource {
    let contents: Data
    let sha256: String
    func fetch(service: String, version: String, to destination: URL) async throws -> String {
        try contents.write(to: destination)
        return sha256
    }
}

@Test func deployReachesEveryNodeRunningTheServiceAndReportsEach() async throws {
    let binary = Data("#!/bin/sh\nexec /bin/sleep 100\n".utf8)
    let good = FakeSource(contents: binary, sha256: Data(SHA256.hash(data: binary)).map { String(format: "%02x", $0) }.joined())
    let bad = FakeSource(contents: Data("tampered".utf8), sha256: good.sha256)
    let head = try Daemon(node: "head", head: true, source: good)
    let worker = try Daemon(node: "worker", head: false, source: bad)
    try await head.start()
    try await worker.start()
    defer { head.cleanup(); worker.cleanup() }
    let token = try #require(try await eventually { try await head.client.createJoinToken() })
    _ = try await worker.client.join(head: "127.0.0.1:\(head.apiPort)", token: token.token, nodeID: "worker")
    _ = try await eventually { try await head.client.nodes().nodes.filter(\.up).count == 2 ? true : nil }
    var onWorker = sleeper
    onWorker.node = NodeID("worker")
    _ = try await head.client.start(sleeper)
    _ = try await head.client.start(onWorker)
    _ = try await eventually { try await head.client.nodes().nodes.allSatisfy { $0.instanceCount == 1 } ? true : nil }

    let response = try await head.client.deploy(service: "api", version: "1.0")
    #expect(response.outcomes.map(\.node) == [NodeID("head"), NodeID("worker")])
    let sha12 = String(good.sha256.prefix(12))
    #expect(response.outcomes[0].sha12 == sha12)
    #expect(response.outcomes[1].sha12 == nil, "a tampered download must not install")
    #expect(response.outcomes[1].error?.contains("Checksum mismatch") == true)

    let releases = try await head.client.clusterReleases(service: "api")
    #expect(releases.nodes.map(\.node) == [NodeID("head")])
    #expect(releases.nodes.first?.releases.current == sha12)

    let list = try await head.client.list()
    #expect(list.processes.first { $0.node == NodeID("head") }?.release == sha12)
    #expect(list.processes.first { $0.node == NodeID("worker") }?.release == nil, "the worker keeps running its old binary")
    await worker.stop()
    await head.stop()
}

@Test func deployWithoutASourceSaysSo() async throws {
    try await withCluster { head, _ async throws in
        _ = try await head.client.start(sleeper)
        let response = try await head.client.deploy(service: "api", version: "1.0", node: "head")
        #expect(response.outcomes.first?.error?.contains("isn't configured") == true)
    }
}

@Test func metricsEndpointServesTheCluster() async throws {
    try await withCluster { head, _ async throws in
        let services = try await head.client.start(sleeper)
        #expect(services.processes.count == 1)
        let text = try #require(try await eventually { () -> String? in
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(head.metricsPort)/metrics")!)
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("tender_process_up") && text.contains(#"service="api""#) ? text : nil
        })
        #expect(text.contains(#"tender_node_up{node="worker"} 1.0"#))
        #expect(text.contains(#"tender_node_clock_skew_seconds{node="worker"}"#))
    }
}

@Test func credentialsAreSavedOnlyOverTheSocketAndNeverReadBack() async throws {
    try await withCluster { head, worker async throws in
        do {
            _ = try await worker.client.setCredentials(serviceAccountJSON: "{}")
            Issue.record("invalid keys must be refused")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_credentials")
        }
        let writer = try await head.client.createAPIToken(name: "w", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let caPEM = try await ClientPinning.fetchCA(head: address, credential: writer.token)
        do {
            _ = try await TenderClient(head: address, caPEM: caPEM, token: writer.token).setCredentials(serviceAccountJSON: "{}")
            Issue.record("credentials must not be settable remotely")
        } catch let error as TenderClientError {
            #expect(error.code == "http_404")
        }
    }
}

@Test func secretsGoThroughTheHeadToTheNodeThatRunsTheService() async throws {
    try await withCluster { head, worker async throws in
        var spec = sleeper
        spec.node = NodeID("worker")
        spec.environment = ["PASS": "${secret:PASS}"]
        _ = try await head.client.start(spec)
        let placed = try await eventually { () -> Bool? in
            try await head.client.nodes().nodes.first { $0.info.id == NodeID("worker") }?.instanceCount == 1 ? true : nil
        }
        #expect(placed == true)

        // Without a node, a service's secret goes where the service runs.
        let set = try await head.client.setSecret("api/PASS", value: Data("s3cret".utf8))
        #expect(set.secrets.map(\.node) == [NodeID("worker")])
        #expect(try await worker.client.secrets().secrets.map(\.name) == ["api/PASS"])
        #expect(try await head.client.secrets().secrets.map(\.usedBy) == [["api"]])

        do {
            _ = try await head.client.setSecret("shared/KEY", value: Data("k".utf8))
            Issue.record("a shared secret needs a node")
        } catch let error as TenderClientError {
            #expect(error.code == "node_required")
        }
        let everywhere = try await head.client.setSecret("shared/KEY", value: Data("k".utf8), allNodes: true)
        #expect(Set(everywhere.secrets.filter { $0.name == "shared/KEY" }.map(\.node)) == [NodeID("head"), NodeID("worker")])
        _ = try await head.client.deleteSecret("api/PASS", node: "worker")
        #expect(try await worker.client.secrets().secrets.map(\.name) == ["shared/KEY"])

        let reader = try await head.client.createAPIToken(name: "r", scope: .read)
        let address = "127.0.0.1:\(head.apiPort)"
        let remote = TenderClient(head: address, caPEM: try await ClientPinning.fetchCA(head: address, credential: reader.token),
                                  token: reader.token)
        #expect(try await remote.secrets().secrets.count == 2)
        do {
            _ = try await remote.setSecret("api/PASS", value: Data("x".utf8), node: "worker")
            Issue.record("a read token must not set secrets")
        } catch let error as TenderClientError {
            #expect(error.code == "forbidden")
        }
    }
}

// MARK: Health

@Test func healthSummarizesTheCluster() {
    func node(_ up: Bool) -> NodeSummary {
        NodeSummary(info: NodeInfo(id: NodeID("n"), version: "1", macOS: "x", hardware: "y"), up: up,
                    lastHeartbeatAge: nil, instanceCount: 0, crashedCount: 0)
    }
    let crashed = InstanceStatus(service: "a", instance: 0, node: NodeID("n"), state: .crashed)
    let running = InstanceStatus(service: "a", instance: 0, node: NodeID("n"), state: .running)
    #expect(ClusterHealth(nodes: NodeList(nodes: [node(true)]), processes: ProcessList(processes: [running])) == .healthy)
    let downAndCrashed = ClusterHealth(nodes: NodeList(nodes: [node(false), node(true)]), processes: ProcessList(processes: [crashed]))
    #expect(downAndCrashed == .degraded(downNodes: 1, crashed: 1))
    #expect(downAndCrashed.summary == "1 node down, 1 crashed")
    #expect(ClusterHealth.notConfigured.symbol == "leaf")
}

@Test func metersReflectEachNode() {
    func node(_ name: String, up: Bool = true) -> NodeSummary {
        NodeSummary(info: NodeInfo(id: NodeID(name), version: "1", macOS: "x", hardware: "y"), up: up,
                    lastHeartbeatAge: nil, instanceCount: 0, crashedCount: 0)
    }
    func process(_ name: String, _ state: InstanceState) -> InstanceStatus {
        InstanceStatus(service: "a", instance: 0, node: NodeID(name), state: state)
    }
    let meters = NodeMeter.meters(
        nodes: [node("ok"), node("hurt"), node("gone", up: false), node("idle"), node("off"), node("joels-macbook-pro")],
        processes: [process("ok", .running), process("ok", .starting),
                    process("hurt", .running), process("hurt", .crashed), process("hurt", .stopped),
                    process("gone", .running), process("off", .stopped)])
    #expect(meters[0] == NodeMeter(label: "ok", fraction: 1, level: .healthy))
    #expect(meters[1] == NodeMeter(label: "hurt", fraction: 0.5, level: .degraded), "stopped isn't a failure")
    #expect(meters[2] == NodeMeter(label: "gone", fraction: 1, level: .down), "a stale report doesn't matter once it's down")
    #expect(meters[3].level == .healthy)
    #expect(meters[4].level == .healthy, "stopping everything on purpose is healthy")
    #expect(meters[5].label == "joels-macbook-p…")
    #expect(NodeMeter.shortLabel("exactly-sixteen!") == "exactly-sixteen!")
}

@Test func theHeadsMeterIsMarked() {
    func node(_ name: String, labels: [String: String] = [:]) -> NodeSummary {
        NodeSummary(info: NodeInfo(id: NodeID(name), version: "1", macOS: "x", hardware: "y", labels: labels), up: true,
                    lastHeartbeatAge: nil, instanceCount: 0, crashedCount: 0)
    }
    let head = node("head", labels: [NodeInfo.roleLabel: NodeInfo.headRole])
    #expect(NodeMeter.meters(nodes: [head, node("worker")], processes: []).map(\.isHead) == [true, false])
}

@Test func aOneNodeClusterMeterTakesTheConnectionName() {
    func node(_ name: String) -> NodeSummary {
        NodeSummary(info: NodeInfo(id: NodeID(name), version: "1", macOS: "x", hardware: "y"), up: true,
                    lastHeartbeatAge: nil, instanceCount: 0, crashedCount: 0)
    }
    let one = [node("joels-mac-mini")]
    #expect(NodeMeter.meters(nodes: one, processes: [], clusterName: "mini-0")[0].label == "mini-0")
    #expect(NodeMeter.meters(nodes: one, processes: [], clusterName: "a-very-long-connection")[0].label == "a-very-long-con…")
    #expect(NodeMeter.meters(nodes: one, processes: [])[0].label == "joels-mac-mini")
    let two = NodeMeter.meters(nodes: [node("mac-1"), node("mac-2")], processes: [], clusterName: "mini-0")
    #expect(two.map(\.label) == ["mac-1", "mac-2"])
}

@Test func metersAndOrderUseHostnamesNotUUIDs() {
    func node(_ id: String, hostname: String?, head: Bool = false) -> NodeSummary {
        NodeSummary(info: NodeInfo(id: NodeID(id), version: "1", macOS: "x", hardware: "y",
                                   labels: head ? [NodeInfo.roleLabel: NodeInfo.headRole] : [:], hostname: hostname),
                    up: true, lastHeartbeatAge: nil, instanceCount: 0, crashedCount: 0)
    }
    let head = node("88e68331-3a92-4a5e-88eb-1992d20c4763", hostname: "mac-mini", head: true)
    let worker = node("7b556fd5-dbe2-4a1b-9c3d-000000000000", hostname: "mac-mini-2")
    let unnamed = node("00000000-0000-0000-0000-000000000000", hostname: nil)
    #expect([worker, unnamed, head].headFirst().map(\.info.id) == [head.info.id, unnamed.info.id, worker.info.id],
            "head first, then by name; an unnamed node sorts by its ID")
    #expect(NodeMeter.meters(nodes: [head, worker], processes: []).map(\.label) == ["mac-mini", "mac-mini-2"])
}

@Test func contextStorePersistsAndClears() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = ClientContextStore.standard(environment: ["TENDER_CONFIG_DIR": env.root.path(percentEncoded: false)])
    #expect(try store.load() == nil)
    try store.save(ClientContext(head: "h:1", caPEM: "pem"), token: "t")
    #expect(try store.load()?.token == "t")
    #expect(try store.load()?.context.head == "h:1")
    let onDisk = try String(contentsOf: env.root.appending(path: "context.json"), encoding: .utf8)
    #expect(!onDisk.contains("\"t\""), "the token belongs in the secret store")
    try store.clear()
    #expect(try store.load() == nil)
}

@Test func historyListsChangesNewestFirstWithFailuresCounted() async throws {
    try await withCluster { head, _ async throws in
        let writer = try await head.client.createAPIToken(name: "alice", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let remote = TenderClient(head: address, caPEM: try await ClientPinning.fetchCA(head: address, credential: writer.token),
                                  token: writer.token)
        _ = try await remote.start(sleeper)
        _ = try? await remote.restart(service: "nope", node: "worker")
        _ = try await remote.list()

        let history = try await remote.history(AuditQuery(since: Date().addingTimeInterval(-60)))
        let alices = history.records.filter { $0.who == "alice" }
        #expect(alices.map(\.action) == ["restart", "start"], "newest first, reads left out")
        #expect(alices.first?.target == "nope" && alices.first?.node == "worker" && alices.first?.succeeded == false)
        #expect(alices.last?.target == "api" && alices.last?.succeeded == true)
        #expect(history.failures >= 1)
        #expect(try await remote.history(AuditQuery(who: "alice", failedOnly: true)).records.map(\.action) == ["restart"])
        #expect(try await remote.history(AuditQuery(about: "api")).records.allSatisfy { $0.target == "api" })
        let limited = try await remote.history(AuditQuery(limit: 1))
        #expect(limited.records.count == 1 && limited.truncated)
    }
}

@Test func labelsAreKeptByTheNodeAndNameItEverywhere() async throws {
    try await withCluster { head, worker async throws in
        let nodes = try await head.client.updateLabels(node: "worker", NodeLabelsUpdate(set: ["name": "Basement mini", "rack": "a"]))
        let summary = try #require(nodes.nodes.first { $0.info.id == NodeID("worker") })
        #expect(summary.info.displayName == "Basement mini")
        #expect(summary.info.userLabels == ["name": "Basement mini", "rack": "a"])

        // The node holds them: in its config, and in what it registers with.
        let file = worker.env.configDirectory.appending(path: "labels.json")
        #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)) == ["name": "Basement mini", "rack": "a"])

        // A display name resolves like a hostname.
        _ = try await head.client.updateLabels(node: "basement mini", NodeLabelsUpdate(remove: ["rack"]))
        let after = try await head.client.nodes().nodes.first { $0.info.id == NodeID("worker") }
        #expect(after?.info.userLabels == ["name": "Basement mini"])

        do {
            _ = try await head.client.updateLabels(node: "head", NodeLabelsUpdate(set: ["role": "worker"]))
            Issue.record("role is Tender's own")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_labels")
        }
        #expect(try await head.client.nodes().nodes.first { $0.info.id == NodeID("head") }?.info.isHead == true)
        #expect(try await head.client.history(AuditQuery(about: "basement")).records.first?.action == "label node")
    }
}
