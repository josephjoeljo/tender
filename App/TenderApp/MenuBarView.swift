import SwiftUI
import TenderClient
import TenderCore

/// Quick glance: cluster health, nodes, and the processes that need attention.
struct MenuBarView: View {
    let model: ClusterModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.health.summary, systemImage: model.health.symbol)
                .font(.headline)
                .lineLimit(3)
            if !model.nodes.isEmpty {
                Divider()
                ForEach(model.nodes, id: \.info.id) { node in
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(node.up ? .green : .red)
                        Text(node.info.id.rawValue)
                        Spacer()
                        Text("\(node.instanceCount) processes").foregroundStyle(.secondary)
                    }
                }
            }
            if !model.processes.isEmpty {
                Divider()
                Text(model.problems.isEmpty ? "Processes" : "Needs attention").font(.subheadline.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.problems.isEmpty ? model.processes : model.problems, id: \.rowID) { process in
                            ProcessRow(process: process, model: model)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if let error = model.actionError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Divider()
            HStack {
                Button("Open dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate()
                }
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 340)
    }
}

extension InstanceStatus {
    var rowID: String { "\(node.rawValue)/\(service)/\(instance)" }
}

struct ProcessRow: View {
    let process: InstanceStatus
    let model: ClusterModel

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(process.service)[\(process.instance)]")
                Text("\(process.node.rawValue) · \(process.state.rawValue)")
                    .font(.caption)
                    .foregroundStyle(process.state == .crashed ? .red : .secondary)
            }
            Spacer()
            button("play.fill", .start, help: "Start").disabled(process.state == .running)
            button("stop.fill", .stop, help: "Stop").disabled(process.state == .stopped)
            button("arrow.clockwise", .restart, help: "Restart")
        }
    }

    private func button(_ symbol: String, _ action: ClusterModel.Action, help: String) -> some View {
        Button {
            Task { await model.perform(action, on: process) }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

#if DEBUG
extension ClusterModel {
    private static func node(_ name: String, up: Bool, processes: Int, crashed: Int = 0) -> NodeSummary {
        NodeSummary(info: NodeInfo(id: NodeID(name), version: "0.1.0", macOS: "macOS", hardware: "Mac", address: "\(name):7070",
                                   labels: name == "mac-1" ? [NodeInfo.roleLabel: NodeInfo.headRole] : [:]),
                    up: up, lastHeartbeatAge: up ? 2 : 90, instanceCount: processes, crashedCount: crashed)
    }

    private static func process(_ service: String, _ instance: Int, _ node: String, _ state: InstanceState) -> InstanceStatus {
        InstanceStatus(service: service, instance: instance, node: NodeID(node), state: state)
    }

    static var previewHealthy: ClusterModel {
        ClusterModel(previewHealth: .healthy,
                     nodes: [node("mac-1", up: true, processes: 2), node("mac-2", up: true, processes: 2)],
                     processes: [process("api", 0, "mac-1", .running), process("api", 1, "mac-2", .running),
                                 process("mongod", 0, "mac-1", .running), process("worker", 0, "mac-2", .stopped)])
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

#Preview("Healthy") { MenuBarView(model: .previewHealthy) }
#Preview("Degraded") { MenuBarView(model: .previewDegraded) }
#Preview("Not configured") { MenuBarView(model: .previewNotConfigured) }
#endif
