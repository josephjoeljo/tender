import TenderCore

/// What the menu bar icon shows. Pure, so that every combination can be tested.
public enum ClusterHealth: Sendable, Equatable {
    case notConfigured
    case unreachable(String)
    case healthy
    case degraded(downNodes: Int, crashed: Int)

    public init(nodes: NodeList, processes: ProcessList) {
        let down = nodes.nodes.filter { !$0.up }.count
        let crashed = processes.processes.filter { $0.state == .crashed }.count
        self = down == 0 && crashed == 0 ? .healthy : .degraded(downNodes: down, crashed: crashed)
    }

    public var symbol: String {
        switch self {
        case .notConfigured: "leaf"
        case .unreachable: "bolt.horizontal.circle"
        case .healthy: "checkmark.circle"
        case .degraded: "exclamationmark.triangle"
        }
    }

    public var summary: String {
        switch self {
        case .notConfigured: "No head configured"
        case .unreachable(let detail): "Head unreachable: \(detail)"
        case .healthy: "All good"
        case .degraded(let down, let crashed):
            [down > 0 ? "\(down) node\(down == 1 ? "" : "s") down" : nil,
             crashed > 0 ? "\(crashed) crashed" : nil].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

/// One node's meter in the menu bar.
public struct NodeMeter: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case healthy, degraded, down }

    public var label: String
    /// How full the capsule is: the share of wanted processes that are running.
    public var fraction: Double
    public var level: Level

    public init(label: String, fraction: Double, level: Level) {
        self.label = label
        self.fraction = fraction
        self.level = level
    }

    public static let maxLabelLength = 8
    /// More than this may not fit, and macOS hides menu bar items that don't, without warning.
    public static let maxMetersShown = 4

    /// Every character of a mono font takes a full width, so names are cut to keep the item small.
    public static func shortLabel(_ name: String) -> String {
        name.count <= maxLabelLength ? name : String(name.prefix(maxLabelLength - 1)) + "…"
    }

    /// Stopped processes don't count against a node: someone asked for that.
    public static func meters(nodes: [NodeSummary], processes: [InstanceStatus]) -> [NodeMeter] {
        nodes.map { node in
            let wanted = processes.filter { $0.node == node.info.id && $0.state != .stopped }
            let running = wanted.filter { $0.state == .running || $0.state == .starting }.count
            let label = shortLabel(node.info.id.rawValue)
            guard node.up else { return NodeMeter(label: label, fraction: 1, level: .down) }
            guard !wanted.isEmpty else { return NodeMeter(label: label, fraction: 1, level: .healthy) }
            return NodeMeter(label: label, fraction: Double(running) / Double(wanted.count),
                             level: running == wanted.count ? .healthy : .degraded)
        }
    }
}
