import Foundation
import TenderClient
import TenderCore

/// One poll's worth of a node's stats. The head keeps no history, so the app records its
/// own while it's open: one sample per poll, the last hour, in memory only.
struct NodeSample: Identifiable {
    var date: Date
    var up: Bool
    var cpuPercent: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var gpuPercent: Double?
    var networkIn: Double?
    var networkOut: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var power: Double?
    var heartbeatAge: Double?
    var clockSkew: Double?
    var spoolBacklog: Double
    var instances: Double
    var crashed: Double

    var id: Date { date }

    init(_ node: NodeSummary, at date: Date) {
        let stats = node.stats
        self.date = date
        up = node.up
        cpuPercent = stats?.cpuPercent
        memoryUsed = stats?.memoryUsed.map { Double($0) }
        memoryTotal = stats.map { Double($0.memoryTotal) }
        gpuPercent = stats?.gpuPercent
        networkIn = stats?.networkInRate
        networkOut = stats?.networkOutRate
        diskRead = stats?.diskReadRate
        diskWrite = stats?.diskWriteRate
        power = stats?.power?.total
        heartbeatAge = node.lastHeartbeatAge
        clockSkew = node.clockSkew
        spoolBacklog = Double(node.spoolBacklog)
        instances = Double(node.instanceCount)
        crashed = Double(node.crashedCount)
    }
}

struct NodeHistory {
    /// An hour at the 5-second poll interval.
    static let capacity = 720

    private(set) var samples: [String: [NodeSample]] = [:]

    mutating func record(_ nodes: [NodeSummary], at date: Date = Date()) {
        for node in nodes {
            samples[node.id, default: []].append(NodeSample(node, at: date))
            if let count = samples[node.id]?.count, count > Self.capacity {
                samples[node.id]?.removeFirst(count - Self.capacity)
            }
        }
    }

    func samples(for nodeID: String, since start: Date) -> [NodeSample] {
        (samples[nodeID] ?? []).filter { $0.date >= start }
    }
}

#if DEBUG
extension NodeHistory {
    /// An hour of made-up wobble around each node's current stats, for previews.
    static func preview(_ nodes: [NodeSummary]) -> NodeHistory {
        var history = NodeHistory()
        let now = Date()
        for step in stride(from: capacity - 1, through: 0, by: -1) {
            let t = Double(step)
            let wobbled = nodes.map { node -> NodeSummary in
                var node = node
                guard node.up, var stats = node.stats else { return node }
                let wave = sin(t / 40) * 0.5 + sin(t / 7) * 0.2
                stats.cpuPercent = stats.cpuPercent.map { max(0, $0 * (1 + wave)) }
                stats.memoryUsed = stats.memoryUsed.map { UInt64(Double($0) * (1 + wave * 0.05)) }
                stats.networkInRate = stats.networkInRate.map { max(0, $0 * (1 + wave * 2)) }
                stats.networkOutRate = stats.networkOutRate.map { max(0, $0 * (1 - wave)) }
                stats.diskReadRate = stats.diskReadRate.map { max(0, $0 * (1 + wave * 1.5)) }
                stats.diskWriteRate = stats.diskWriteRate.map { max(0, $0 * (1 - wave)) }
                stats.gpuPercent = stats.gpuPercent.map { max(0, $0 * (1 + wave * 1.5)) }
                let power = stats.power?.total
                stats.power?.total = power.map { max(0, $0 * (1 + wave)) }
                node.stats = stats
                node.lastHeartbeatAge = 2 + abs(sin(t / 3)) * 4
                node.spoolBacklog = max(0, Int(sin(t / 25) * 40))
                return node
            }
            history.record(wobbled, at: now.addingTimeInterval(-t * 5))
        }
        return history
    }
}
#endif
