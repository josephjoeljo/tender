import SwiftUI
import TenderClient
import TenderCore

/// One node: its current stats on top, then charts of the head's history plus the app's polls.
struct NodeDetailView: View {
    let model: ClusterModel
    let nodeID: String
    @AppStorage("nodeHistoryWindow") private var window: Double = 900
    @State private var editing = false

    var body: some View {
        if let node = model.nodes.first(where: { $0.id == nodeID }) {
            let now = Date()
            let samples = model.history.samples(for: nodeID, since: now.addingTimeInterval(-window))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NodeBentoCard(node: node)
                    // Beside the title when the picker fits, under it on a phone.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            historyTitle
                            Spacer()
                            HistoryWindowPicker(window: $window, keepingDays: model.historyRetention?.nodeDays)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            historyTitle
                            HistoryWindowPicker(window: $window, keepingDays: model.historyRetention?.nodeDays, fillsWidth: true)
                        }
                    }
                    if samples.count < 2 {
                        Label("No history yet. The head records a node from its first heartbeat and keeps \(keptFor(model.historyRetention?.nodeDays)).", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], spacing: 16) {
                        charts(samples, node: node, span: now.addingTimeInterval(-window)...now)
                    }
                    Text("From the head: every heartbeat for the last hour, then per minute, per 15 minutes beyond 2 days, and per hour beyond 35 days, for \(keptFor(model.historyRetention?.nodeDays)) (set in Settings). Then this app's 5-second polls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle(node.info.displayName)
            .toolbar {
                ToolbarItem {
                    Button("Name and Labels", systemImage: "tag") { editing = true }
                        .help("Rename this node or edit its labels")
                }
            }
            .sheet(isPresented: $editing) { NodeSettingsSheet(model: model, node: node) }
            .task(id: "\(nodeID) \(window)") {
                await model.loadHistoryRetention()
                await model.loadHistory(nodeID: nodeID, window: window)
            }
        } else {
            ContentUnavailableView("Node not found", systemImage: "desktopcomputer",
                                   description: Text("\(nodeID) is no longer part of this cluster."))
        }
    }

    private var historyTitle: some View { Text("History").font(.title3) }

    @ViewBuilder
    private func charts(_ samples: [NodeSample], node: NodeSummary, span: ClosedRange<Date>) -> some View {
        HistoryChart(span: span, title: "CPU", samples: samples, series: [.init("CPU", .blue, \.cpuPercent)],
                     format: { StatFormat.percent($0) }, domain: 0...100)
        HistoryChart(span: span, title: "Memory", samples: samples, series: [.init("Used", .purple, \.memoryUsed)],
                     format: { StatFormat.bytes(UInt64(max($0, 0))) },
                     domain: node.stats.map { 0...Double($0.memoryTotal) })
        HistoryChart(span: span, title: "Network", samples: samples,
                     series: [.init("In", .teal, \.networkIn), .init("Out", .orange, \.networkOut)],
                     format: { StatFormat.rate($0) })
        HistoryChart(span: span, title: "Storage I/O", samples: samples,
                     series: [.init("Read", .green, \.diskRead), .init("Write", .pink, \.diskWrite)],
                     format: { StatFormat.rate($0) })
        HistoryChart(span: span, title: "GPU", samples: samples, series: [.init("GPU", .indigo, \.gpuPercent)],
                     format: { StatFormat.percent($0) }, domain: 0...100)
        if node.stats?.power != nil {
            HistoryChart(span: span, title: "Power", samples: samples, series: [.init("Power", .yellow, \.power)],
                         format: { StatFormat.watts($0) })
        }
        HistoryChart(span: span, title: "Processes", samples: samples,
                     series: [.init("Running", .blue, \.instances), .init("Crashed", .red, \.crashed)],
                     format: { String(format: "%.0f", $0) }, step: true)
        HistoryChart(span: span, title: "Heartbeat age", samples: samples, series: [.init("Age", .gray, \.heartbeatAge)],
                     format: { StatFormat.duration($0) })
        HistoryChart(span: span, title: "Log backlog", samples: samples, series: [.init("Lines", .brown, \.spoolBacklog)],
                     format: { String(format: "%.0f", $0) }, step: true)
        HistoryChart(span: span, title: "Clock skew", samples: samples, series: [.init("Skew", .mint, \.clockSkew)],
                     format: { String(format: "%+.2f s", $0) })
    }
}

#if DEBUG
#Preview("Node detail") {
    NavigationStack { NodeDetailView(model: .previewDegraded, nodeID: "mac-1") }.frame(width: 1000, height: 800)
}
#endif

/// "190 days", or the old fixed span from a head that doesn't say.
func keptFor(_ days: Int?) -> String {
    guard let days else { return "up to 6 months" }
    return days == 1 ? "1 day" : "\(days) days"
}
