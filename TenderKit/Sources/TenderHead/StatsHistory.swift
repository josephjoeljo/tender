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

/// One node's stats history, in memory: every heartbeat for the last hour or so, and
/// one merged point per minute for a day. The head is cheap to lose, and so is this.
struct NodeStatsRecorder {
    /// An hour of heartbeats at the default 5-second interval.
    static let recentCapacity = 720
    /// A day of minutes.
    static let minuteCapacity = 1440
    static let bucket: TimeInterval = 60

    private var recent: RingBuffer<NodeStatsPoint>
    private var minutes: RingBuffer<NodeStatsPoint>
    private var pending: [NodeStatsPoint] = []
    private var pendingBucket: Double?

    init(recentCapacity: Int = Self.recentCapacity, minuteCapacity: Int = Self.minuteCapacity) {
        recent = RingBuffer(capacity: recentCapacity)
        minutes = RingBuffer(capacity: minuteCapacity)
    }

    mutating func record(_ point: NodeStatsPoint) {
        recent.append(point)
        let bucket = (point.date.timeIntervalSince1970 / Self.bucket).rounded(.down)
        if let pendingBucket, pendingBucket != bucket { flush() }
        pendingBucket = bucket
        pending.append(point)
    }

    private mutating func flush() {
        if let merged = NodeStatsPoint.merged(pending) { minutes.append(merged) }
        pending = []
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
