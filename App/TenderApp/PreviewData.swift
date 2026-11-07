import Foundation
import TenderClient
import TenderCore

// Sample clusters for Xcode previews and TENDER_APP_PREVIEW, on every platform.
#if DEBUG
extension ClusterModel {
    private static func node(_ name: String, up: Bool, processes: Int, crashed: Int = 0) -> NodeSummary {
        NodeSummary(info: NodeInfo(id: NodeID(name), version: "0.1.0", macOS: "macOS", hardware: "Mac", address: "\(name):7070",
                                   labels: name == "mac-1" ? [NodeInfo.roleLabel: NodeInfo.headRole] : [:]),
                    up: up, lastHeartbeatAge: up ? 2 : 90, instanceCount: processes, crashedCount: crashed,
                    stats: up ? .preview : nil)
    }

    private static func process(_ service: String, _ instance: Int, _ node: String, _ state: InstanceState,
                                adopted: Bool = false) -> InstanceStatus {
        InstanceStatus(service: service, instance: instance, node: NodeID(node), state: state,
                       // Varied by name, so sorting the sample list visibly changes its order.
                       pid: state == .running ? 4242 : nil, uptime: state == .running ? Double(service.count * 1800) : nil,
                       cpu: state == .running ? Double(20 - service.count) / 2 : nil,
                       rss: state == .running ? UInt64(service.count * 40) << 20 : nil,
                       cpuSeconds: state == .running ? 410 : nil, adopted: adopted, stats: state == .running ? .preview : nil)
    }

    static var previewHealthy: ClusterModel {
        ClusterModel(previewHealth: .healthy,
                     nodes: [node("mac-1", up: true, processes: 2), node("mac-2", up: true, processes: 2)],
                     processes: [process("api", 0, "mac-1", .running), process("api", 1, "mac-2", .running),
                                 process("mongod", 0, "mac-1", .running), process("worker", 0, "mac-2", .stopped),
                                 process("homebrew.mxcl.redis", 0, "mac-1", .running, adopted: true)])
    }

    static var previewDegraded: ClusterModel {
        ClusterModel(previewHealth: .degraded(downNodes: 1, crashed: 1),
                     nodes: [node("mac-1", up: true, processes: 2, crashed: 1), node("mac-2", up: true, processes: 2), node("mac-3", up: false, processes: 0)],
                     processes: [process("api", 0, "mac-1", .crashed), process("api", 1, "mac-2", .running),
                                 process("mongod", 0, "mac-1", .running), process("worker", 0, "mac-2", .running)])
    }

    static var previewMany: ClusterModel {
        ClusterModel(previewHealth: .degraded(downNodes: 1, crashed: 0),
                     nodes: (1...6).map { node("mac-\($0)", up: $0 != 4, processes: 1) },
                     processes: (1...6).filter { $0 != 4 }.map { process("api", 0, "mac-\($0)", .running) })
    }

    static var previewNotConfigured: ClusterModel {
        ClusterModel(previewHealth: .notConfigured, nodes: [], processes: [])
    }
}
#endif
