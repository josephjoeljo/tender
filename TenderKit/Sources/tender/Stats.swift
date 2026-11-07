import ArgumentParser
import Foundation
import TenderClient
import TenderCore

extension Tender {
    struct Stats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show one instance's resource history, as the head recorded it.",
            discussion: "Averages per point, oldest first. The head keeps every heartbeat for an hour, minutes for 2 days, quarter hours for 35 days and hours for as long as `tender retention` says (190 days by default).")

        @Argument(help: "Service name, or an adopted job's label.") var name: String
        @Option(help: "Node the service runs on. Needed when it runs on more than one.") var node: String?
        @Option(help: "Instance. Defaults to the lowest.") var instance: Int?
        @Option(help: "How far back, like 30m, 1h, 7d or 180d.") var since = "1h"
        @Option(help: "Most points to return; neighbours are merged to fit (the head caps it at 2000).") var limit = 60
        @OptionGroup var options: CommonOptions

        func validate() throws {
            guard limit > 0 else { throw ValidationError("--limit must be positive.") }
        }

        func run() async throws {
            let start = try Logs.parseSince(since)
            try await options.run({ client in
                try await client.processHistory(service: name, node: node, instance: instance, since: start, limit: limit)
            }, text: Self.render)
        }

        static func render(_ history: ProcessStatsHistory) -> String {
            var lines = ["\(history.service)[\(history.instance)] on \(history.node): \(history.points.count) points"
                         + (history.downsampled ? " (merged to fit)" : "")]
            guard !history.points.isEmpty else { return lines[0] }
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            let header = ["TIME", "CPU%", "MEM", "READ/S", "WRITE/S", "GPU%", "WATTS", "FILES", "RESTARTS"]
            var rows = [header]
            for point in history.points {
                rows.append([
                    formatter.string(from: point.date) + (point.down ? "*" : ""),
                    point.cpuPercent.map { String(format: "%.1f", $0) } ?? "-",
                    point.memory.map(bytes) ?? "-",
                    point.diskReadRate.map(bytes) ?? "-",
                    point.diskWriteRate.map(bytes) ?? "-",
                    point.gpuPercent.map { String(format: "%.1f", $0) } ?? "-",
                    point.power.map { String(format: "%.2f", $0) } ?? "-",
                    point.openFiles.map { String(Int($0.rounded())) } ?? "-",
                    String(point.restarts),
                ])
            }
            let widths = header.indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
            for row in rows {
                lines.append(row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                    .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
            }
            if history.points.contains(where: \.down) { lines.append("* not running for some of this point") }
            return lines.joined(separator: "\n")
        }

        private static func bytes(_ value: Double) -> String {
            let units = ["B", "K", "M", "G", "T"]
            var amount = value
            var unit = 0
            while amount >= 1024, unit < units.count - 1 {
                amount /= 1024
                unit += 1
            }
            return unit == 0 ? "\(Int(amount))B" : String(format: "%.1f%@", amount, units[unit])
        }
    }
}

extension Tender {
    struct Retention: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or change how long the head keeps stats history.",
            discussion: "With no options, shows the current setting. Changing it needs a write token and prunes older points right away. Minutes are kept for 2 days and quarter hours for 35 days at most; hours for the whole retention.")

        @Option(help: "Days of node history to keep, 1 to 730.") var nodes: Int?
        @Option(help: "Days of process history to keep, 1 to 730.") var processes: Int?
        @OptionGroup var options: CommonOptions

        func validate() throws {
            for days in [nodes, processes].compactMap({ $0 }) where !HistoryRetention.allowedDays.contains(days) {
                throw ValidationError("Retention must be 1 to 730 days.")
            }
        }

        func run() async throws {
            try await options.run({ client in
                if nodes == nil, processes == nil { return try await client.historyRetention() }
                return try await client.setHistoryRetention(HistoryRetentionUpdate(nodeDays: nodes, processDays: processes))
            }, text: { "Node history: \($0.nodeDays) days\nProcess history: \($0.processDays) days" })
        }
    }
}
