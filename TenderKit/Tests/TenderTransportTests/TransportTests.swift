import Distributed
import Foundation
import Testing
import TenderActorSystem
import TenderCore
import TenderPKI
import TenderProtocol

private func agentRef(_ node: String, using system: TenderActorSystem) throws -> $NodeAgentProtocol<TenderActorSystem> {
    try $NodeAgentProtocol.resolve(id: ActorIdentity(node: NodeID(node), name: ActorNames.agent), using: system)
}

/// Milestone 2 step 1: the go/no-go spike. The contract, the implementation and the
/// caller are separate, and the caller only knows the @Resolvable stub.
@Test func resolvableStubCallsAcrossMutualTLS() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker")
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await worker.shutdown(); await head.shutdown() } }

    let remote = try agentRef("worker", using: head)
    let list = try await remote.apply(.start(ServiceSpec(name: "api", program: .executable("/bin/sleep"))))
    #expect(list.processes.first?.node == NodeID("worker"))
    #expect(try await remote.status().orphans == ["on-worker"])
    #expect(try await remote.releases(service: "svc").current == "svc")
    _ = agent
}

@Test func localActorIsCalledThroughTheSameContract() async throws {
    let cluster = try Cluster()
    let head = try cluster.system("head")
    let agent = makeAgent(on: head)
    let local = try agentRef("head", using: head)
    #expect(try await local.status().orphans == ["on-head"])
    _ = agent
}

@Test func oneConnectionCarriesCallsInBothDirections() async throws {
    let cluster = try Cluster()
    let head = try cluster.system("head")
    let headAgent = makeAgent(on: head)
    let registry = TenderActorSystem.$wellKnownName.withValue(ActorNames.registry) { TestRegistry(actorSystem: head) }
    let port = try await head.listen(host: "127.0.0.1", port: 0)

    // The worker doesn't listen at all, so the head can only use the worker's connection.
    let worker = try cluster.system("worker", resolver: StaticNodeResolver([NodeID("head"): NodeAddress(host: "127.0.0.1", port: port)]))
    let workerAgent = makeAgent(on: worker)
    defer { Task { await worker.shutdown(); await head.shutdown() } }

    let remote = try $HeadRegistryProtocol.resolve(id: ActorIdentity(node: NodeID("head"), name: ActorNames.registry), using: worker)
    try await remote.heartbeat(Heartbeat(node: NodeID("worker"), nodeClock: Date(), processes: []))
    #expect(try await registry.count() == 1)

    let back = try agentRef("worker", using: head)
    #expect(try await back.status().orphans == ["on-worker"])
    _ = (headAgent, workerAgent)
}

@Test func typedErrorsCrossTheWire() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker")
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await worker.shutdown(); await head.shutdown() } }
    let remote = try agentRef("worker", using: head)

    await #expect(throws: NodeCallError(code: "boom", message: "it broke", httpStatus: 418)) {
        try await remote.apply(.stop(service: "explode"))
    }
    do {
        _ = try await remote.apply(.stop(service: "crash"))
        Issue.record("expected an error")
    } catch let error as NodeCallError {
        #expect(error.code == "internal")
    }
    _ = agent
}

@Test func missingActorFails() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker")
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await worker.shutdown(); await head.shutdown() } }
    do {
        _ = try await agentRef("worker", using: head).status()
        Issue.record("expected an error")
    } catch let error as NodeCallError {
        #expect(error.code == "no_such_actor")
    }
}

@Test func slowCallTimesOutAndIsRetryable() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker")
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]),
                                  callTimeout: .milliseconds(200))
    defer { Task { await worker.shutdown(); await head.shutdown() } }
    do {
        _ = try await agentRef("worker", using: head).apply(.stop(service: "hang"))
        Issue.record("expected a timeout")
    } catch let error as TransportError {
        #expect(error == .timedOut(NodeID("worker")))
        #expect(error.isRetryable)
    }
    _ = agent
}

@Test func inFlightCallFailsWhenTheConnectionDrops() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker")
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await worker.shutdown(); await head.shutdown() } }
    let remote = try agentRef("worker", using: head)
    _ = try await remote.status()

    async let call = remote.apply(.stop(service: "hang"))
    try await Task.sleep(for: .milliseconds(100))
    head.disconnect(NodeID("worker"))
    do {
        _ = try await call
        Issue.record("expected a disconnect")
    } catch let error as TransportError {
        #expect(error == .disconnected(NodeID("worker")))
        #expect(error.isRetryable)
    }
    _ = agent
}

@Test func reconnectsLazilyAfterAPeerRestarts() async throws {
    let cluster = try Cluster()
    let tls = try cluster.tls(for: "worker")
    let first = TenderActorSystem(localNode: NodeID("worker"), tls: tls)
    let firstAgent = makeAgent(on: first)
    let port = try await first.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    let remote = try agentRef("worker", using: head)
    _ = try await remote.status()
    _ = firstAgent
    await first.shutdown()
    try await Task.sleep(for: .milliseconds(100))

    // While it's down: retryable.
    do {
        _ = try await remote.status()
        Issue.record("expected a failure")
    } catch let error as TransportError {
        #expect(error.isRetryable)
    }

    let second = TenderActorSystem(localNode: NodeID("worker"), tls: tls)
    let secondAgent = makeAgent(on: second)
    try await second.listen(host: "127.0.0.1", port: port)
    #expect(try await remote.status().orphans == ["on-worker"])
    #expect(head.isConnected(to: NodeID("worker")))
    _ = secondAgent
    await second.shutdown()
    await head.shutdown()
}

@Test func threeNodesTalkToEachOther() async throws {
    let cluster = try Cluster()
    let a = try cluster.system("a")
    let b = try cluster.system("b")
    let portA = try await a.listen(host: "127.0.0.1", port: 0)
    let portB = try await b.listen(host: "127.0.0.1", port: 0)
    let resolver = StaticNodeResolver([NodeID("a"): NodeAddress(host: "127.0.0.1", port: portA),
                                       NodeID("b"): NodeAddress(host: "127.0.0.1", port: portB)])
    let c = try cluster.system("c", resolver: resolver)
    let agents = (makeAgent(on: a), makeAgent(on: b))
    defer { Task { await a.shutdown(); await b.shutdown(); await c.shutdown() } }

    async let fromA = agentRef("a", using: c).status()
    async let fromB = agentRef("b", using: c).status()
    #expect(try await fromA.orphans == ["on-a"])
    #expect(try await fromB.orphans == ["on-b"])
    // Many concurrent calls share the connection, matched by call ID.
    let remote = try agentRef("a", using: c)
    try await withThrowingTaskGroup(of: String?.self) { group in
        for index in 0..<50 {
            group.addTask { try await remote.releases(service: "s\(index)").current }
        }
        var seen = Set<String>()
        for try await value in group { seen.insert(value ?? "") }
        #expect(seen.count == 50)
    }
    _ = agents
}

// MARK: Rejections

@Test func versionMismatchIsRejectedWithAClearError() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker", protocolVersion: 2)
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]),
                                  protocolVersion: 1)
    defer { Task { await worker.shutdown(); await head.shutdown() } }
    do {
        _ = try await agentRef("worker", using: head).status()
        Issue.record("expected a rejection")
    } catch let error as TransportError {
        guard case .handshakeRejected(let reason) = error else { throw error }
        #expect(reason.contains("protocol version mismatch"))
        #expect(!error.isRetryable)
    }
    _ = agent
}

private struct RejectingVerifier: PeerVerifier {
    func verify(certificateNode: NodeID, remoteIP: String?) async throws {
        #expect(remoteIP == "127.0.0.1")
        throw NodeCallError(code: "nope", message: "revoked: \(certificateNode)")
    }
}

@Test func verifierCanRejectAValidCertificate() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker", verifier: RejectingVerifier())
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await worker.shutdown(); await head.shutdown() } }
    do {
        _ = try await agentRef("worker", using: head).status()
        Issue.record("expected a rejection")
    } catch let error as TransportError {
        #expect(error.description.contains("revoked: head"))
    }
    _ = agent
}

@Test func certificateFromAnotherCAIsRefused() async throws {
    let cluster = try Cluster()
    let other = try CertificateAuthority.create()
    let worker = try cluster.system("worker")
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    let intruder = TenderActorSystem(
        localNode: NodeID("head"),
        tls: TransportTLS(certificatePEM: try cluster.tls(for: "head", signedBy: other).certificatePEM,
                          privateKeyPEM: "", trustRootPEM: cluster.ca.certificatePEM),
        resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await worker.shutdown() } }
    await #expect(throws: (any Error).self) { _ = try await agentRef("worker", using: intruder).status() }

    let key = NodeKey.generate()
    let intruder2 = TenderActorSystem(
        localNode: NodeID("head"),
        tls: TransportTLS(certificatePEM: try other.sign(csrPEM: try key.makeCSR(nodeID: NodeID("head")), nodeID: NodeID("head")),
                          privateKeyPEM: key.privateKeyPEM, trustRootPEM: cluster.ca.certificatePEM),
        resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    await #expect(throws: (any Error).self) { _ = try await agentRef("worker", using: intruder2).status() }
    #expect(!worker.isConnected(to: NodeID("head")))
    _ = agent
}

@Test func peerClaimingAnotherNameThanItsCertificateIsRefused() async throws {
    let cluster = try Cluster()
    let worker = try cluster.system("worker")
    let agent = makeAgent(on: worker)
    let port = try await worker.listen(host: "127.0.0.1", port: 0)
    // Valid certificate for "mallory", but it introduces itself as "head".
    let impostor = TenderActorSystem(
        localNode: NodeID("head"), tls: try cluster.tls(for: "mallory"),
        resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await worker.shutdown(); await impostor.shutdown() } }
    do {
        _ = try await agentRef("worker", using: impostor).status()
        Issue.record("expected a rejection")
    } catch let error as TransportError {
        #expect(error.description.contains("certificate is for 'mallory'"))
    }
    _ = agent
}

@Test func dialerRefusesAPeerWithTheWrongCertificate() async throws {
    let cluster = try Cluster()
    // Answers on the worker's address, with a valid certificate for another node.
    let other = try cluster.system("other")
    let agent = makeAgent(on: other)
    let port = try await other.listen(host: "127.0.0.1", port: 0)
    let head = try cluster.system("head", resolver: StaticNodeResolver([NodeID("worker"): NodeAddress(host: "127.0.0.1", port: port)]))
    defer { Task { await other.shutdown(); await head.shutdown() } }
    do {
        _ = try await agentRef("worker", using: head).status()
        Issue.record("expected a rejection")
    } catch let error as TransportError {
        #expect(error.description.contains("expected node 'worker'"))
    }
    _ = agent
}

@Test func unknownNodeIsARetryableFailure() async throws {
    let cluster = try Cluster()
    let head = try cluster.system("head")
    do {
        _ = try await agentRef("ghost", using: head).status()
        Issue.record("expected a failure")
    } catch let error as TransportError {
        #expect(error == .unreachable(NodeID("ghost"), "address unknown"))
    }
}
