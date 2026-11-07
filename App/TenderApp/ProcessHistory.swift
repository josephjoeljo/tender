import SwiftUI
import TenderClient
import TenderCore

/// One point of an instance's history from the head, or the latest poll.
struct ProcessSample: ChartSample {
    var date: Date
    var cpuPercent: Double?
    var memory: Double?
    var gpuPercent: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var power: Double?
    var openFiles: Double?
    var threads: Double?
    var restarts: Double

    var id: Date { date }

    init(_ point: ProcessStatsPoint) {
        date = point.date
        cpuPercent = point.cpuPercent
        memory = point.memory
        gpuPercent = point.gpuPercent
        diskRead = point.diskReadRate
        diskWrite = point.diskWriteRate
        power = point.power
        openFiles = point.openFiles
        threads = point.threads
        restarts = Double(point.restarts)
    }
}

extension ClusterModel {
    enum ProcessHistoryLoad: Equatable {
        case points([ProcessStatsPoint])
        /// The head runs a tenderd from before process history.
        case unsupported
        case failed(String)
    }
}

/// Charts of one instance's resource use over a window the viewer picks, the same windows
/// as a node's history. Refetched every few seconds for short windows, every minute for long ones.
struct ProcessHistorySection: View {
    let model: ClusterModel
    let process: InstanceStatus
    @AppStorage("processHistoryWindow") private var window: Double = 900
    @State private var load: ClusterModel.ProcessHistoryLoad?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History").font(.headline)
            HistoryWindowPicker(window: $window, keepingDays: model.historyRetention?.processDays, fillsWidth: true)
            content
        }
        .task(id: "\(process.node) \(process.service) \(process.instance) \(window)") {
            load = nil
            await model.loadHistoryRetention()
            while !Task.isCancelled {
                load = await model.processHistory(of: process, window: window)
                try? await Task.sleep(for: .seconds(window <= 3600 ? 10 : 60))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case nil:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        case .unsupported:
            note("The head's tenderd doesn't keep process history yet. Update it to see charts here.", "info.circle")
        case .failed(let message):
            note("Couldn't load history: \(message)", "exclamationmark.triangle")
        case .points(let points):
            let now = Date()
            let samples = points.map(ProcessSample.init)
            if samples.count < 2 {
                note("No history yet. The head records an instance from its first heartbeat and keeps \(keptFor(model.historyRetention?.processDays)).", "clock")
            }
            charts(samples, span: now.addingTimeInterval(-window)...now)
            Text("Averages per point, from the head. A restarted process continues the same series.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func charts(_ samples: [ProcessSample], span: ClosedRange<Date>) -> some View {
        let node = model.nodes.first { $0.info.id == process.node }?.stats
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], spacing: 12) {
            HistoryChart(span: span, title: "CPU (% of one core)", samples: samples,
                         series: [.init("CPU", .blue, \.cpuPercent)], format: { StatFormat.percent($0) })
            HistoryChart(span: span, title: "Memory", samples: samples, series: [.init("Footprint", .purple, \.memory)],
                         format: { StatFormat.bytes(UInt64(max($0, 0))) })
            HistoryChart(span: span, title: "Storage I/O", samples: samples,
                         series: [.init("Read", .green, \.diskRead), .init("Write", .pink, \.diskWrite)],
                         format: { StatFormat.rate($0) })
            if samples.contains(where: { $0.gpuPercent ?? 0 > 0 }) {
                HistoryChart(span: span, title: "GPU", samples: samples, series: [.init("GPU", .indigo, \.gpuPercent)],
                             format: { StatFormat.percent($0) }, domain: 0...100)
            }
            if node?.power != nil || samples.contains(where: { $0.power != nil }) {
                HistoryChart(span: span, title: "Power", samples: samples, series: [.init("Power", .yellow, \.power)],
                             format: { StatFormat.watts($0) })
            }
            HistoryChart(span: span, title: "Open files", samples: samples,
                         series: [.init("Files", .orange, \.openFiles), .init("Threads", .teal, \.threads)],
                         format: { String(format: "%.0f", $0) })
            HistoryChart(span: span, title: "Restarts", samples: samples, series: [.init("Restarts", .red, \.restarts)],
                         format: { String(format: "%.0f", $0) }, step: true)
        }
    }
}

#if DEBUG
extension ProcessStatsPoint {
    /// Made-up wobble around an instance's current use across the window, for previews.
    static func preview(_ process: InstanceStatus, window: TimeInterval, now: Date = Date()) -> [ProcessStatsPoint] {
        guard process.state == .running else { return [] }
        let count = 240
        let stats = process.stats
        return (0..<count).map { index in
            let t = Double(index)
            let wave = sin(t / 18) * 0.4 + sin(t / 5) * 0.15
            let memory = Double(stats?.footprint ?? process.rss ?? 0)
            return ProcessStatsPoint(
                date: now.addingTimeInterval(-window + window * t / Double(count - 1)),
                cpuPercent: process.cpu.map { max(0, $0 * (1 + wave)) },
                memory: memory * (0.9 + t / Double(count) * 0.1 + wave * 0.02),
                gpuPercent: stats?.gpuPercent.map { max(0, $0 * (1 + wave)) },
                diskReadRate: stats?.diskReadRate.map { max(0, $0 * (1 + wave * 2)) },
                diskWriteRate: stats?.diskWriteRate.map { max(0, $0 * (1 - wave)) },
                power: stats?.power.map { max(0, $0 * (1 + wave)) },
                openFiles: stats?.openFiles.map { Double($0) + (index > count / 2 ? 3 : 0) },
                threads: stats?.threads.map(Double.init),
                restarts: max(0, process.restarts - (index < count / 3 ? 1 : 0)))
        }
    }
}
#endif
