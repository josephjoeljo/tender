import Foundation

/// One heartbeat's worth of a node's stats as the head recorded it, or several merged
/// into one when the history is downsampled.
public struct NodeStatsPoint: Codable, Sendable, Equatable {
    /// The head's clock when the heartbeat arrived (the last one, for a merged point).
    public var date: Date
    public var cpuPercent: Double?
    public var memoryUsed: Double?
    public var memoryTotal: Double?
    public var gpuPercent: Double?
    public var networkInRate: Double?
    public var networkOutRate: Double?
    public var diskReadRate: Double?
    public var diskWriteRate: Double?
    /// `PowerStats.total`, in watts.
    public var power: Double?
    /// Seconds since the heartbeat before this one: how old the node's last report got
    /// before this one arrived. Nil for the first heartbeat since the head started.
    public var heartbeatGap: TimeInterval?
    public var clockSkew: TimeInterval?
    public var spoolBacklog: Int
    public var instanceCount: Int
    public var crashedCount: Int

    public init(date: Date, cpuPercent: Double? = nil, memoryUsed: Double? = nil, memoryTotal: Double? = nil,
                gpuPercent: Double? = nil, networkInRate: Double? = nil, networkOutRate: Double? = nil,
                diskReadRate: Double? = nil, diskWriteRate: Double? = nil, power: Double? = nil,
                heartbeatGap: TimeInterval? = nil, clockSkew: TimeInterval? = nil,
                spoolBacklog: Int = 0, instanceCount: Int = 0, crashedCount: Int = 0) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.gpuPercent = gpuPercent
        self.networkInRate = networkInRate
        self.networkOutRate = networkOutRate
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.power = power
        self.heartbeatGap = heartbeatGap
        self.clockSkew = clockSkew
        self.spoolBacklog = spoolBacklog
        self.instanceCount = instanceCount
        self.crashedCount = crashedCount
    }

    /// One point standing for several, oldest first. Usage and rates are averaged; the
    /// heartbeat gap, backlog and crashes keep their worst value so a spike isn't smoothed
    /// away; totals and the instance count are the latest.
    public static func merged(_ points: some BidirectionalCollection<NodeStatsPoint>) -> NodeStatsPoint? {
        guard let last = points.last else { return nil }
        func mean(_ value: KeyPath<NodeStatsPoint, Double?>) -> Double? {
            let values = points.compactMap { $0[keyPath: value] }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return NodeStatsPoint(
            date: last.date,
            cpuPercent: mean(\.cpuPercent),
            memoryUsed: mean(\.memoryUsed),
            memoryTotal: last.memoryTotal,
            gpuPercent: mean(\.gpuPercent),
            networkInRate: mean(\.networkInRate),
            networkOutRate: mean(\.networkOutRate),
            diskReadRate: mean(\.diskReadRate),
            diskWriteRate: mean(\.diskWriteRate),
            power: mean(\.power),
            heartbeatGap: points.compactMap(\.heartbeatGap).max(),
            clockSkew: mean(\.clockSkew),
            spoolBacklog: points.map(\.spoolBacklog).max() ?? 0,
            instanceCount: last.instanceCount,
            crashedCount: points.map(\.crashedCount).max() ?? 0
        )
    }

    /// At most `limit` points, merging runs of neighbours evenly. Oldest first in and out.
    public static func downsampled(_ points: [NodeStatsPoint], to limit: Int) -> [NodeStatsPoint] {
        guard limit > 0 else { return [] }
        guard points.count > limit else { return points }
        let size = (points.count + limit - 1) / limit
        return stride(from: 0, to: points.count, by: size).compactMap {
            merged(points[$0..<min($0 + size, points.count)])
        }
    }
}

extension NodeStatsPoint {
    /// At most `limit` points, merging those in equal slices of time. Unlike
    /// `downsampled(_:to:)`, a stretch with many fine points doesn't crowd out a longer one
    /// with fewer coarse points. Oldest first in and out.
    public static func downsampled(_ points: [NodeStatsPoint], to limit: Int, over span: ClosedRange<Date>) -> [NodeStatsPoint] {
        guard limit > 0 else { return [] }
        guard points.count > limit else { return points }
        let slice = max(span.upperBound.timeIntervalSince(span.lowerBound) / Double(limit), 1)
        var result: [NodeStatsPoint] = []
        var run: [NodeStatsPoint] = []
        var runSlice: Double?
        for point in points {
            // The newest point would start a slice of its own; it belongs to the last one.
            let index = min((point.date.timeIntervalSince(span.lowerBound) / slice).rounded(.down), Double(limit - 1))
            if let runSlice, runSlice != index, let merged = merged(run) {
                result.append(merged)
                run = []
            }
            runSlice = index
            run.append(point)
        }
        if let merged = merged(run) { result.append(merged) }
        return result
    }
}

/// A node's stats, from `GET /v1/nodes/:id/history`: the last hour from memory, older
/// stretches from the head's database at coarser resolutions, up to about 6 months.
public struct NodeStatsHistory: Codable, Sendable, Equatable {
    public var node: NodeID
    /// Oldest first.
    public var points: [NodeStatsPoint]
    /// True when there were more points than the limit and neighbours were merged.
    public var downsampled: Bool

    public init(node: NodeID, points: [NodeStatsPoint], downsampled: Bool = false) {
        self.node = node
        self.points = points
        self.downsampled = downsampled
    }

    /// Points per response, when the request doesn't say.
    public static let defaultLimit = 720
    public static let maxLimit = 2000
}
