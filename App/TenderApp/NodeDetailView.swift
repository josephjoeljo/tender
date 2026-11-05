import Charts
import SwiftUI
import TenderClient
import TenderCore

/// One node: its current stats on top, then charts of the head's history plus the app's polls.
struct NodeDetailView: View {
    let model: ClusterModel
    let nodeID: String
    @AppStorage("nodeHistoryWindow") private var window: Double = 900

    var body: some View {
        if let node = model.nodes.first(where: { $0.id == nodeID }) {
            let now = Date()
            let samples = model.history.samples(for: nodeID, since: now.addingTimeInterval(-window))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NodeBentoCard(node: node)
                    HStack {
                        Text("History").font(.app(.title3))
                        Spacer()
                        Picker("Window", selection: $window) {
                            Text("5 min").tag(300.0)
                            Text("15 min").tag(900.0)
                            Text("1 hour").tag(3600.0)
                            Text("6 hours").tag(21600.0)
                            Text("24 hours").tag(86400.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if samples.count < 2 {
                        Label("No history yet. The head records one point per heartbeat, from when it started.", systemImage: "clock")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], spacing: 16) {
                        charts(samples, node: node, span: now.addingTimeInterval(-window)...now)
                    }
                    Text("From the head's memory (up to 24 hours, per-minute beyond the last hour), then this app's 5-second polls.")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle(node.info.id.rawValue)
            .task(id: "\(nodeID) \(window)") { await model.loadHistory(nodeID: nodeID, window: window) }
        } else {
            ContentUnavailableView("Node not found", systemImage: "desktopcomputer",
                                   description: Text("\(nodeID) is no longer part of this cluster."))
        }
    }

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

private struct HistoryChart: View {
    struct Series {
        let name: String
        let color: Color
        let value: KeyPath<NodeSample, Double?>

        init(_ name: String, _ color: Color, _ value: KeyPath<NodeSample, Double?>) {
            self.name = name
            self.color = color
            self.value = value
        }

        init(_ name: String, _ color: Color, _ value: KeyPath<NodeSample, Double>) {
            self.init(name, color, value.appending(path: \.optional))
        }
    }

    /// The whole window, so the time axis doesn't stretch while history is still building up.
    let span: ClosedRange<Date>
    let title: String
    let samples: [NodeSample]
    let series: [Series]
    let format: (Double) -> String
    var domain: ClosedRange<Double>?
    /// Counts change in steps, so don't draw slopes between them.
    var step = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.app(.caption)).foregroundStyle(.secondary)
                Spacer()
                ForEach(series, id: \.name) { line in
                    HStack(spacing: 4) {
                        Circle().fill(line.color).frame(width: 6, height: 6)
                        Text(samples.last.flatMap { $0[keyPath: line.value] }.map(format) ?? StatFormat.dash)
                            .font(.app(.callout))
                    }
                    .help(line.name)
                }
            }
            Chart {
                ForEach(series, id: \.name) { line in
                    ForEach(samples) { sample in
                        if let value = sample[keyPath: line.value] {
                            LineMark(x: .value("Time", sample.date), y: .value(line.name, value),
                                     series: .value("Series", line.name))
                                .foregroundStyle(line.color)
                                .interpolationMethod(step ? .stepEnd : .monotone)
                            if series.count == 1 {
                                AreaMark(x: .value("Time", sample.date), y: .value(line.name, value))
                                    .foregroundStyle(line.color.opacity(0.12))
                                    .interpolationMethod(step ? .stepEnd : .monotone)
                            }
                        }
                    }
                }
            }
            .chartXScale(domain: span)
            .chartYScale(domain: domain ?? autoDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.app(.caption2))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(value.as(Double.self).map(format) ?? "").font(.app(.caption2)) }
                }
            }
            .frame(height: 120)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)) }
    }

    /// From zero (or below, for clock skew), with headroom, so a flat line doesn't fill the chart.
    private var autoDomain: ClosedRange<Double> {
        let values = samples.flatMap { sample in series.compactMap { sample[keyPath: $0.value] } }
        let low = min(values.min() ?? 0, 0) * 1.2
        return low...max((values.max() ?? 0) * 1.2, low + 1)
    }
}

private extension Double {
    var optional: Double? { self }
}

#if DEBUG
#Preview("Node detail") {
    NavigationStack { NodeDetailView(model: .previewDegraded, nodeID: "mac-1") }.frame(width: 1000, height: 800)
}
#endif
