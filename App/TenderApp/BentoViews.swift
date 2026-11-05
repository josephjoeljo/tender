import SwiftUI
import TenderClient
import TenderCore

// The bento layout of the nodes page: one card per node, its health at a glance.
// Within a card the tiles get smaller as the stats get less urgent.

enum NodesLayout: String, CaseIterable, Identifiable {
    case list, bento
    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "List"
        case .bento: "Bento"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .bento: "square.grid.2x2"
        }
    }
}

struct NodesBentoView: View {
    let nodes: [NodeSummary]
    let open: (NodeSummary) -> Void
    @State private var width: CGFloat = 0

    private static let minCardWidth: CGFloat = 360
    private static let spacing: CGFloat = 16

    /// As many columns as fit, but never more than there are nodes, so the cards always span the full width.
    private var columns: [GridItem] {
        let fit = Int((width - Self.spacing) / (Self.minCardWidth + Self.spacing))
        let count = max(1, min(nodes.count, fit))
        return Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(nodes) { node in
                    Button { open(node) } label: { NodeBentoCard(node: node) }
                        .buttonStyle(.plain)
                        .help("Show \(node.info.id.rawValue)'s history")
                }
            }
            .padding(Self.spacing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct NodeBentoCard: View {
    let node: NodeSummary

    var body: some View {
        let stats = node.stats
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 8) {
                BentoRingTile(title: "CPU", symbol: "cpu", value: StatFormat.percent(stats?.cpuPercent),
                              detail: stats.map { "\($0.cpuCores) cores" + load($0) } ?? StatFormat.dash,
                              fraction: stats?.cpuPercent.map { $0 / 100 })
                BentoRingTile(title: "Memory", symbol: "memorychip", value: StatFormat.bytes(stats?.memoryUsed),
                              detail: "of \(StatFormat.bytes(stats?.memoryTotal))" + (stats?.memoryPressure.map { " · \($0.rawValue)" } ?? ""),
                              fraction: StatFormat.ratio(stats?.memoryUsed, of: stats?.memoryTotal),
                              tint: pressureTint(stats?.memoryPressure))
            }
            HStack(spacing: 8) {
                BentoCountTile(title: "Processes", symbol: "gearshape.2", count: node.instanceCount, tint: .accentColor)
                BentoCountTile(title: "Crashed", symbol: "exclamationmark.triangle", count: node.crashedCount,
                               tint: node.crashedCount > 0 ? .red : .secondary)
            }
            HStack(spacing: 8) {
                BentoMiniTile(title: "Heartbeat", value: node.lastHeartbeatAge.map { StatFormat.duration($0) + " ago" } ?? StatFormat.dash,
                              tint: (node.lastHeartbeatAge ?? 0) > 30 || !node.up ? .orange : nil)
                BentoMiniTile(title: "Clock skew", value: node.clockSkew.map { String(format: "%+.2f s", $0) } ?? StatFormat.dash,
                              tint: abs(node.clockSkew ?? 0) > 1 ? .orange : nil)
                BentoMiniTile(title: "Log backlog", value: "\(node.spoolBacklog)",
                              detail: node.spoolDropped > 0 ? "\(node.spoolDropped) dropped" : nil,
                              tint: node.spoolDropped > 0 ? .orange : nil)
            }
            if let stats {
                HStack(spacing: 8) {
                    BentoMiniTile(title: "Disk free", value: StatFormat.bytes(stats.diskFree),
                                  detail: "of \(StatFormat.bytes(stats.diskTotal))")
                    BentoMiniTile(title: "Network", value: "↓ \(StatFormat.rate(stats.networkInRate))",
                                  detail: "↑ \(StatFormat.rate(stats.networkOutRate))")
                    BentoMiniTile(title: "GPU", value: StatFormat.percent(stats.gpuPercent),
                                  detail: stats.gpuMemoryUsed.map { StatFormat.bytes($0) })
                    BentoMiniTile(title: stats.power == nil ? "Thermal" : "Power",
                                  value: stats.power.map { StatFormat.watts($0.total) } ?? (stats.thermalState?.capitalized ?? StatFormat.dash),
                                  detail: stats.power == nil ? nil : stats.thermalState?.capitalized,
                                  tint: thermalTint(stats.thermalState))
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(node.up ? Color.primary.opacity(0.08) : Color.red.opacity(0.5))
        }
        .saturation(node.up ? 1 : 0.4)
        .contextMenu {
            Button("Copy Name") { copyToPasteboard(node.info.id.rawValue) }
            if let address = node.info.address {
                Button("Copy Address") { copyToPasteboard(address) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RowArtwork(symbol: node.info.isHead ? "crown.fill" : "desktopcomputer",
                       tint: node.info.isHead ? .orange : .blue, active: node.up)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.info.id.rawValue).font(.app(.headline)).lineLimit(1)
                    if node.info.isHead { RowBadge("HEAD", tint: .orange) }
                }
                Text("\(node.info.address ?? "No address") · up \(StatFormat.duration(node.uptime))")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            UpDownPill(up: node.up)
        }
    }

    private func load(_ stats: NodeStats) -> String {
        stats.loadAverage.first.map { String(format: " · load %.2f", $0) } ?? ""
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

private struct UpDownPill: View {
    let up: Bool

    var body: some View {
        Label(up ? "Up" : "Down", systemImage: "circle.fill")
            .labelStyle(PillLabelStyle())
            .font(.app(.caption))
            .foregroundStyle(up ? .green : .red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((up ? Color.green : .red).opacity(0.15), in: Capsule())
    }

    private struct PillLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.font(.system(size: 6))
                configuration.title
            }
        }
    }
}

private struct BentoTileBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The largest tile: a ring plus the value, for CPU and memory.
private struct BentoRingTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let fraction: Double?
    var tint: Color?

    var body: some View {
        let color = tint ?? fraction.map(StatTile.color(for:)) ?? .secondary
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(max(fraction ?? 0, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 52)
            .animation(.snappy, value: fraction)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(.caption)).foregroundStyle(.secondary)
                Text(value)
                    .font(.app(.title2))
                    .fontWeight(.semibold)
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .modifier(BentoTileBackground())
    }
}

private struct BentoCountTile: View {
    let title: String
    let symbol: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol)
                .font(.app(.callout))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.app(.title))
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .modifier(BentoTileBackground())
    }
}

private struct BentoMiniTile: View {
    let title: String
    let value: String
    var detail: String?
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.app(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.app(.callout))
                .fontWeight(.medium)
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .modifier(BentoTileBackground())
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

#if DEBUG
#Preview("Bento") { NodesBentoView(nodes: ClusterModel.previewDegraded.nodes, open: { _ in }).frame(width: 1000, height: 600) }
#endif
