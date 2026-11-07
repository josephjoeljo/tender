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
        var secretFetchErrors = 0
        var stats: NodeStats?
        var history = NodeStatsRecorder()
        /// Instances in the latest heartbeat; one that stops being reported is dropped, and
        /// only what's on disk is left of it.
        var processHistory: [ProcessKey: ProcessStatsRecorder] = [:]
    }

    public static func skew(now: Date, nodeClock: Date, roundTrip: TimeInterval?) -> TimeInterval {
        now.timeIntervalSince(nodeClock) - (roundTrip ?? 0) / 2
    }

    public static let nodeDownAfter: TimeInterval = 20

    private var entries: [NodeID: Entry] = [:]
    private let store: HeadStore?
    public private(set) var retention: HistoryRetention
    private let downAfter: TimeInterval

    /// Last-known nodes are loaded as down, until they report in.
    public init(store: HeadStore?, downAfter: TimeInterval = RegistryState.nodeDownAfter) {
        self.store = store
        self.downAfter = downAfter
        var loaded: [NodeID: Entry] = [:]
        for info in (try? store?.nodes()) ?? [] { loaded[info.id] = Entry(info: info) }
        entries = loaded
        retention = (try? store?.historyRetention()) ?? HistoryRetention()
    }

    /// Saves the change and prunes right away, so a shorter retention frees space now.
    public func setRetention(_ update: HistoryRetentionUpdate, now: Date = Date()) throws -> HistoryRetention {
        var changed = retention
        if let days = update.nodeDays { changed.nodeDays = days }
        if let days = update.processDays { changed.processDays = days }
        guard changed.isValid else {
            throw NodeCallError(code: "invalid_retention",
                                message: "Retention must be \(HistoryRetention.allowedDays.lowerBound) to \(HistoryRetention.allowedDays.upperBound) days.",
                                httpStatus: 400)
        }
        try store?.saveHistoryRetention(changed)
        retention = changed
        for node in entries.keys {
            try? store?.pruneStats(node: node, keepingDays: changed.nodeDays, now: now)
            try? store?.pruneProcessStats(node: node, keepingDays: changed.processDays, now: now)
        }
        return changed
    }

    /// The node with this ID, else the only one with this hostname.
    public func resolve(_ reference: String) -> NodeID? {
        if entries[NodeID(reference)] != nil { return NodeID(reference) }
        let named = entries.values.filter { $0.info.hostname?.lowercased() == reference.lowercased() }
        return named.count == 1 ? named[0].info.id : nil
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
        let gap = entry.lastHeartbeat.map { now.timeIntervalSince($0) }
        entry.lastHeartbeat = now
        entry.processes = heartbeat.processes
        entry.orphans = heartbeat.orphans
        entry.skew = Self.skew(now: now, nodeClock: heartbeat.nodeClock, roundTrip: heartbeat.previousRoundTrip)
        let closed = entry.history.record(NodeStatsPoint(heartbeat, skew: entry.skew, gap: gap, at: now))
        save(closed, node: heartbeat.node, now: now)
        var processHistory: [ProcessKey: ProcessStatsRecorder] = [:]
        var processClosed: [HeadStore.ClosedProcessPoint] = []
        for status in heartbeat.processes {
            let key = ProcessKey(service: status.service, instance: status.instance)
            var recorder = entry.processHistory[key] ?? ProcessStatsRecorder()
            for (tier, point) in recorder.record(ProcessStatsPoint(status, at: now)) {
                processClosed.append(.init(service: key.service, instance: key.instance, tier: tier, point: point))
            }
            processHistory[key] = recorder
        }
        entry.processHistory = processHistory
        save(processClosed, prune: closed.contains { $0.tier == .hour }, node: heartbeat.node, now: now)
        entry.spoolBacklog = heartbeat.spoolBacklog
        entry.spoolDropped = heartbeat.spoolDropped
        entry.secretFetchErrors = heartbeat.secretFetchErrors
        entry.stats = heartbeat.stats
        entries[heartbeat.node] = entry
        return true
    }

    public func remove(_ node: NodeID) {
        entries[node] = nil
        try? store?.deleteStats(node: node)
    }

    /// History is a convenience: a failed write loses a point, never a heartbeat.
    private func save(_ closed: [(tier: StatsTier, point: NodeStatsPoint)], node: NodeID, now: Date) {
        guard let store, !closed.isEmpty else { return }
        for (tier, point) in closed { try? store.saveStats(node: node, tier: tier, point: point) }
        if closed.contains(where: { $0.tier == .hour }) {
            try? store.pruneStats(node: node, keepingDays: retention.nodeDays, now: now)
        }
    }

    private func save(_ closed: [HeadStore.ClosedProcessPoint], prune: Bool, node: NodeID, now: Date) {
        guard let store else { return }
        try? store.saveProcessStats(node: node, closed)
        if prune { try? store.pruneProcessStats(node: node, keepingDays: retention.processDays, now: now) }
    }

    public func knows(_ node: NodeID) -> Bool { entries[node] != nil }

    /// Nil for a node the head doesn't know.
    public func history(of node: NodeID, since: Date?, limit: Int, now: Date = Date()) -> NodeStatsHistory? {
        guard let entry = entries[node] else { return nil }
        let since = Self.clamp(since, keepingDays: retention.nodeDays, now: now)
        let fetch = since.fetch
        let points = stitched(entry.history.points(since: fetch), since: fetch) { tier in
            try store?.stats(node: node, tier: tier, since: fetch)
        }
        let (sampled, downsampled) = Self.limited(points, to: limit, since: since.requested)
        return NodeStatsHistory(node: node, points: sampled, downsampled: downsampled)
    }

    /// Nil for a node the head doesn't know. An instance it has never seen has no points.
    public func history(of node: NodeID, service: String, instance: Int, since: Date?,
                        limit: Int, now: Date = Date()) -> ProcessStatsHistory? {
        guard let entry = entries[node] else { return nil }
        let since = Self.clamp(since, keepingDays: retention.processDays, now: now)
        let fetch = since.fetch
        let memory = entry.processHistory[ProcessKey(service: service, instance: instance)]?.points(since: fetch) ?? []
        let points = stitched(memory, since: fetch) { tier in
            try store?.processStats(node: node, service: service, instance: instance, tier: tier, since: fetch)
        }
        let (sampled, downsampled) = Self.limited(points, to: limit, since: since.requested)
        return ProcessStatsHistory(node: node, service: service, instance: instance, points: sampled,
                                   downsampled: downsampled)
    }

    /// Instances of a service the node reported in its latest heartbeat.
    public func instances(of service: String, on node: NodeID) -> [Int] {
        (entries[node]?.processes ?? []).filter { $0.service == service }.map(\.instance).sorted()
    }

    /// Nothing from before the retention is fetched, even if it hasn't been pruned yet. The
    /// requested start (clamped too) sets the downsampling span; none means from the first point.
    private static func clamp(_ since: Date?, keepingDays days: Int,
                              now: Date) -> (fetch: Date, requested: Date?) {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86400)
        return (max(since ?? cutoff, cutoff), since.map { max($0, cutoff) })
    }

    private static func limited<Point: StatsSample>(_ points: [Point], to limit: Int,
                                                    since: Date?) -> (points: [Point], downsampled: Bool) {
        guard let first = points.first, let last = points.last else { return ([], false) }
        let span = min(since ?? first.date, first.date)...max(last.date, first.date)
        return (Point.downsampled(points, to: limit, over: span), points.count > limit)
    }

    /// The finest points that cover each stretch: stored hours, then quarter hours, then
    /// minutes, each up to where the next finer one starts, then what's in memory.
    private func stitched<Point: StatsSample>(_ memory: [Point], since: Date?,
                                              stored: (StatsTier) throws -> [Point]?) -> [Point] {
        guard store != nil else { return memory }
        var points = memory
        var start = memory.first?.date ?? .distantFuture
        for tier in [StatsTier.minute, .quarterHour, .hour] {
            let older = ((try? stored(tier)) ?? []).filter { $0.date < start }
            guard let first = older.first else { continue }
            points = older + points
            start = first.date
        }
        return points
    }

    public func isUp(_ node: NodeID, now: Date = Date()) -> Bool {
        guard let last = entries[node]?.lastHeartbeat else { return false }
        return now.timeIntervalSince(last) < downAfter
    }

    /// From the latest heartbeats, so a scrape never waits on a node.
    public func allProcesses() -> [InstanceStatus] {
        entries.values.flatMap(\.processes)
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
                spoolDropped: entry.spoolDropped,
                secretFetchErrors: entry.secretFetchErrors,
                stats: entry.stats
            )
        }.headFirst()
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
