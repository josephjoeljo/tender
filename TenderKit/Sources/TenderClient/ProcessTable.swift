import Foundation
import TenderCore

/// Human-readable rendering of `ProcessList`, shared by the CLI and other clients.
public enum ProcessTable {
    public static func render(_ list: ProcessList) -> String {
        var output: String
        if list.processes.isEmpty {
            output = "No processes."
        } else {
            let rows = [["SERVICE", "INST", "STATE", "PID", "UPTIME", "CPU", "RSS", "RESTARTS", "RELEASE"]]
                + list.processes.map(row)
            let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
            output = rows.map { row in
                zip(row, widths)
                    .map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                    .joined(separator: "  ")
                    .trimmingCharacters(in: .whitespaces)
            }.joined(separator: "\n")
        }
        if !list.orphans.isEmpty {
            output += "\n\nOrphaned launchd jobs (not in desired state):\n"
            output += list.orphans.map { "  \($0)" }.joined(separator: "\n")
        }
        return output
    }

    public static func render(_ list: ReleaseList) -> String {
        guard !list.releases.isEmpty else { return "No releases." }
        let formatter = ISO8601DateFormatter()
        return list.releases.map { release in
            let marker = release.sha12 == list.current ? "* " : "  "
            return "\(marker)\(release.sha12)  \(formatter.string(from: release.createdAt))"
        }.joined(separator: "\n")
    }

    private static func row(_ status: InstanceStatus) -> [String] {
        [
            status.service,
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
