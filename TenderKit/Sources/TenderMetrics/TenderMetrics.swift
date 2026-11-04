import Foundation
import TenderCore

/// Everything `/metrics` reports, gathered at scrape time. Labels stay low-cardinality:
/// node, service, instance, never a pid.
public struct MetricsSnapshot: Sendable {
    public var nodes: [NodeSummary]
    public var processes: [InstanceStatus]
    public var linesIngested: [NodeID: UInt64]
    public var deploys: [DeployCount]

    public struct DeployCount: Sendable, Hashable {
        public var service: String
        public var result: String
        public var count: UInt64

        public init(service: String, result: String, count: UInt64) {
            self.service = service
            self.result = result
            self.count = count
        }
    }

    public init(nodes: [NodeSummary], processes: [InstanceStatus], linesIngested: [NodeID: UInt64], deploys: [DeployCount]) {
        self.nodes = nodes
        self.processes = processes
        self.linesIngested = linesIngested
        self.deploys = deploys
    }
}

/// Prometheus text exposition format. Values are derived from the snapshot at each
/// scrape, rather than kept in a registry, so a head restart can't make them drift.
public enum MetricsRenderer {
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private struct Family {
        var name: String
        var type: String
        var help: String
        var samples: [(labels: [(String, String)], value: Double)] = []
    }

    public static func render(_ snapshot: MetricsSnapshot) -> String {
        func family(_ name: String, _ type: String, _ help: String) -> Family {
            Family(name: name, type: type, help: help)
        }
        var up = family("tender_node_up", "gauge", "1 if the node's heartbeats are arriving.")
        var last = family("tender_node_last_heartbeat_seconds", "gauge", "Seconds since the node's last heartbeat.")
        var skew = family("tender_node_clock_skew_seconds", "gauge", "Head clock minus node clock.")
        var backlog = family("tender_log_spool_backlog", "gauge", "Lines waiting in the node's spool.")
        var dropped = family("tender_log_spool_dropped_total", "counter", "Lines dropped because the spool was over its limits.")
        var secretErrors = family("tender_secret_fetch_errors_total", "counter", "Failed GCP Secret Manager fetches since the node's daemon started.")
        for node in snapshot.nodes {
            let labels = [("node", node.info.id.rawValue)]
            up.samples.append((labels, node.up ? 1 : 0))
            if let age = node.lastHeartbeatAge { last.samples.append((labels, age)) }
            if let value = node.clockSkew { skew.samples.append((labels, value)) }
            backlog.samples.append((labels, Double(node.spoolBacklog)))
            dropped.samples.append((labels, Double(node.spoolDropped)))
            secretErrors.samples.append((labels, Double(node.secretFetchErrors)))
        }
        var processUp = family("tender_process_up", "gauge", "1 if the instance is running.")
        var restarts = family("tender_process_restarts_total", "counter", "launchd restarts since the job was loaded.")
        var cpu = family("tender_process_cpu_seconds_total", "counter", "CPU time of the current process.")
        var rss = family("tender_process_resident_bytes", "gauge", "Resident memory.")
        for process in snapshot.processes {
            let labels = [("node", process.node.rawValue), ("service", process.service), ("instance", String(process.instance))]
            processUp.samples.append((labels, process.state == .running ? 1 : 0))
            restarts.samples.append((labels, Double(process.restarts)))
            if let value = process.cpuSeconds { cpu.samples.append((labels, value)) }
            if let value = process.rss { rss.samples.append((labels, Double(value))) }
        }
        var ingested = family("tender_log_lines_ingested_total", "counter", "Log lines stored by the head.")
        for (node, count) in snapshot.linesIngested.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            ingested.samples.append(([("node", node.rawValue)], Double(count)))
        }
        var deploys = family("tender_release_deploys_total", "counter", "Release deployments by result.")
        for deploy in snapshot.deploys {
            deploys.samples.append(([("service", deploy.service), ("result", deploy.result)], Double(deploy.count)))
        }

        var output = ""
        for item in [up, last, skew, processUp, restarts, cpu, rss, ingested, backlog, dropped, secretErrors, deploys] {
            output += "# HELP \(item.name) \(item.help)\n# TYPE \(item.name) \(item.type)\n"
            for sample in item.samples {
                let labels = sample.labels.map { "\($0.0)=\"\(escaped($0.1))\"" }.joined(separator: ",")
                output += "\(item.name){\(labels)} \(sample.value)\n"
            }
        }
        return output
    }
}
