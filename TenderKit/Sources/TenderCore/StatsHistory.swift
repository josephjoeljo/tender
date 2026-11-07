import Foundation

/// A point in a stats history that several can be merged into, for coarser tiers and
/// for downsampling a response.
public protocol StatsSample: Sendable {
    /// The head's clock when the heartbeat arrived (the last one, for a merged point).
    var date: Date { get }
    /// One point standing for several, oldest first; nil for none.
    static func merged(_ points: some BidirectionalCollection<Self>) -> Self?
}

extension StatsSample {
    /// At most `limit` points, merging runs of neighbours evenly. Oldest first in and out.
    public static func downsampled(_ points: [Self], to limit: Int) -> [Self] {
        guard limit > 0 else { return [] }
        guard points.count > limit else { return points }
        let size = (points.count + limit - 1) / limit
        return stride(from: 0, to: points.count, by: size).compactMap {
            merged(points[$0..<min($0 + size, points.count)])
        }
    }

    /// At most `limit` points, merging those in equal slices of time. Unlike
    /// `downsampled(_:to:)`, a stretch with many fine points doesn't crowd out a longer one
    /// with fewer coarse points. Oldest first in and out.
    public static func downsampled(_ points: [Self], to limit: Int, over span: ClosedRange<Date>) -> [Self] {
        guard limit > 0 else { return [] }
        guard points.count > limit else { return points }
        let slice = max(span.upperBound.timeIntervalSince(span.lowerBound) / Double(limit), 1)
        var result: [Self] = []
        var run: [Self] = []
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

/// One heartbeat's worth of a node's stats as the head recorded it, or several merged
/// into one when the history is downsampled.
public struct NodeStatsPoint: StatsSample, Codable, Sendable, Equatable {
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

/// One instance's resource use at one heartbeat, or merged over a bucket. Keyed by node,
/// service and instance, never by PID, so a restart continues the same series.
public struct ProcessStatsPoint: StatsSample, Codable, Sendable, Equatable {
    public var date: Date
    /// Percent of one core.
    public var cpuPercent: Double?
    /// Physical footprint in bytes, else RSS from an older tenderd.
    public var memory: Double?
    public var gpuPercent: Double?
    /// Bytes per second.
    public var diskReadRate: Double?
    public var diskWriteRate: Double?
    /// Watts.
    public var power: Double?
    public var openFiles: Double?
    public var threads: Double?
    /// launchd runs since the job was loaded, minus the first one; the latest when merged.
    public var restarts: Int
    /// True when the instance had no running process at any heartbeat in the point.
    public var down: Bool

    public init(date: Date, cpuPercent: Double? = nil, memory: Double? = nil, gpuPercent: Double? = nil,
                diskReadRate: Double? = nil, diskWriteRate: Double? = nil, power: Double? = nil,
                openFiles: Double? = nil, threads: Double? = nil, restarts: Int = 0, down: Bool = false) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.gpuPercent = gpuPercent
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.power = power
        self.openFiles = openFiles
        self.threads = threads
        self.restarts = restarts
        self.down = down
    }

    /// Usage and rates are averaged; restarts are the latest; `down` if any point was.
    public static func merged(_ points: some BidirectionalCollection<ProcessStatsPoint>) -> ProcessStatsPoint? {
        guard let last = points.last else { return nil }
        func mean(_ value: KeyPath<ProcessStatsPoint, Double?>) -> Double? {
            let values = points.compactMap { $0[keyPath: value] }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return ProcessStatsPoint(
            date: last.date,
            cpuPercent: mean(\.cpuPercent),
            memory: mean(\.memory),
            gpuPercent: mean(\.gpuPercent),
            diskReadRate: mean(\.diskReadRate),
            diskWriteRate: mean(\.diskWriteRate),
            power: mean(\.power),
            openFiles: mean(\.openFiles),
            threads: mean(\.threads),
            restarts: last.restarts,
            down: points.contains(where: \.down)
        )
    }
}

extension ProcessStatsPoint {
    public init(_ status: InstanceStatus, at date: Date) {
        let stats = status.stats
        self.init(date: date,
                  cpuPercent: status.cpu,
                  memory: (stats?.footprint ?? status.rss).map { Double($0) },
                  gpuPercent: stats?.gpuPercent,
                  diskReadRate: stats?.diskReadRate,
                  diskWriteRate: stats?.diskWriteRate,
                  power: stats?.power,
                  openFiles: stats?.openFiles.map { Double($0) },
                  threads: stats?.threads.map { Double($0) },
                  restarts: status.restarts,
                  down: status.pid == nil)
    }
}

/// One instance's stats, from `GET /v1/processes/:name/history`: like `NodeStatsHistory`,
/// the last hour from memory and older stretches from the head's database.
public struct ProcessStatsHistory: Codable, Sendable, Equatable {
    public var node: NodeID
    public var service: String
    public var instance: Int
    /// Oldest first.
    public var points: [ProcessStatsPoint]
    /// True when there were more points than the limit and neighbours were merged.
    public var downsampled: Bool

    public init(node: NodeID, service: String, instance: Int, points: [ProcessStatsPoint], downsampled: Bool = false) {
        self.node = node
        self.service = service
        self.instance = instance
        self.points = points
        self.downsampled = downsampled
    }
}

/// How long the head keeps stats history, in days, from `GET/PUT /v1/settings/history`.
/// The finer tiers keep their own shorter spans (2 days of minutes, 35 of quarter hours)
/// unless this is shorter still.
public struct HistoryRetention: Codable, Sendable, Equatable {
    public var nodeDays: Int
    public var processDays: Int

    public init(nodeDays: Int = Self.defaultDays, processDays: Int = Self.defaultDays) {
        self.nodeDays = nodeDays
        self.processDays = processDays
    }

    /// A little past the 6 months the app's longest window shows.
    public static let defaultDays = 190
    public static let allowedDays = 1...730

    public var isValid: Bool { Self.allowedDays.contains(nodeDays) && Self.allowedDays.contains(processDays) }
}

/// A partial change: fields left nil keep their value.
public struct HistoryRetentionUpdate: Codable, Sendable, Equatable {
    public var nodeDays: Int?
    public var processDays: Int?

    public init(nodeDays: Int? = nil, processDays: Int? = nil) {
        self.nodeDays = nodeDays
        self.processDays = processDays
    }
}
