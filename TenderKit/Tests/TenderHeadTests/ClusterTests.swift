import Foundation
import LaunchdKit
import Testing
import TenderActorSystem
import TenderAgent
import TenderClient
import TenderCore
import TenderPKI
import TenderProtocol
@testable import TenderHead

actor MemoryLaunchd: LaunchdControlling {
    var loaded: Set<String> = []
    func bootstrap(plistURL: URL) async throws { loaded.insert(plistURL.deletingPathExtension().lastPathComponent) }
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

    init(node: String, head: Bool, env: TenderEnvironment? = nil, agentPort: Int? = nil, apiPort: Int? = nil) throws {
        self.env = try env ?? makeEnvironment()
        self.agentPort = agentPort ?? freePort()
        self.apiPort = apiPort ?? freePort()
        isHead = head
        nodeName = node
    }

    func start() async throws {
        let secrets = env.makeSecretStore()
        let cluster = ClusterOptions(listenHost: "127.0.0.1", advertiseHost: "127.0.0.1", agentPort: agentPort,
                                     identityMode: .off, heartbeatInterval: .milliseconds(100))
        var hooks: ClusterHooks?
        if isHead {
            let options = HeadOptions(nodeID: NodeID(nodeName), apiHost: "127.0.0.1", apiPort: apiPort, agentPort: agentPort,
                                      advertisedNames: ["127.0.0.1"])
            hooks = try HeadServices(environment: env, secrets: secrets, options: options).hooks()
        }
        let runtime = AgentRuntime(environment: env, secrets: secrets, cluster: cluster, hooks: hooks, launchd: launchd, shutdownSignals: [])
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
private func withCluster(_ body: (Daemon, Daemon) async throws -> Void) async throws {
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

@Test func skewAndSpoolStatsReachTheSummary() async throws {
    let store = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let summaryState = RegistryState(store: nil)
    let info = NodeInfo(id: NodeID("n"), version: "1", macOS: "x", hardware: "y")
    try await summaryState.register(info)
    let now = Date()
    _ = await summaryState.heartbeat(Heartbeat(node: NodeID("n"), nodeClock: now.addingTimeInterval(-5), processes: [],
                                               previousRoundTrip: 2, spoolBacklog: 3, spoolDropped: 4),
                                     registeredThisRun: true, now: now)
    let summary = try #require(await summaryState.summaries(now: now).first)
    #expect(abs((summary.clockSkew ?? 0) - 4) < 0.001)
    #expect(summary.spoolBacklog == 3)
    #expect(summary.spoolDropped == 4)
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
