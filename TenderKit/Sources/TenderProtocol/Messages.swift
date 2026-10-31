import Distributed
import Foundation
import TenderCore

// The node contract: Codable messages plus @Resolvable distributed protocols,
// generic over DistributedActorSystem<any Codable>. No transport dependency.
//
// Never change or remove a shipped `distributed func`: calls are matched by mangled
// name. Add a new one instead. See docs/DESIGN.md §4.

public enum AgentCommand: Codable, Sendable, Equatable {
    case start(ServiceSpec)
    case startExisting(service: String)
    case stop(service: String)
    case restart(service: String)
    case delete(service: String)
    case collectGarbage
}

public enum AgentEvent: Codable, Sendable {
    case heartbeat(node: NodeID)
    case status([InstanceStatus])
}

public struct Heartbeat: Codable, Sendable, Equatable {
    public var node: NodeID
    /// The worker's wall clock when this was sent.
    public var nodeClock: Date
    public var processes: [InstanceStatus]
    public var orphans: [String]
    /// How long the previous heartbeat took, for estimating clock skew.
    public var previousRoundTrip: TimeInterval?
    public var spoolBacklog: Int
    public var spoolDropped: Int

    public init(node: NodeID, nodeClock: Date, processes: [InstanceStatus], orphans: [String] = [],
                previousRoundTrip: TimeInterval? = nil, spoolBacklog: Int = 0, spoolDropped: Int = 0) {
        self.previousRoundTrip = previousRoundTrip
        self.spoolBacklog = spoolBacklog
        self.spoolDropped = spoolDropped
        self.node = node
        self.nodeClock = nodeClock
        self.processes = processes
        self.orphans = orphans
    }
}

public enum ActorNames {
    public static let agent = "agent"
    public static let registry = "registry"
}

/// What the head (or any node) can ask a node to do.
@Resolvable
public protocol NodeAgentProtocol: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
    distributed func apply(_ command: AgentCommand) async throws -> ProcessList
    distributed func status() async throws -> ProcessList
    distributed func releases(service: String) async throws -> ReleaseList
    distributed func rollback(service: String, to sha12: String?) async throws -> ProcessList
    distributed func adopt(_ request: AdoptRequest) async throws -> ProcessList
    distributed func forgetAdopted(label: String) async throws -> ProcessList
}

/// What a worker tells the head.
@Resolvable
public protocol HeadRegistryProtocol: DistributedActor where ActorSystem: DistributedActorSystem<any Codable> {
    distributed func register(_ node: NodeInfo) async throws
    distributed func heartbeat(_ heartbeat: Heartbeat) async throws
    /// Stores log lines and returns the highest sequence number that's safe to prune.
    distributed func ingest(_ batch: LogBatch) async throws -> UInt64
}
