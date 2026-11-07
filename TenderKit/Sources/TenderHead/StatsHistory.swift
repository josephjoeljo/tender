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

    /// How long this tier's points are kept when the whole history is kept for `days`:
    /// minutes for 2 days and quarter hours for 35, or `days` if that's shorter; hours for `days`.
    public func retention(keepingDays days: Int) -> TimeInterval {
        let keep = TimeInterval(days) * 86400
        switch self {
        case .minute: return min(2 * 86400, keep)
        case .quarterHour: return min(35 * 86400, keep)
        case .hour: return keep
        }
    }
}

/// One node's or instance's stats history: every heartbeat for the last hour or so and one
/// merged point per minute for a day, in memory. `record` also hands back each bucket that
/// closes, by tier, for the head to keep on disk for longer.
enum StatsRecorderDefaults {
    /// An hour of heartbeats at the default 5-second interval.
    static let recentCapacity = 720
    /// A day of minutes.
    static let minuteCapacity = 1440
}

typealias NodeStatsRecorder = StatsRecorder<NodeStatsPoint>
typealias ProcessStatsRecorder = StatsRecorder<ProcessStatsPoint>

struct StatsRecorder<Point: StatsSample> {
    private var recent: RingBuffer<Point>
    private var minutes: RingBuffer<Point>
    private var pending: [StatsTier: (bucket: Double, points: [Point])] = [:]

    init(recentCapacity: Int = StatsRecorderDefaults.recentCapacity,
         minuteCapacity: Int = StatsRecorderDefaults.minuteCapacity) {
        recent = RingBuffer(capacity: recentCapacity)
        minutes = RingBuffer(capacity: minuteCapacity)
    }

    /// The buckets this point closed, finest first.
    @discardableResult
    mutating func record(_ point: Point) -> [(tier: StatsTier, point: Point)] {
        recent.append(point)
        var closed: [(tier: StatsTier, point: Point)] = []
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
    private mutating func add(_ point: Point, to tier: StatsTier) -> Point? {
        let bucket = (point.date.timeIntervalSince1970 / tier.bucket).rounded(.down)
        var closed: Point?
        if let open = pending[tier], open.bucket != bucket {
            closed = Point.merged(open.points)
            pending[tier] = nil
        }
        pending[tier, default: (bucket, [])].points.append(point)
        return closed
    }

    /// Minute points from before the raw ones start, then the raw ones, from `since` on.
    func points(since: Date?) -> [Point] {
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

/// An instance on a node, the key of its stats history.
struct ProcessKey: Hashable, Sendable {
    var service: String
    var instance: Int
}
