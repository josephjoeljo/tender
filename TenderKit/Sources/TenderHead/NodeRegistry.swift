import Distributed
import Foundation
import TenderActorSystem
import TenderCore
import TenderLogStore
import TenderProtocol

/// The head's view of the cluster: a cache rebuilt from what workers report.
public actor RegistryState {
    struct Entry {
        var info: NodeInfo
        var lastHeartbeat: Date?
        var processes: [InstanceStatus] = []
        var orphans: [String] = []
        var skew: TimeInterval?
        var spoolBacklog = 0
        var spoolDropped = 0
    }

    public static func skew(now: Date, nodeClock: Date, roundTrip: TimeInterval?) -> TimeInterval {
        now.timeIntervalSince(nodeClock) - (roundTrip ?? 0) / 2
    }

    public static let nodeDownAfter: TimeInterval = 20

    private var entries: [NodeID: Entry] = [:]
    private let store: HeadStore?
    private let downAfter: TimeInterval

    /// Last-known nodes are loaded as down, until they report in.
    public init(store: HeadStore?, downAfter: TimeInterval = RegistryState.nodeDownAfter) {
        self.store = store
        self.downAfter = downAfter
        var loaded: [NodeID: Entry] = [:]
        for info in (try? store?.nodes()) ?? [] { loaded[info.id] = Entry(info: info) }
        entries = loaded
    }

    public func register(_ info: NodeInfo) throws {
        var entry = entries[info.id] ?? Entry(info: info)
        entry.info = info
        entries[info.id] = entry
        try store?.saveNode(info)
    }

    /// False for a node that hasn't registered with this head process, which
    /// tells it to register again. That's how the registry rebuilds after a restart.
    public func heartbeat(_ heartbeat: Heartbeat, registeredThisRun: Bool, now: Date = Date()) -> Bool {
        guard registeredThisRun, var entry = entries[heartbeat.node] else { return false }
        entry.lastHeartbeat = now
        entry.processes = heartbeat.processes
        entry.orphans = heartbeat.orphans
        entry.skew = Self.skew(now: now, nodeClock: heartbeat.nodeClock, roundTrip: heartbeat.previousRoundTrip)
        entry.spoolBacklog = heartbeat.spoolBacklog
        entry.spoolDropped = heartbeat.spoolDropped
        entries[heartbeat.node] = entry
        return true
    }

    public func remove(_ node: NodeID) { entries[node] = nil }

    public func isUp(_ node: NodeID, now: Date = Date()) -> Bool {
        guard let last = entries[node]?.lastHeartbeat else { return false }
        return now.timeIntervalSince(last) < downAfter
    }

    public func address(of node: NodeID) -> String? { entries[node]?.info.address }

    public func summaries(now: Date = Date()) -> [NodeSummary] {
        entries.values.map { entry in
            NodeSummary(
                info: entry.info,
                up: entry.lastHeartbeat.map { now.timeIntervalSince($0) < downAfter } ?? false,
                lastHeartbeatAge: entry.lastHeartbeat.map { now.timeIntervalSince($0) },
                instanceCount: entry.processes.count,
                crashedCount: entry.processes.filter { $0.state == .crashed }.count,
                clockSkew: entry.skew,
                spoolBacklog: entry.spoolBacklog,
                spoolDropped: entry.spoolDropped
            )
        }.sorted { $0.info.id.rawValue < $1.info.id.rawValue }
    }

    public func upNodes(now: Date = Date()) -> [NodeID] {
        entries.filter { isUpEntry($0.value, now: now) }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    private func isUpEntry(_ entry: Entry, now: Date) -> Bool {
        entry.lastHeartbeat.map { now.timeIntervalSince($0) < downAfter } ?? false
    }

    /// Up nodes reporting this service.
    public func nodes(running service: String, now: Date = Date()) -> [NodeID] {
        entries.filter { isUpEntry($0.value, now: now) && $0.value.processes.contains { $0.service == service } }
            .map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    /// Nodes known but not up: `tender list` has to say their processes are unknown.
    public func downNodes(now: Date = Date()) -> [NodeID] {
        entries.filter { !isUpEntry($0.value, now: now) }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }
}

/// Dials nodes at the address they registered.
public struct RegistryResolver: NodeResolver {
    let state: RegistryState
    let defaultPort: Int

    public init(state: RegistryState, defaultPort: Int = 7070) {
        self.state = state
        self.defaultPort = defaultPort
    }

    public func address(of node: NodeID) async throws -> NodeAddress? {
        guard let address = await state.address(of: node), let colon = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: colon)...]) else { return nil }
        return NodeAddress(host: String(address[..<colon]), port: port)
    }
}

/// Refuses revoked nodes at the handshake.
public struct RevocationVerifier: PeerVerifier {
    let store: HeadStore
    public init(store: HeadStore) { self.store = store }

    public func verify(certificateNode: NodeID, remoteIP: String?) async throws {
        if try store.isRevoked(node: certificateNode) {
            throw NodeCallError(code: "node_revoked", message: "Node '\(certificateNode)' has been revoked.", httpStatus: 403)
        }
    }
}

/// The contract workers call. A node can only speak for itself: the caller's name comes
/// from its verified connection, not from anything in the message.
distributed actor HeadRegistry: HeadRegistryProtocol {
    typealias ActorSystem = TenderActorSystem
    private let state: RegistryState
    private let logs: LogStore
    private var registered: Set<NodeID> = []

    init(state: RegistryState, logs: LogStore, actorSystem: TenderActorSystem) {
        self.state = state
        self.logs = logs
        self.actorSystem = actorSystem
    }

    private func requireCaller(is node: NodeID) throws {
        guard TenderActorSystem.currentCaller == node else {
            throw NodeCallError(code: "wrong_node",
                                message: "'\(TenderActorSystem.currentCaller?.rawValue ?? "?")' can't speak for '\(node)'.",
                                httpStatus: 403)
        }
    }

    distributed func register(_ node: NodeInfo) async throws {
        try requireCaller(is: node.id)
        try await state.register(node)
        registered.insert(node.id)
    }

    distributed func ingest(_ batch: LogBatch) async throws -> UInt64 {
        try requireCaller(is: batch.node)
        return try await logs.ingest(batch)
    }

    distributed func heartbeat(_ heartbeat: Heartbeat) async throws {
        try requireCaller(is: heartbeat.node)
        guard await state.heartbeat(heartbeat, registeredThisRun: registered.contains(heartbeat.node)) else {
            throw NodeCallError(code: "not_registered", message: "Register first.", httpStatus: 409)
        }
    }
}
