import Foundation
import TenderCore

/// Human-readable rendering of `ProcessList`, shared by the CLI and other clients.
public enum ProcessTable {
    /// `names` maps node IDs to hostnames (from `tender nodes`); a node missing from it
    /// shows a short form of its ID.
    public static func render(_ list: ProcessList, names: [NodeID: String] = [:]) -> String {
        func name(_ node: NodeID) -> String { names[node] ?? shortID(node) }
        var output: String
        if list.processes.isEmpty {
            output = "No processes."
        } else {
            let rows = [["SERVICE", "NODE", "INST", "STATE", "PID", "UPTIME", "CPU", "RSS", "RESTARTS", "RELEASE"]]
                + list.processes.map { row($0, node: name($0.node)) }
            output = aligned(rows)
        }
        if !list.unreachableNodes.isEmpty {
            output += "\n\nNot reachable, so their processes aren't listed: "
                + list.unreachableNodes.map { id in names[NodeID(id)].map { "\($0) (\(id))" } ?? id }.joined(separator: ", ")
        }
        if !list.orphans.isEmpty {
            output += "\n\nOrphaned launchd jobs (not in desired state):\n"
            output += list.orphans.map { "  \($0)" }.joined(separator: "\n")
        }
        return output
    }

    public static func render(_ list: NodeList) -> String {
        guard !list.nodes.isEmpty else { return "No nodes." }
        let rows = [["NODE", "ID", "STATE", "ADDRESS", "PROCESSES", "CRASHED", "LAST SEEN", "SKEW", "VERSION"]] + list.nodes.map { node in
            [
                node.info.displayName,
                node.info.id.rawValue,
                node.up ? "up" : "down",
                node.info.address ?? "-",
                String(node.instanceCount),
                String(node.crashedCount),
                node.lastHeartbeatAge.map { duration($0) + " ago" } ?? "-",
                node.clockSkew.map { String(format: "%.1fs", $0) } ?? "-",
                node.info.version,
            ]
        }
        var output = aligned(rows)
        let skewed = list.nodes.filter { abs($0.clockSkew ?? 0) > 1 }
        for node in skewed {
            output += String(format: "\nwarning: %@'s clock is off by %.1f s, so its log times are unreliable.",
                             node.info.displayName, node.clockSkew ?? 0)
        }
        for node in list.nodes where node.spoolDropped > 0 {
            output += "\nwarning: \(node.info.displayName) has dropped \(node.spoolDropped) log lines."
        }
        return output
    }

    private static func aligned(_ rows: [[String]]) -> String {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            zip(row, widths)
                .map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    public static func render(_ list: ReleaseList) -> String {
        guard !list.releases.isEmpty else { return "No releases." }
        let formatter = ISO8601DateFormatter()
        return list.releases.map { release in
            let marker = release.sha12 == list.current ? "* " : "  "
            return "\(marker)\(release.sha12)  \(formatter.string(from: release.createdAt))"
        }.joined(separator: "\n")
    }

    private static func row(_ status: InstanceStatus, node: String) -> [String] {
        [
            status.service,
            node,
            String(status.instance),
            status.state.rawValue,
            status.pid.map(String.init) ?? "-",
            status.uptime.map(duration) ?? "-",
            status.cpu.map { String(format: "%.1f%%", $0) } ?? "-",
            status.rss.map(bytes) ?? "-",
            String(status.restarts),
            status.release ?? "-",
        ]
    }

    /// A UUID node ID is shortened to its first group (use `tender nodes` for the rest).
    /// Hostnames by node ID. Only the head lists nodes, so this is empty for a worker's socket.
    public static func names(_ nodes: NodeList?) -> [NodeID: String] {
        Dictionary((nodes?.nodes ?? []).compactMap { node in node.info.hostname.map { (node.info.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    static func shortID(_ node: NodeID) -> String {
        UUID(uuidString: node.rawValue) != nil ? String(node.rawValue.prefix(8)) : node.rawValue
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86400 { return "\(total / 3600)h\(total % 3600 / 60)m" }
        return "\(total / 86400)d\(total % 86400 / 3600)h"
    }

    static func bytes(_ count: UInt64) -> String {
        let megabytes = Double(count) / 1_048_576
        return megabytes < 1024 ? String(format: "%.1fM", megabytes) : String(format: "%.1fG", megabytes / 1024)
    }
}

/// Log lines come from whatever the process printed. Control characters are shown as
/// `?` so that a line can't move the cursor, rewrite the screen or set the window title.
public func terminalSafe(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value) ? "?" : scalar
    }))
}
