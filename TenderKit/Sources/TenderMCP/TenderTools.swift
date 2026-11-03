import Foundation
import MCP
import Synchronization
import TenderCore

/// Who is calling a tool. On the head this is the API token; for `tender mcp` it is
/// the bridge, and the head checks the bridge's own token on every forwarded call.
public struct MCPCaller: Sendable, Equatable {
    public var name: String
    public var scope: APIScope

    public init(name: String, scope: APIScope) {
        self.name = name
        self.scope = scope
    }
}

/// One tool call, for the audit log. Arguments are the tool's own (names, versions,
/// limits); no tool takes a secret, so they are safe to record.
public struct ToolCallRecord: Sendable, Equatable {
    public var time: Date
    public var who: String
    public var tool: String
    public var arguments: String
    public var error: String?
    public var duration: TimeInterval
}

/// The MCP tools. Every response is bounded: lists are capped, log searches are
/// limited in lines and time, long lines are cut, and the whole text stays under
/// `maxResponseBytes`. Errors come first, so that a truncated response keeps them.
public final class TenderTools: Sendable {
    public static let maxResponseBytes = 60_000
    public static let maxLogLines = 500
    public static let defaultLogLines = 200
    public static let defaultLogWindow: TimeInterval = 15 * 60
    static let maxLineLength = 1_000
    static let maxListedProcesses = 300

    let backend: any ClusterBackend
    let onCall: @Sendable (ToolCallRecord) -> Void
    let limiter: WriteLimiter
    let now: @Sendable () -> Date

    public init(backend: any ClusterBackend, writesPerMinute: Int = 20,
                onCall: @escaping @Sendable (ToolCallRecord) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.backend = backend
        self.onCall = onCall
        self.limiter = WriteLimiter(perMinute: writesPerMinute)
        self.now = now
    }

    // MARK: Catalog

    static let readTools: Set<String> = [
        "list_nodes", "list_processes", "describe_process", "search_logs", "get_metrics_summary", "list_releases",
    ]
    static let writeTools: Set<String> = [
        "start_process", "stop_process", "restart_process", "deploy_release", "rollback_release",
    ]

    /// A read token sees only the read tools, so an agent isn't offered what it can't do.
    public func definitions(for caller: MCPCaller) -> [Tool] {
        Self.catalog.filter { caller.scope == .write || Self.readTools.contains($0.name) }
    }

    static let catalog: [Tool] = [
        Tool(name: "list_nodes",
             description: "Nodes in the cluster: up or down, seconds since the last heartbeat, instance and crash counts, clock skew against the head (seconds; above 1 s, cross-node log order is less reliable) and log spool backlog. Down nodes are listed first.",
             inputSchema: schema([:]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "list_processes",
             description: "Process instances across all nodes: service, node, instance, state, pid, uptime, restarts, release, CPU and memory. Crashed instances come first. At most \(maxListedProcesses) rows; filter by service, node or state to narrow it. `unreachableNodes` lists nodes that didn't answer, so the list may be incomplete.",
             inputSchema: schema([
                "service": string("Only this service (or adopted launchd label)."),
                "node": string("Only this node."),
                "state": .object(["type": "string", "enum": ["running", "starting", "stopped", "crashed", "unknown"],
                                  "description": "Only instances in this state."]),
             ]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "describe_process",
             description: "Everything about one service: its instances on every node, its releases per node (newest first, the current one marked), and its last 20 stderr lines from the past 15 minutes.",
             inputSchema: schema(["service": string("Service name or adopted launchd label.")], required: ["service"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "search_logs",
             description: "Searches stored log lines. Defaults: the last 15 minutes, \(defaultLogLines) lines (at most \(maxLogLines)). stderr lines are returned first, then stdout, each oldest first; lines longer than \(maxLineLength) characters are cut. `query` matches lines containing all its words. Order across nodes is approximate, since node clocks differ; `seq` orders lines within one node. `gaps` reports lines a node dropped while its spool was full.",
             inputSchema: schema([
                "service": string("Only this service."),
                "node": string("Only this node."),
                "query": string("Words that must all appear in the line."),
                "stream": .object(["type": "string", "enum": ["out", "err"], "description": "Only stdout or stderr."]),
                "since_minutes": .object(["type": "integer", "minimum": 1, "maximum": 10080,
                                          "description": "How far back to look, in minutes. Default 15."]),
                "limit": .object(["type": "integer", "minimum": 1, "maximum": .int(maxLogLines),
                                  "description": "Lines to return. Default \(defaultLogLines)."]),
             ]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "get_metrics_summary",
             description: "A compact health summary: node counts (up/down), and per service the instances running and crashed, total restarts, total CPU (percent of one core) and total memory (bytes). Use it before list_processes on a large cluster.",
             inputSchema: schema([:]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "list_releases",
             description: "Releases of a service on each node, newest first (at most 10 per node), with the one each node runs marked as current.",
             inputSchema: schema(["service": string("Service name.")], required: ["service"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "start_process",
             description: "Starts a stopped service, on one node or every node that has it. Idempotent. Needs a write token. With dry_run, returns what would happen and changes nothing.",
             inputSchema: writeSchema([:]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "stop_process",
             description: "Stops a service, on one node or every node running it. It stays stopped until started; launchd won't restart it. Idempotent. Needs a write token. With dry_run, returns what would happen and changes nothing.",
             inputSchema: writeSchema([:]),
             annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
        Tool(name: "restart_process",
             description: "Restarts a service (and starts it if stopped), on one node or every node running it. Instances restart at once, not one by one. Needs a write token. With dry_run, returns what would happen and changes nothing.",
             inputSchema: writeSchema([:]),
             annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)),
        Tool(name: "deploy_release",
             description: "Deploys a release version from the configured bucket: each node running the service downloads it, verifies its sha256 and restarts on it. Reports each node's result. Needs a write token. With dry_run, returns the nodes that would deploy and changes nothing.",
             inputSchema: writeSchema(["version": string("Release version to deploy.")], required: ["version"]),
             annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true)),
        Tool(name: "rollback_release",
             description: "Rolls a service back to its previous release, or to the release `to` (a sha12 from list_releases), on one node or every node running it. Needs a write token. With dry_run, returns what would happen and changes nothing.",
             inputSchema: writeSchema(["to": string("sha12 of the release to go back to. Default: the previous one.")]),
             annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)),
    ]

    static func string(_ description: String) -> Value {
        .object(["type": "string", "description": .string(description)])
    }

    static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        return .object(object)
    }

    static func writeSchema(_ extra: [String: Value], required: [String] = []) -> Value {
        var properties = extra
        properties["service"] = string("Service name or adopted launchd label.")
        properties["node"] = string("Only this node. Default: every node running the service.")
        properties["dry_run"] = .object(["type": "boolean", "description": "Report what would happen without doing it."])
        return schema(properties, required: ["service"] + required)
    }

    // MARK: Calls

    /// Never throws: failures come back as an error result the agent can read.
    public func call(_ name: String, arguments: [String: Value], caller: MCPCaller) async -> CallTool.Result {
        let started = now()
        var failure: String?
        let result: CallTool.Result
        do {
            let text = try await run(name, Arguments(arguments), caller: caller)
            result = .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            failure = Self.describe(error)
            result = .init(content: [.text(text: "error: \(failure!)", annotations: nil, _meta: nil)], isError: true)
        }
        onCall(ToolCallRecord(time: started, who: caller.name, tool: name, arguments: Self.compact(arguments),
                              error: failure, duration: now().timeIntervalSince(started)))
        return result
    }

    func run(_ name: String, _ arguments: Arguments, caller: MCPCaller) async throws -> String {
        if Self.writeTools.contains(name) {
            guard caller.scope == .write else {
                throw ToolError("\(name) needs a write token. This token is read-only.")
            }
            if !arguments.bool("dry_run"), !limiter.allow(caller.name, now: now()) {
                throw ToolError("Too many changes: at most \(limiter.perMinute) write calls per minute per token. Try again shortly.")
            }
        } else if !Self.readTools.contains(name) {
            throw ToolError("Unknown tool '\(name)'.")
        }
        try arguments.rejectUnknown(allowed: Self.allowedArguments(name))
        switch name {
        case "list_nodes": return try await listNodes()
        case "list_processes": return try await listProcesses(arguments)
        case "describe_process": return try await describeProcess(try arguments.required("service"))
        case "search_logs": return try await searchLogs(arguments)
        case "get_metrics_summary": return try await metricsSummary()
        case "list_releases": return try await listReleases(try arguments.required("service"))
        default: return try await write(name, arguments)
        }
    }

    static func allowedArguments(_ tool: String) -> Set<String> {
        guard let definition = catalog.first(where: { $0.name == tool }),
              let properties = definition.inputSchema.objectValue?["properties"]?.objectValue else { return [] }
        return Set(properties.keys)
    }

    func listNodes() async throws -> String {
        var nodes = try await backend.nodes().nodes
        nodes.sort { ($0.up ? 1 : 0, $0.info.id.rawValue) < ($1.up ? 1 : 0, $1.info.id.rawValue) }
        return try Self.render(NodesOutput(nodes: nodes.map(NodeRow.init)))
    }

    func listProcesses(_ arguments: Arguments) async throws -> String {
        let list = try await backend.processes()
        var rows = list.processes
        if let service = arguments.string("service") { rows = rows.filter { $0.service == service } }
        if let node = arguments.string("node") { rows = rows.filter { $0.node.rawValue == node } }
        if let state = arguments.string("state") { rows = rows.filter { $0.state.rawValue == state } }
        rows.sort { (Self.rank($0.state), $0.service, $0.node.rawValue, $0.instance)
            < (Self.rank($1.state), $1.service, $1.node.rawValue, $1.instance) }
        let total = rows.count
        rows = Array(rows.prefix(Self.maxListedProcesses))
        return try Self.render(ProcessesOutput(
            unreachableNodes: list.unreachableNodes, total: total,
            truncated: total > rows.count ? "Showing \(rows.count) of \(total). Filter by service, node or state." : nil,
            processes: rows.map(ProcessRow.init)))
    }

    func describeProcess(_ service: String) async throws -> String {
        async let list = backend.processes()
        async let releases = backend.releases(service: service)
        async let errors = backend.searchLogs(LogQuery(service: service, stream: .err,
                                                        since: now().addingTimeInterval(-Self.defaultLogWindow), limit: 20))
        let processes = try await list
        let instances = processes.processes.filter { $0.service == service }
        guard !instances.isEmpty else {
            throw ToolError("No service or adopted job named '\(service)'. Use list_processes to see the names.")
        }
        // A worker-only bridge has no log store or cluster releases; describe what there is.
        let releaseRows = (try? await releases)?.nodes.map(ReleasesRow.init) ?? []
        let errorLines = (try? await errors)?.entries.map(LogRow.init) ?? []
        return try Self.render(DescribeOutput(
            service: service, unreachableNodes: processes.unreachableNodes,
            recentErrors: errorLines, instances: instances.map(ProcessRow.init), releases: releaseRows))
    }

    func searchLogs(_ arguments: Arguments) async throws -> String {
        let limit = min(max(try arguments.int("limit") ?? Self.defaultLogLines, 1), Self.maxLogLines)
        let minutes = min(max(try arguments.int("since_minutes") ?? 15, 1), 10_080)
        var stream: LogLine.Stream?
        if let raw = arguments.string("stream") {
            guard let parsed = LogLine.Stream(rawValue: raw) else { throw ToolError("stream must be out or err.") }
            stream = parsed
        }
        let query = LogQuery(service: arguments.string("service"), node: arguments.string("node"), stream: stream,
                             since: now().addingTimeInterval(-Double(minutes) * 60), text: arguments.string("query"),
                             limit: limit)
        let result = try await backend.searchLogs(query)
        let rows = result.entries.map(LogRow.init)
        return try Self.render(LogsOutput(
            window: "last \(minutes) min", gaps: result.gaps.map(GapRow.init),
            errors: rows.filter { $0.stream == "err" }, output: rows.filter { $0.stream == "out" },
            note: rows.count == limit ? "Hit the limit of \(limit) lines; narrow the query or the window." : nil))
    }

    func metricsSummary() async throws -> String {
        async let nodes = backend.nodes()
        async let processes = backend.processes()
        let nodeList = try await nodes.nodes
        let list = try await processes
        var services: [String: ServiceSummary] = [:]
        for row in list.processes {
            var summary = services[row.service] ?? ServiceSummary(service: row.service)
            summary.instances += 1
            if row.state == .running { summary.running += 1 }
            if row.state == .crashed { summary.crashed += 1 }
            summary.restarts += row.restarts
            summary.cpuPercent += row.cpu ?? 0
            summary.memoryBytes += row.rss ?? 0
            services[row.service] = summary
        }
        let sorted = services.values.sorted { ($0.crashed == 0 ? 1 : 0, $0.service) < ($1.crashed == 0 ? 1 : 0, $1.service) }
        return try Self.render(MetricsOutput(
            nodesUp: nodeList.filter(\.up).count, nodesDown: nodeList.filter { !$0.up }.map(\.info.id.rawValue),
            unreachableNodes: list.unreachableNodes,
            services: Array(sorted.prefix(Self.maxListedProcesses)).map { summary in
                var rounded = summary
                rounded.cpuPercent = (summary.cpuPercent * 10).rounded() / 10
                return rounded
            }))
    }

    func listReleases(_ service: String) async throws -> String {
        let releases = try await backend.releases(service: service)
        guard !releases.nodes.isEmpty else { throw ToolError("No releases of '\(service)' on any node.") }
        return try Self.render(ReleasesOutput(service: service, nodes: releases.nodes.map(ReleasesRow.init)))
    }

    func write(_ name: String, _ arguments: Arguments) async throws -> String {
        let service = try arguments.required("service")
        let node = arguments.string("node")
        if arguments.bool("dry_run") { return try await plan(name, service: service, node: node, arguments) }
        switch name {
        case "start_process": return try await processResult(try await backend.start(service: service, node: node), service)
        case "stop_process": return try await processResult(try await backend.stop(service: service, node: node), service)
        case "restart_process": return try await processResult(try await backend.restart(service: service, node: node), service)
        case "rollback_release":
            return try await processResult(
                try await backend.rollback(service: service, to: arguments.string("to"), node: node), service)
        default:
            let response = try await backend.deploy(
                DeployRequest(service: service, version: try arguments.required("version"), node: node))
            let failed = response.outcomes.filter { $0.error != nil }
            return try Self.render(DeployOutput(
                failed: failed.map(DeployRow.init), succeeded: response.outcomes.filter { $0.error == nil }.map(DeployRow.init)))
        }
    }

    func processResult(_ list: ProcessList, _ service: String) async throws -> String {
        let instances = list.processes.filter { $0.service == service }
        return try Self.render(ProcessesOutput(unreachableNodes: list.unreachableNodes, total: instances.count,
                                               truncated: nil, processes: instances.map(ProcessRow.init)))
    }

    /// What a write would touch, from the current process list. Nothing is changed.
    func plan(_ name: String, service: String, node: String?, _ arguments: Arguments) async throws -> String {
        let list = try await backend.processes()
        var instances = list.processes.filter { $0.service == service }
        if let node { instances = instances.filter { $0.node.rawValue == node } }
        let nodes = Array(Set(instances.map(\.node.rawValue))).sorted()
        let verb = switch name {
        case "start_process": "start"
        case "stop_process": "stop"
        case "restart_process": "restart"
        case "deploy_release": "deploy \(try arguments.required("version")) of"
        default: "roll back" + (arguments.string("to").map { " to \($0)" } ?? " to the previous release of")
        }
        let summary: String
        if nodes.isEmpty {
            summary = name == "start_process"
                ? "Would \(verb) '\(service)' on \(node ?? "the head") if it exists there; no instance of it is listed now."
                : "Nothing to do: no instance of '\(service)'\(node.map { " on \($0)" } ?? "") is listed."
        } else {
            summary = "Would \(verb) '\(service)' on \(nodes.joined(separator: ", ")) (\(instances.count) instance\(instances.count == 1 ? "" : "s"))."
        }
        return try Self.render(PlanOutput(dryRun: true, plan: summary, unreachableNodes: list.unreachableNodes,
                                          instances: instances.map(ProcessRow.init)))
    }

    // MARK: Rendering

    static func rank(_ state: InstanceState) -> Int {
        switch state {
        case .crashed: 0
        case .unknown: 1
        case .stopped: 2
        default: 3
        }
    }

    /// Compact JSON, cut to `maxResponseBytes` on a line boundary with a note saying so.
    static func render(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        return bounded(text)
    }

    static func bounded(_ text: String, limit: Int = maxResponseBytes) -> String {
        guard text.utf8.count > limit else { return text }
        var kept: [Substring] = []
        var size = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            size += line.utf8.count + 1
            if size > limit - 200 { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
            + "\n… truncated at \(limit) bytes. The JSON above is incomplete; narrow the request (filters, limit, window)."
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ToolError { return error.message }
        return String(describing: error)
    }

    static func compact(_ arguments: [String: Value]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = (try? encoder.encode(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    static func cut(_ line: String) -> String {
        line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "… [cut]" : line
    }
}

struct ToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Typed reads of a tool's arguments, with clear errors for the agent.
struct Arguments {
    let values: [String: Value]
    init(_ values: [String: Value]) { self.values = values }

    func string(_ key: String) -> String? {
        guard let value = values[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError("'\(key)' is required.") }
        return value
    }

    func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .int(let value)?: return value
        case .double(let value)? where value.rounded() == value: return Int(value)
        case .string(let raw)?:
            guard let value = Int(raw) else { throw ToolError("'\(key)' must be an integer.") }
            return value
        default: throw ToolError("'\(key)' must be an integer.")
        }
    }

    func bool(_ key: String) -> Bool {
        switch values[key] {
        case .bool(let value)?: value
        case .string(let raw)?: raw == "true"
        default: false
        }
    }

    func rejectUnknown(allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw ToolError("Unknown argument\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", ")). Allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
    }
}

/// A sliding one-minute window per caller, for write tools only.
final class WriteLimiter: Sendable {
    let perMinute: Int
    private let calls = Mutex<[String: [Date]]>([:])

    init(perMinute: Int) { self.perMinute = perMinute }

    func allow(_ caller: String, now: Date) -> Bool {
        calls.withLock { calls in
            var recent = (calls[caller] ?? []).filter { now.timeIntervalSince($0) < 60 }
            guard recent.count < perMinute else {
                calls[caller] = recent
                return false
            }
            recent.append(now)
            calls[caller] = recent
            return true
        }
    }
}

// MARK: Output shapes

struct NodeRow: Encodable {
    var node: String
    var up: Bool
    var head: Bool
    var lastHeartbeatSecondsAgo: Int?
    var instances: Int
    var crashed: Int
    var clockSkewSeconds: Double?
    var spoolBacklog: Int
    var spoolDropped: Int

    init(_ summary: NodeSummary) {
        node = summary.info.id.rawValue
        up = summary.up
        head = summary.info.isHead
        lastHeartbeatSecondsAgo = summary.lastHeartbeatAge.map { Int($0.rounded()) }
        instances = summary.instanceCount
        crashed = summary.crashedCount
        clockSkewSeconds = summary.clockSkew.map { ($0 * 1000).rounded() / 1000 }
        spoolBacklog = summary.spoolBacklog
        spoolDropped = summary.spoolDropped
    }
}

struct NodesOutput: Encodable { var nodes: [NodeRow] }

struct ProcessRow: Encodable {
    var service: String
    var node: String
    var instance: Int
    var state: String
    var pid: Int32?
    var lastExitCode: Int32?
    var uptimeSeconds: Int?
    var restarts: Int
    var release: String?
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    var adopted: Bool?

    init(_ status: InstanceStatus) {
        service = status.service
        node = status.node.rawValue
        instance = status.instance
        state = status.state.rawValue
        pid = status.pid
        lastExitCode = status.lastExitCode
        uptimeSeconds = status.uptime.map { Int($0) }
        restarts = status.restarts
        release = status.release
        cpuPercent = status.cpu.map { ($0 * 10).rounded() / 10 }
        memoryBytes = status.rss
        adopted = status.adopted ? true : nil
    }
}

struct ProcessesOutput: Encodable {
    var unreachableNodes: [String]
    var total: Int
    var truncated: String?
    var processes: [ProcessRow]
}

struct LogRow: Encodable {
    var time: Date
    var node: String
    var seq: UInt64
    var service: String
    var instance: Int
    var stream: String
    var line: String

    init(_ entry: LogEntry) {
        time = entry.nodeTime
        node = entry.node.rawValue
        seq = entry.seq
        service = entry.service
        instance = entry.instance
        stream = entry.stream.rawValue
        line = TenderTools.cut(entry.line)
    }
}

struct GapRow: Encodable {
    var node: String?
    var droppedLines: Int
    var recordedAt: Date

    init(_ gap: LogGap) {
        node = gap.node?.rawValue
        droppedLines = gap.droppedLines
        recordedAt = gap.recordedAt
    }
}

struct LogsOutput: Encodable {
    var window: String
    var gaps: [GapRow]
    var errors: [LogRow]
    var output: [LogRow]
    var note: String?
}

struct ReleaseRow: Encodable {
    var sha12: String
    var createdAt: Date
    var current: Bool
}

struct ReleasesRow: Encodable {
    var node: String
    var releases: [ReleaseRow]

    init(_ node: NodeReleases) {
        self.node = node.node.rawValue
        releases = node.releases.releases.prefix(10).map {
            ReleaseRow(sha12: $0.sha12, createdAt: $0.createdAt, current: $0.sha12 == node.releases.current)
        }
    }
}

struct ReleasesOutput: Encodable {
    var service: String
    var nodes: [ReleasesRow]
}

struct DescribeOutput: Encodable {
    var service: String
    var unreachableNodes: [String]
    var recentErrors: [LogRow]
    var instances: [ProcessRow]
    var releases: [ReleasesRow]
}

struct ServiceSummary: Encodable {
    var service: String
    var instances = 0
    var running = 0
    var crashed = 0
    var restarts = 0
    var cpuPercent = 0.0
    var memoryBytes: UInt64 = 0
}

struct MetricsOutput: Encodable {
    var nodesUp: Int
    var nodesDown: [String]
    var unreachableNodes: [String]
    var services: [ServiceSummary]
}

struct DeployRow: Encodable {
    var node: String
    var sha12: String?
    var error: String?

    init(_ outcome: DeployOutcome) {
        node = outcome.node.rawValue
        sha12 = outcome.sha12
        error = outcome.error
    }
}

struct DeployOutput: Encodable {
    var failed: [DeployRow]
    var succeeded: [DeployRow]
}

struct PlanOutput: Encodable {
    var dryRun: Bool
    var plan: String
    var unreachableNodes: [String]
    var instances: [ProcessRow]
}
