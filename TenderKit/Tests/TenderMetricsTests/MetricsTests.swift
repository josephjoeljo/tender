import Foundation
import Testing
import TenderCore
@testable import TenderMetrics

@Test func rendersEveryDesignedMetric() {
    let node = NodeSummary(info: NodeInfo(id: NodeID("mac-2"), version: "1", macOS: "x", hardware: "y"), up: true,
                           lastHeartbeatAge: 1.5, instanceCount: 1, crashedCount: 0, clockSkew: 0.25, spoolBacklog: 7, spoolDropped: 3)
    let process = InstanceStatus(service: "api", instance: 0, node: NodeID("mac-2"), state: .running, pid: 99, restarts: 2,
                                 cpu: 5, rss: 1024, cpuSeconds: 9.5)
    let text = MetricsRenderer.render(MetricsSnapshot(
        nodes: [node], processes: [process], linesIngested: [NodeID("mac-2"): 42],
        deploys: [.init(service: "api", result: "success", count: 1)]))
    for line in [
        #"tender_node_up{node="mac-2"} 1.0"#,
        #"tender_node_last_heartbeat_seconds{node="mac-2"} 1.5"#,
        #"tender_node_clock_skew_seconds{node="mac-2"} 0.25"#,
        #"tender_process_up{node="mac-2",service="api",instance="0"} 1.0"#,
        #"tender_process_restarts_total{node="mac-2",service="api",instance="0"} 2.0"#,
        #"tender_process_cpu_seconds_total{node="mac-2",service="api",instance="0"} 9.5"#,
        #"tender_process_resident_bytes{node="mac-2",service="api",instance="0"} 1024.0"#,
        #"tender_log_lines_ingested_total{node="mac-2"} 42.0"#,
        #"tender_log_spool_backlog{node="mac-2"} 7.0"#,
        #"tender_log_spool_dropped_total{node="mac-2"} 3.0"#,
        #"tender_release_deploys_total{service="api",result="success"} 1.0"#,
        "# TYPE tender_process_restarts_total counter",
        "# TYPE tender_node_up gauge",
    ] {
        #expect(text.contains(line), "missing \(line)")
    }
    #expect(!text.contains("99"), "no pids in labels or values")
}

@Test func labelValuesAreEscaped() {
    #expect(MetricsRenderer.escaped("a\"b\\c\nd") == #"a\"b\\c\nd"#)
    let process = InstanceStatus(service: "x\"} evil 1\n", instance: 0, node: NodeID("n"), state: .stopped)
    let text = MetricsRenderer.render(MetricsSnapshot(nodes: [], processes: [process], linesIngested: [:], deploys: []))
    let lines = text.split(separator: "\n").filter { $0.hasPrefix("tender_process_up") }
    #expect(lines.count == 1, "a label must not be able to inject a metric line")
}
