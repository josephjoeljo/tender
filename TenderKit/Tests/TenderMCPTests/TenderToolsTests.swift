import Foundation
import MCP
import Synchronization
import Testing
import TenderCore
@testable import TenderMCP

/// Records what the tools asked for, and answers with canned data.
final class FakeBackend: ClusterBackend, @unchecked Sendable {
    let calls = Mutex<[String]>([])
    let queries = Mutex<[LogQuery]>([])
    var processList = ProcessList(processes: [
        InstanceStatus(service: "api", instance: 0, node: NodeID("mac-1"), state: .running, pid: 10, restarts: 1, cpu: 1.25, rss: 100),
        InstanceStatus(service: "api", instance: 1, node: NodeID("mac-2"), state: .crashed, lastExitCode: 1, restarts: 4, rss: 50),
        InstanceStatus(service: "worker", instance: 0, node: NodeID("mac-1"), state: .running, pid: 11),
    ])
    var logEntries: [LogEntry] = []

    private func record(_ call: String) { calls.withLock { $0.append(call) } }

    func nodes() async throws -> NodeList {
        NodeList(nodes: [
            NodeSummary(info: NodeInfo(id: NodeID("mac-1"), version: "1", macOS: "15", hardware: "Mac"), up: true, lastHeartbeatAge: 2,
                        instanceCount: 2, crashedCount: 0),
            NodeSummary(info: NodeInfo(id: NodeID("mac-2"), version: "1", macOS: "15", hardware: "Mac"), up: false, lastHeartbeatAge: 90,
                        instanceCount: 1, crashedCount: 1),
        ])
    }
    func processes() async throws -> ProcessList { processList }
    func searchLogs(_ query: LogQuery) async throws -> LogSearchResult {
        queries.withLock { $0.append(query) }
        return LogSearchResult(entries: logEntries)
    }
    func releases(service: String) async throws -> ClusterReleases {
        ClusterReleases(service: service, nodes: [NodeReleases(node: NodeID("mac-1"), releases: ReleaseList(
            releases: [Release(service: service, sha12: "aaaaaaaaaaaa", path: "/x", createdAt: Date(timeIntervalSince1970: 0))],
            current: "aaaaaaaaaaaa"))])
    }
    func start(service: String, node: String?) async throws -> ProcessList { record("start \(service)"); return processList }
    func stop(service: String, node: String?) async throws -> ProcessList { record("stop \(service) \(node ?? "-")"); return processList }
    func restart(service: String, node: String?) async throws -> ProcessList { record("restart \(service)"); return processList }
    func deploy(_ request: DeployRequest) async throws -> DeployResponse {
        record("deploy \(request.service) \(request.version)")
        return DeployResponse(outcomes: [DeployOutcome(node: NodeID("mac-1"), sha12: "bbbbbbbbbbbb"),
                                         DeployOutcome(node: NodeID("mac-2"), error: "download failed")])
    }
    func rollback(service: String, to sha12: String?, node: String?) async throws -> ProcessList {
        record("rollback \(service)")
        return processList
    }
    func secrets() async throws -> SecretList {
        SecretList(secrets: [
            SecretInfo(name: "api/MONGO_PASSWORD", scope: .service, node: NodeID("mac-1"),
                       updatedAt: Date(timeIntervalSince1970: 0), revision: 3, usedBy: ["api"]),
            SecretInfo(name: "worker/TOKEN", scope: .service, node: NodeID("mac-1"),
                       updatedAt: Date(timeIntervalSince1970: 0), revision: 1, usedBy: ["worker"]),
        ], missing: ["mac-2: api: JWT_KEY"])
    }
}

let reader = MCPCaller(name: "reader", scope: .read)
let writer = MCPCaller(name: "writer", scope: .write)

func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
}

@Test func readTokensAreOfferedOnlyReadTools() {
    let tools = TenderTools(backend: FakeBackend())
    let read = Set(tools.definitions(for: reader).map(\.name))
    #expect(read == TenderTools.readTools)
    #expect(Set(tools.definitions(for: writer).map(\.name)) == TenderTools.readTools.union(TenderTools.writeTools))
}

@Test func everySchemaIsAClosedObject() throws {
    for tool in TenderTools.catalog {
        let schema = try #require(tool.inputSchema.objectValue, "\(tool.name)")
        #expect(schema["type"] == "object", "\(tool.name)")
        #expect(schema["additionalProperties"] == false, "\(tool.name)")
        #expect(tool.description?.isEmpty == false)
        #expect(tool.annotations.readOnlyHint == TenderTools.readTools.contains(tool.name), "\(tool.name)")
    }
}

@Test func writeToolsRefuseReadTokens() async {
    let backend = FakeBackend()
    let tools = TenderTools(backend: backend)
    let result = await tools.call("stop_process", arguments: ["service": "api"], caller: reader)
    #expect(result.isError == true)
    #expect(text(result).contains("write token"))
    #expect(backend.calls.withLock { $0 }.isEmpty)
}

@Test func unknownToolsAndArgumentsAreRefused() async {
    let tools = TenderTools(backend: FakeBackend())
    #expect(await tools.call("rm_rf", arguments: [:], caller: writer).isError == true)
    let result = await tools.call("list_processes", arguments: ["servcie": "api"], caller: reader)
    #expect(result.isError == true)
    #expect(text(result).contains("servcie"))
}

@Test func processesListCrashedFirstAndFilter() async {
    let tools = TenderTools(backend: FakeBackend())
    let all = text(await tools.call("list_processes", arguments: [:], caller: reader))
    let crashed = try? #require(all.range(of: #""state" : "crashed""#))
    let running = try? #require(all.range(of: #""state" : "running""#))
    #expect(crashed!.lowerBound < running!.lowerBound)
    let worker = text(await tools.call("list_processes", arguments: ["service": "worker"], caller: reader))
    #expect(worker.contains(#""total" : 1"#))
}

@Test func logSearchIsBoundedAndPutsErrorsFirst() async throws {
    let backend = FakeBackend()
    let fixed = Date(timeIntervalSince1970: 1_000_000)
    backend.logEntries = [
        LogEntry(node: NodeID("mac-1"), seq: 1, nodeTime: fixed, ingestTime: fixed, service: "api", instance: 0, stream: .out, line: "hello"),
        LogEntry(node: NodeID("mac-1"), seq: 2, nodeTime: fixed, ingestTime: fixed, service: "api", instance: 0, stream: .err,
                 line: String(repeating: "x", count: 5_000)),
    ]
    let tools = TenderTools(backend: backend, now: { fixed })
    let result = text(await tools.call("search_logs", arguments: ["service": "api", "limit": 100_000], caller: reader))
    let query = try #require(backend.queries.withLock { $0.first })
    #expect(query.limit == TenderTools.maxLogLines)
    #expect(query.since == fixed.addingTimeInterval(-TenderTools.defaultLogWindow))
    #expect(result.range(of: "\"errors\"")!.lowerBound < result.range(of: "\"output\"")!.lowerBound)
    #expect(result.contains("[cut]"))
    #expect(!result.contains(String(repeating: "x", count: 1_001)))
}

@Test func responsesAreCutToTheByteLimit() {
    let long = (0..<10_000).map { "line \($0)" }.joined(separator: "\n")
    let bounded = TenderTools.bounded(long, limit: 2_000)
    #expect(bounded.utf8.count <= 2_000)
    #expect(bounded.contains("truncated"))
    #expect(TenderTools.bounded("short", limit: 2_000) == "short")
}

@Test func dryRunChangesNothingAndDescribesThePlan() async {
    let backend = FakeBackend()
    let tools = TenderTools(backend: backend)
    let result = text(await tools.call("stop_process", arguments: ["service": "api", "dry_run": true], caller: writer))
    #expect(result.contains("Would stop 'api' on mac-1, mac-2 (2 instances)."))
    #expect(backend.calls.withLock { $0 }.isEmpty)
    let deploy = text(await tools.call("deploy_release", arguments: ["service": "api", "version": "v2", "dry_run": true],
                                       caller: writer))
    #expect(deploy.contains("Would deploy v2 of 'api'"))
}

@Test func writesCallTheBackendAndDeployReportsFailuresFirst() async {
    let backend = FakeBackend()
    let tools = TenderTools(backend: backend)
    _ = await tools.call("stop_process", arguments: ["service": "api", "node": "mac-2"], caller: writer)
    let deploy = text(await tools.call("deploy_release", arguments: ["service": "api", "version": "v2"], caller: writer))
    #expect(backend.calls.withLock { $0 } == ["stop api mac-2", "deploy api v2"])
    #expect(deploy.range(of: "\"failed\"")!.lowerBound < deploy.range(of: "\"succeeded\"")!.lowerBound)
    #expect(deploy.contains("download failed"))
}

@Test func writesAreRateLimitedPerCaller() async {
    let backend = FakeBackend()
    let tools = TenderTools(backend: backend, writesPerMinute: 2)
    for _ in 0..<2 { #expect(await tools.call("restart_process", arguments: ["service": "api"], caller: writer).isError == false) }
    let limited = await tools.call("restart_process", arguments: ["service": "api"], caller: writer)
    #expect(limited.isError == true)
    #expect(text(limited).contains("per minute"))
    // Dry runs and other callers aren't held back.
    #expect(await tools.call("restart_process", arguments: ["service": "api", "dry_run": true], caller: writer).isError == false)
    let other = MCPCaller(name: "other", scope: .write)
    #expect(await tools.call("restart_process", arguments: ["service": "api"], caller: other).isError == false)
}

@Test func everyCallIsReportedForTheAuditLog() async {
    let records = Mutex<[ToolCallRecord]>([])
    let tools = TenderTools(backend: FakeBackend(), onCall: { record in records.withLock { $0.append(record) } })
    _ = await tools.call("list_nodes", arguments: [:], caller: reader)
    _ = await tools.call("stop_process", arguments: ["service": "api"], caller: reader)
    let seen = records.withLock { $0 }
    #expect(seen.map(\.tool) == ["list_nodes", "stop_process"])
    #expect(seen.map(\.who) == ["reader", "reader"])
    #expect(seen[0].error == nil)
    #expect(seen[1].error?.contains("write token") == true)
    #expect(seen[1].arguments == #"{"service":"api"}"#)
}

@Test func describeUnknownServiceIsAnError() async {
    let tools = TenderTools(backend: FakeBackend())
    let result = await tools.call("describe_process", arguments: ["service": "nope"], caller: reader)
    #expect(result.isError == true)
    let known = text(await tools.call("describe_process", arguments: ["service": "api"], caller: reader))
    #expect(known.contains("aaaaaaaaaaaa"))
    #expect(known.contains("\"recentErrors\""))
}

@Test func metricsSummaryAddsUpPerService() async {
    let tools = TenderTools(backend: FakeBackend())
    let summary = text(await tools.call("get_metrics_summary", arguments: [:], caller: reader))
    #expect(summary.contains(#""nodesDown" : ["#))
    #expect(summary.contains(#""mac-2""#))
    #expect(summary.contains(#""restarts" : 5"#))
    #expect(summary.contains(#""memoryBytes" : 150"#))
}

// MARK: Streamable HTTP

func rpc(_ method: String, id: Int, params: String = "{}") -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#.utf8)
}

let jsonHeaders = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]

@Test func httpServesInitializeListAndCall() async throws {
    let tools = TenderTools(backend: FakeBackend())
    let initialize = await TenderMCPServer.handle(
        method: "POST", headers: jsonHeaders,
        body: rpc("initialize", id: 1, params: #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#),
        tools: tools, caller: reader)
    #expect(initialize.status == 200)
    let body = String(decoding: initialize.body ?? Data(), as: UTF8.self)
    #expect(body.contains(#""name":"tender""#))

    let list = await TenderMCPServer.handle(method: "POST", headers: jsonHeaders, body: rpc("tools/list", id: 2),
                                            tools: tools, caller: reader)
    let listed = String(decoding: list.body ?? Data(), as: UTF8.self)
    #expect(listed.contains("search_logs"))
    #expect(!listed.contains("stop_process"))

    let call = await TenderMCPServer.handle(method: "POST", headers: jsonHeaders,
                                            body: rpc("tools/call", id: 3, params: #"{"name":"list_nodes","arguments":{}}"#),
                                            tools: tools, caller: reader)
    #expect(String(decoding: call.body ?? Data(), as: UTF8.self).contains("mac-2"))

    let get = await TenderMCPServer.handle(method: "GET", headers: jsonHeaders, body: nil, tools: tools, caller: reader)
    #expect(get.status == 405)
}

@Test func secretsListNamesAndMissingOnly() async {
    let tools = TenderTools(backend: FakeBackend())
    let result = text(await tools.call("list_secrets", arguments: ["service": "api"], caller: reader))
    #expect(result.contains("api/MONGO_PASSWORD"))
    #expect(!result.contains("worker/TOKEN"))
    #expect(result.range(of: "\"missing\"")!.lowerBound < result.range(of: "\"secrets\"")!.lowerBound)
    #expect(result.contains("JWT_KEY"))
    #expect(!result.contains("\"value\""))
}
