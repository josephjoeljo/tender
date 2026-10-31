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
