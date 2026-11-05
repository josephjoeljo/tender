import SwiftUI
import TenderClient
import TenderCore

// List rows in the style of a music track list: artwork tile, title over a
// dimmed subtitle, then quiet trailing values and a "…" menu.

/// The rounded square at the start of a row, standing in for album artwork.
struct RowArtwork: View {
    let symbol: String
    let tint: Color
    /// Inactive rows (a node that's down, a stopped process) are drawn grey.
    var active = true

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: RowLayout.artwork, height: RowLayout.artwork)
            .saturation(active ? 1 : 0)
            .opacity(active ? 1 : 0.6)
    }
}

enum RowLayout {
    static let artwork: CGFloat = 40
    static let spacing: CGFloat = 12
    /// Where the title starts, so dropped-down panels and separators line up with it.
    static let textLeading = artwork + spacing
}

/// A small boxed label after a title, like the "explicit" mark on a track.
struct RowBadge: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.app(size: 9).bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct TrackRow<Artwork: View, Badges: View, Subtitle: View, Trailing: View, Actions: View>: View {
    let title: String
    @ViewBuilder let artwork: Artwork
    @ViewBuilder let badges: Badges
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: RowLayout.spacing) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.app(.body)).lineLimit(1)
                    badges
                }
                HStack(spacing: 0) { subtitle }
                    .font(.app(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) { trailing }
                .font(.app(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

// MARK: Nodes

extension NodeSummary {
    var uptime: TimeInterval? {
        stats.flatMap { stats in stats.bootTime.map { stats.sampledAt.timeIntervalSince($0) } }
    }
}

struct NodeTrackRow: View {
    let node: NodeSummary
    let open: () -> Void

    var body: some View {
        TrackRow(title: node.info.id.rawValue) {
            RowArtwork(symbol: node.info.isHead ? "crown.fill" : "desktopcomputer",
                       tint: node.info.isHead ? .orange : .blue, active: node.up)
                .help(node.info.isHead ? "Head" : "Worker")
        } badges: {
            if !node.up { RowBadge("DOWN", tint: .red) }
            if node.crashedCount > 0 { RowBadge("\(node.crashedCount) CRASHED", tint: .red) }
            if node.spoolDropped > 0 || abs(node.clockSkew ?? 0) > 1 { RowBadge("CHECK", tint: .orange) }
        } subtitle: {
            Text("\(node.info.address ?? "No address") – \(node.instanceCount) \(node.instanceCount == 1 ? "process" : "processes")")
        } trailing: {
            Text(StatFormat.percent(node.stats?.cpuPercent)).frame(width: 52, alignment: .trailing).help("CPU")
            Text(node.stats.map { "\(StatFormat.bytes($0.memoryUsed)) / \(StatFormat.bytes($0.memoryTotal))" } ?? StatFormat.dash)
                .frame(width: 130, alignment: .trailing).help("Memory")
            Text(StatFormat.duration(node.uptime)).frame(width: 64, alignment: .trailing).help("Uptime")
            Button(action: open) {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show this node's history")
        } actions: {
            Button("Show History", systemImage: "chart.xyaxis.line", action: open)
            Divider()
            Button("Copy Name") { copy(node.info.id.rawValue) }
            if let address = node.info.address {
                Button("Copy Address") { copy(address) }
            }
        }
    }
}

// MARK: Processes

extension ProcessKind {
    var title: String {
        switch self {
        case .server: "Server"
        case .gameServer: "Game server"
        case .database: "Database"
        case .cache: "Cache"
        case .queue: "Queue"
        case .worker: "Worker"
        case .scheduler: "Scheduler"
        case .proxy: "Proxy"
        case .model: "AI model"
        case .other: "Process"
        }
    }

    var symbol: String {
        switch self {
        case .server: "server.rack"
        case .gameServer: "gamecontroller.fill"
        case .database: "cylinder.split.1x2.fill"
        case .cache: "bolt.fill"
        case .queue: "tray.full.fill"
        case .worker: "hammer.fill"
        case .scheduler: "clock.fill"
        case .proxy: "arrow.triangle.branch"
        case .model: "brain"
        case .other: "terminal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .server: .blue
        case .gameServer: .purple
        case .database: .green
        case .cache: .red
        case .queue: .orange
        case .worker: .indigo
        case .scheduler: .teal
        case .proxy: .cyan
        case .model: .pink
        case .other: .gray
        }
    }
}

extension InstanceStatus {
    /// Older tenderds don't send a kind, so fall back to the same guess they'd make.
    var resolvedKind: ProcessKind { kind ?? .guess(from: service) }
}

struct ProcessTrackRow: View {
    let process: InstanceStatus
    let model: ClusterModel
    /// Show the instance number, for services that run more than one.
    var showsInstance = false

    var body: some View {
        let kind = process.resolvedKind
        TrackRow(title: showsInstance ? "\(process.service) #\(process.instance)" : process.service) {
            RowArtwork(symbol: kind.symbol, tint: kind.tint, active: process.state == .running)
                .help(kind.title)
        } badges: {
            if process.adopted { RowBadge("ADOPTED") }
        } subtitle: {
            Text("\(kind.title) – \(process.node.rawValue) · ")
            Text(process.state.rawValue)
                .foregroundStyle(process.state == .crashed ? .red : .secondary)
            if process.restarts > 0 {
                Text(" · \(process.restarts) \(process.restarts == 1 ? "restart" : "restarts")")
                    .foregroundStyle(.orange)
            }
        } trailing: {
            Text(StatFormat.percent(process.cpu)).frame(width: 52, alignment: .trailing).help("CPU")
            Text(StatFormat.bytes(process.stats?.footprint ?? process.rss)).frame(width: 70, alignment: .trailing).help("Memory")
            Text(StatFormat.duration(process.uptime)).frame(width: 64, alignment: .trailing).help("Uptime")
        } actions: {
            Button("Start", systemImage: "play.fill") { perform(.start) }.disabled(process.state == .running)
            Button("Stop", systemImage: "stop.fill") { perform(.stop) }.disabled(process.state == .stopped)
            Button("Restart", systemImage: "arrow.clockwise") { perform(.restart) }
            Divider()
            Button("Copy Name") { copy(process.service) }
        }
    }

    private func perform(_ action: ClusterModel.Action) {
        Task { await model.perform(action, on: process) }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
