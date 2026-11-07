import SwiftUI
import TenderClient
import TenderCore

// The panels that drop down under a process or node row in the dashboard.

enum StatFormat {
    static let dash = "–"

    static func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? dash
    }

    static func rate(_ value: Double?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(max($0, 0).rounded()), countStyle: .file) + "/s" } ?? dash
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? dash
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return dash }
        return value < 1 ? String(format: "%.0f mW", value * 1000) : String(format: "%.2f W", value)
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return dash }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? dash
    }

    static func ratio(_ part: UInt64?, of whole: UInt64?) -> Double? {
        guard let part, let whole, whole > 0 else { return nil }
        return Double(part) / Double(whole)
    }
}

/// One measurement: a title, a big value, an optional bar, and a line or two of detail.
struct StatTile: View {
    let title: String
    let symbol: String
    let value: String
    var detail: [String] = []
    /// 0…1. Shown as a bar that turns orange past 75% and red past 90%.
    var fraction: Double?
    /// Overrides the bar and value colour, for states like memory pressure.
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(tint ?? Self.color(for: fraction))
            }
            ForEach(Array(detail.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    static func color(for fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor
    }
}

private struct StatGrid<Content: View>: View {
    var minimum: CGFloat = 180
    @ViewBuilder let content: Content

    var body: some View {
        AdaptiveGrid(minimum: minimum, spacing: 10) { content }
    }
}

/// As many equal columns as fit at `minimum` wide, rows as tall as their tallest cell. Not
/// lazy, unlike LazyVGrid, so it can sit inside a self-sizing list row: on iOS a lazy grid
/// there keeps re-measuring the cell until UIKit gives up.
struct AdaptiveGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat

    private func columns(_ width: CGFloat, count: Int) -> Int {
        max(1, min(count, Int((width + spacing) / (minimum + spacing))))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (columnWidth: CGFloat, heights: [CGFloat], columns: Int) {
        let columns = columns(width, count: subviews.count)
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
        return (columnWidth, heights, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let heights = rows(subviews, width: width).heights
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columnWidth, heights, columns) = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns where row * columns + column < subviews.count {
                subviews[row * columns + column].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (columnWidth + spacing), y: y),
                    proposal: ProposedViewSize(width: columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}

/// Small labelled facts under the tiles.
private struct FactRow: View {
    let facts: [(String, String)]

    var body: some View {
        // On one line when it fits, as on the Mac; in columns on a phone.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                items
                Spacer(minLength: 0)
            }
            AdaptiveGrid(minimum: 150, spacing: 6) { items }
        }
        .font(.caption)
    }

    private var items: some View {
        ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
            HStack(spacing: 4) {
                Text(fact.0).foregroundStyle(.secondary)
                Text(fact.1).textSelection(.enabled).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OlderDaemonNote: View {
    var body: some View {
        Label("This node's tenderd doesn't send detailed stats yet. Update it to see storage, GPU, Neural Engine and energy.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct ProcessStatsPanel: View {
    let process: InstanceStatus
    /// The node it runs on, for scaling CPU and memory against the machine.
    let node: NodeSummary?
    /// Narrower tiles, for the inspector.
    var compact = false
    /// The inspector shows PID, uptime and the rest as rows of its own.
    var showsFacts = true

    var body: some View {
        let stats = process.stats
        let machine = node?.stats
        let memory = stats?.footprint ?? process.rss
        VStack(alignment: .leading, spacing: 10) {
            if process.state != .running {
                Label("Not running, so there's nothing to measure right now.", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if stats == nil {
                OlderDaemonNote()
            }
            StatGrid(minimum: compact ? 130 : 180) {
                StatTile(title: "CPU", symbol: "cpu", value: StatFormat.percent(process.cpu),
                         detail: ["of one core" + (machine.map { " · node has \($0.cpuCores)" } ?? ""),
                                  "CPU time \(StatFormat.duration(process.cpuSeconds))"],
                         fraction: machine.flatMap { m in process.cpu.map { $0 / Double(max(m.cpuCores, 1) * 100) } })
                StatTile(title: "Memory", symbol: "memorychip", value: StatFormat.bytes(memory),
                         detail: ["Resident \(StatFormat.bytes(process.rss))", "Peak \(StatFormat.bytes(stats?.peakFootprint))"],
                         fraction: StatFormat.ratio(memory, of: machine?.memoryTotal))
                if let stats {
                    StatTile(title: "Storage", symbol: "internaldrive",
                             value: "↓ \(StatFormat.rate(stats.diskReadRate))",
                             detail: ["↑ \(StatFormat.rate(stats.diskWriteRate)) written",
                                      "Total \(StatFormat.bytes(stats.diskReadBytes)) read · \(StatFormat.bytes(stats.diskWriteBytes)) written"])
                    StatTile(title: "GPU", symbol: "square.stack.3d.up", value: StatFormat.percent(stats.gpuPercent),
                             detail: [stats.gpuPercent == nil ? "GPU not readable on this node"
                                      : "GPU time \(StatFormat.duration(stats.gpuSeconds))"],
                             fraction: stats.gpuPercent.map { $0 / 100 })
                    StatTile(title: "Neural Engine", symbol: "brain",
                             value: (stats.neuralFootprint ?? 0) > 0 ? StatFormat.bytes(stats.neuralFootprint) : "Not in use",
                             detail: ["ANE memory held by this process"])
                    StatTile(title: "Energy", symbol: "bolt", value: StatFormat.watts(stats.power),
                             detail: [stats.wakeupsPerSecond.map { String(format: "%.0f wakeups/s", $0) } ?? "Wakeups \(StatFormat.dash)"])
                    StatTile(title: "Threads & files", symbol: "list.bullet.indent",
                             value: stats.threads.map { "\($0) threads" } ?? StatFormat.dash,
                             detail: [stats.openFiles.map { "\($0) open files" } ?? "Open files \(StatFormat.dash)"])
                }
            }
            if showsFacts {
                FactRow(facts: [
                ("PID", process.pid.map(String.init) ?? StatFormat.dash),
                ("Uptime", StatFormat.duration(process.uptime)),
                ("Release", process.release ?? StatFormat.dash),
                ("Last exit", process.lastExitCode.map(String.init) ?? StatFormat.dash),
                ("Restarts", "\(process.restarts)"),
            ] + (process.adopted ? [("Adopted", "yes")] : []))
            }
        }
    }
}

struct NodeStatsPanel: View {
    let node: NodeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stats = node.stats {
                StatGrid {
                    StatTile(title: "CPU", symbol: "cpu", value: StatFormat.percent(stats.cpuPercent),
                             detail: [cores(stats), stats.loadAverage.isEmpty ? "Load \(StatFormat.dash)"
                                      : "Load " + stats.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " · ")],
                             fraction: stats.cpuPercent.map { $0 / 100 })
                    StatTile(title: "Memory", symbol: "memorychip",
                             value: "\(StatFormat.bytes(stats.memoryUsed)) of \(StatFormat.bytes(stats.memoryTotal))",
                             detail: ["Wired \(StatFormat.bytes(stats.memoryWired)) · Compressed \(StatFormat.bytes(stats.memoryCompressed))",
                                      "Swap \(StatFormat.bytes(stats.swapUsed)) · Pressure \(stats.memoryPressure?.rawValue ?? StatFormat.dash)"],
                             fraction: StatFormat.ratio(stats.memoryUsed, of: stats.memoryTotal),
                             tint: pressureTint(stats.memoryPressure))
                    StatTile(title: "Storage", symbol: "internaldrive",
                             value: "\(StatFormat.bytes(stats.diskFree)) free",
                             detail: ["of \(StatFormat.bytes(stats.diskTotal))",
                                      "↓ \(StatFormat.rate(stats.diskReadRate)) · ↑ \(StatFormat.rate(stats.diskWriteRate))"],
                             fraction: stats.diskTotal.flatMap { total in
                                 stats.diskFree.map { StatFormat.ratio(total - min($0, total), of: total) ?? 0 }
                             })
                    StatTile(title: "Network", symbol: "network", value: "↓ \(StatFormat.rate(stats.networkInRate))",
                             detail: ["↑ \(StatFormat.rate(stats.networkOutRate))", "Ethernet and Wi-Fi"])
                    StatTile(title: "GPU", symbol: "square.stack.3d.up", value: StatFormat.percent(stats.gpuPercent),
                             detail: ["GPU memory \(StatFormat.bytes(stats.gpuMemoryUsed))"],
                             fraction: stats.gpuPercent.map { $0 / 100 })
                    if let power = stats.power {
                        StatTile(title: "Neural Engine · experimental", symbol: "brain",
                                 value: (power.neuralEngine ?? 0) > 0.005 ? StatFormat.watts(power.neuralEngine) : "Idle",
                                 detail: ["Power draw (Apple exposes no usage %)",
                                          power.neuralEngine == nil ? "No ANE channel on this chip" : "Whole node, all processes"])
                        StatTile(title: "Power · experimental", symbol: "bolt",
                                 value: StatFormat.watts(power.total),
                                 detail: ["CPU \(StatFormat.watts(power.cpu)) · GPU \(StatFormat.watts(power.gpu))",
                                          "DRAM \(StatFormat.watts(power.dram)) · SoC only, not the wall"])
                    }
                    StatTile(title: "Thermal", symbol: "thermometer.medium",
                             value: stats.thermalState?.capitalized ?? StatFormat.dash,
                             detail: ["Up \(StatFormat.duration(node.uptime))"],
                             tint: thermalTint(stats.thermalState))
                }
            } else {
                OlderDaemonNote()
            }
            FactRow(facts: [
                ("Hardware", node.info.hardware),
                ("macOS", node.info.macOS),
                ("Uptime", StatFormat.duration(node.uptime)),
                ("Last heartbeat", node.lastHeartbeatAge.map { StatFormat.duration($0) + " ago" } ?? StatFormat.dash),
                ("Role", node.info.isHead ? "head" : "worker"),
            ])
            FactRow(facts: [
                ("Clock skew", node.clockSkew.map { String(format: "%.2f s", $0) } ?? StatFormat.dash),
                ("Log backlog", "\(node.spoolBacklog)"),
                ("Dropped", "\(node.spoolDropped)"),
                ("Crashed", "\(node.crashedCount)"),
                ("Version", node.info.version),
            ])
        }
    }

    private func cores(_ stats: NodeStats) -> String {
        if let p = stats.performanceCores, let e = stats.efficiencyCores {
            return "\(stats.cpuCores) cores (\(p)P + \(e)E)"
        }
        return "\(stats.cpuCores) cores"
    }

    private func pressureTint(_ pressure: MemoryPressure?) -> Color? {
        switch pressure {
        case .warning: .orange
        case .critical: .red
        default: nil
        }
    }

    private func thermalTint(_ state: String?) -> Color? {
        switch state {
        case "serious": .orange
        case "critical": .red
        default: nil
        }
    }
}

/// A row that drops a panel down, lined up under its title, when clicked anywhere outside its buttons.
struct ExpandableRow<Header: View, Detail: View>: View {
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { toggle() } }
            if isExpanded {
                detail
                    #if os(macOS)
                    // Under the title, like a track list. iOS gives the panel the row's full width.
                    .padding(.leading, RowLayout.textLeading)
                    #endif
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }
}

extension Set {
    mutating func toggle(_ member: Element) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}

#if DEBUG
extension NodeStats {
    static var preview: NodeStats {
        NodeStats(sampledAt: Date(), cpuPercent: 23.4, cpuCores: 10, performanceCores: 4, efficiencyCores: 6,
                  loadAverage: [2.1, 1.8, 1.5], memoryTotal: 16 << 30, memoryUsed: 11 << 30, memoryWired: 2 << 30,
                  memoryCompressed: 1 << 30, swapUsed: 0, memoryPressure: .normal, diskTotal: 500 << 30,
                  diskFree: 180 << 30, diskReadRate: 1_200_000, diskWriteRate: 340_000, networkInRate: 85_000,
                  networkOutRate: 12_000, gpuPercent: 7, gpuMemoryUsed: 900 << 20, thermalState: "nominal",
                  bootTime: Date().addingTimeInterval(-3 * 86400),
                  power: PowerStats(cpu: 2.4, gpu: 0.3, neuralEngine: 0.8, dram: 0.4, total: 3.9))
    }
}

extension ProcessStats {
    static var preview: ProcessStats {
        ProcessStats(footprint: 180 << 20, peakFootprint: 260 << 20, threads: 24, openFiles: 41,
                     diskReadBytes: 3 << 30, diskWriteBytes: 800 << 20, diskReadRate: 120_000, diskWriteRate: 45_000,
                     gpuPercent: 0, gpuSeconds: 0, neuralFootprint: 0, power: 0.18, wakeupsPerSecond: 42)
    }
}
#endif
