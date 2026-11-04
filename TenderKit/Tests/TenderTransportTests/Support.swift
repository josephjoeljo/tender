import Distributed
import Foundation
import TenderActorSystem
import TenderCore
import TenderPKI
import TenderProtocol

/// Implements the contract without importing anything but the contract, as TenderAgent does.
distributed actor TestAgent: NodeAgentProtocol {
    typealias ActorSystem = TenderActorSystem
    private var applied: [AgentCommand] = []

    distributed func apply(_ command: AgentCommand) async throws -> ProcessList {
        applied.append(command)
        if case .stop("explode") = command {
            throw NodeCallError(code: "boom", message: "it broke", httpStatus: 418)
        }
        if case .stop("crash") = command { throw CocoaError(.fileNoSuchFile) }
        if case .stop("hang") = command { try await Task.sleep(for: .seconds(60)) }
        return ProcessList(processes: [InstanceStatus(service: "api", instance: 0, node: id.node, state: .running)])
    }

    distributed func status() async throws -> ProcessList { ProcessList(processes: [], orphans: ["on-\(id.node)"]) }
    distributed func releases(service: String) async throws -> ReleaseList { ReleaseList(releases: [], current: service) }
    distributed func rollback(service: String, to sha12: String?) async throws -> ProcessList { ProcessList(processes: []) }
    distributed func adopt(_ request: AdoptRequest) async throws -> ProcessList { ProcessList(processes: []) }
    distributed func forgetAdopted(label: String) async throws -> ProcessList { ProcessList(processes: []) }
    distributed func deploy(service: String, version: String) async throws -> String { version }
    distributed func setSecret(_ name: String, value: Data) async throws {}
    distributed func deleteSecret(_ name: String) async throws {}
    distributed func listSecrets() async throws -> SecretList { SecretList(secrets: []) }
    distributed func specs() async throws -> NodeSpecs { NodeSpecs(node: id.node) }
    distributed func applyManifest(_ request: ApplyRequest) async throws -> ApplyResponse {
        ApplyResponse(diff: ManifestDiff(), dryRun: request.dryRun)
    }
}

distributed actor TestRegistry: HeadRegistryProtocol {
    typealias ActorSystem = TenderActorSystem
    private var beats = 0
    distributed func register(_ node: NodeInfo) async throws {}
    distributed func heartbeat(_ heartbeat: Heartbeat) async throws { beats += 1 }
    distributed func ingest(_ batch: LogBatch) async throws -> UInt64 { batch.records.last?.seq ?? 0 }
    distributed func count() -> Int { beats }
}

struct Cluster {
    let ca: CertificateAuthority
    init() throws { ca = try CertificateAuthority.create() }

    func tls(for node: String, signedBy authority: CertificateAuthority? = nil) throws -> TransportTLS {
        let key = NodeKey.generate()
        let signer = authority ?? ca
        return TransportTLS(
            certificatePEM: try signer.sign(csrPEM: try key.makeCSR(nodeID: NodeID(node)), nodeID: NodeID(node)),
            privateKeyPEM: key.privateKeyPEM,
            trustRootPEM: ca.certificatePEM
        )
    }

    func system(_ node: String, resolver: any NodeResolver = StaticNodeResolver(), verifier: any PeerVerifier = AcceptAllPeers(),
                protocolVersion: Int = TenderVersion.protocolVersion, callTimeout: Duration = .seconds(5)) throws -> TenderActorSystem {
        TenderActorSystem(localNode: NodeID(node), tls: try tls(for: node), resolver: resolver, verifier: verifier,
                          protocolVersion: protocolVersion, callTimeout: callTimeout)
    }
}

func makeAgent(on system: TenderActorSystem) -> TestAgent {
    TenderActorSystem.$wellKnownName.withValue(ActorNames.agent) { TestAgent(actorSystem: system) }
}
