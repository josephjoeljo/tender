import Foundation
import TenderCore
import TenderProtocol

/// A fixed-capacity FIFO: appending past capacity overwrites the oldest element.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Oldest first.
    var elements: [Element] { Array(storage[head...] + storage[..<head]) }
    var first: Element? { isEmpty ? nil : storage[head] }
}

/// How finely the head stores a node's stats history in `head.db`, and for how long.
/// Each tier is built from closed 1-minute buckets, so a restart loses at most the
/// buckets that were still open.
public enum StatsTier: Int, CaseIterable, Sendable {
    case minute = 1, quarterHour = 2, hour = 3

    public var bucket: TimeInterval {
        switch self {
        case .minute: 60
        case .quarterHour: 15 * 60
        case .hour: 3600
        }
    }

    /// A little past the longest window the app offers for each resolution: 24 hours,
    /// 7 and 30 days, 6 months.
    public var retention: TimeInterval {
        switch self {
        case .minute: 2 * 86400
        case .quarterHour: 35 * 86400
        case .hour: 190 * 86400
        }
    }
}

/// One node's stats history: every heartbeat for the last hour or so and one merged point
/// per minute for a day, in memory. `record` also hands back each bucket that closes, by
/// tier, for the head to keep on disk for longer.
struct NodeStatsRecorder {
    /// An hour of heartbeats at the default 5-second interval.
    static let recentCapacity = 720
    /// A day of minutes.
    static let minuteCapacity = 1440

    private var recent: RingBuffer<NodeStatsPoint>
    private var minutes: RingBuffer<NodeStatsPoint>
    private var pending: [StatsTier: (bucket: Double, points: [NodeStatsPoint])] = [:]

    init(recentCapacity: Int = Self.recentCapacity, minuteCapacity: Int = Self.minuteCapacity) {
        recent = RingBuffer(capacity: recentCapacity)
        minutes = RingBuffer(capacity: minuteCapacity)
    }

    /// The buckets this point closed, finest first.
    @discardableResult
    mutating func record(_ point: NodeStatsPoint) -> [(tier: StatsTier, point: NodeStatsPoint)] {
        recent.append(point)
        var closed: [(tier: StatsTier, point: NodeStatsPoint)] = []
        guard let minute = add(point, to: .minute) else { return closed }
        minutes.append(minute)
        closed.append((.minute, minute))
        // Coarser tiers merge whole minutes, keyed by the minute's own time.
        for tier in [StatsTier.quarterHour, .hour] {
            if let merged = add(minute, to: tier) { closed.append((tier, merged)) }
        }
        return closed
    }

    /// Adds a point to the tier's open bucket; the merged bucket it closed, if any.
    private mutating func add(_ point: NodeStatsPoint, to tier: StatsTier) -> NodeStatsPoint? {
        let bucket = (point.date.timeIntervalSince1970 / tier.bucket).rounded(.down)
        var closed: NodeStatsPoint?
        if let open = pending[tier], open.bucket != bucket {
            closed = NodeStatsPoint.merged(open.points)
            pending[tier] = nil
        }
        pending[tier, default: (bucket, [])].points.append(point)
        return closed
    }

    /// Minute points from before the raw ones start, then the raw ones, from `since` on.
    func points(since: Date?) -> [NodeStatsPoint] {
        let raw = recent.elements
        let rawStart = raw.first?.date ?? .distantFuture
        let all = minutes.elements.filter { $0.date < rawStart } + raw
        guard let since else { return all }
        return all.filter { $0.date >= since }
    }
}

extension NodeStatsPoint {
    init(_ heartbeat: Heartbeat, skew: TimeInterval?, gap: TimeInterval?, at date: Date) {
        let stats = heartbeat.stats
        self.init(date: date,
                  cpuPercent: stats?.cpuPercent,
                  memoryUsed: stats?.memoryUsed.map { Double($0) },
                  memoryTotal: stats.map { Double($0.memoryTotal) },
                  gpuPercent: stats?.gpuPercent,
                  networkInRate: stats?.networkInRate,
                  networkOutRate: stats?.networkOutRate,
                  diskReadRate: stats?.diskReadRate,
                  diskWriteRate: stats?.diskWriteRate,
                  power: stats?.power?.total,
                  heartbeatGap: gap,
                  clockSkew: skew,
                  spoolBacklog: heartbeat.spoolBacklog,
                  instanceCount: heartbeat.processes.count,
                  crashedCount: heartbeat.processes.filter { $0.state == .crashed }.count)
    }
}
