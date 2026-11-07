#if os(macOS)
import SwiftUI
import TenderClient
import TenderCore

/// Quick glance: cluster health, nodes, and the processes that need attention.
struct MenuBarView: View {
    let model: ClusterModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// The process list's natural height. A ScrollView in a menu bar window has no ideal
    /// height of its own and collapses to zero, so the list is sized to this, up to a cap.
    @State private var processListHeight: CGFloat = 0

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
                        Text(node.info.displayName)
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { processListHeight = $0 }
                }
                .frame(height: min(max(processListHeight, 20), 220))
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

struct ProcessRow: View {
    let process: InstanceStatus
    let model: ClusterModel

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(process.service)[\(process.instance)]")
                Text("\(model.name(of: process.node)) · \(process.state.rawValue)")
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
#Preview("Healthy") { MenuBarView(model: .previewHealthy) }
#Preview("Degraded") { MenuBarView(model: .previewDegraded) }
#Preview("Not configured") { MenuBarView(model: .previewNotConfigured) }
#endif
#endif
