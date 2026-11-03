import AsyncHTTPClient
import Foundation
import NIOCore
import Testing
import TenderCore
import TenderLogStore
@testable import TenderClient
@testable import TenderHead

/// One JSON-RPC call to the head's `/mcp`, over the same pinned TLS as `TenderClient`.
private func mcp(_ address: String, caPEM: String, token: String?, _ body: String) async throws -> (Int, String) {
    var request = HTTPClientRequest(url: "https://\(address)/mcp")
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/json")
    request.headers.add(name: "Accept", value: "application/json, text/event-stream")
    if let token { request.headers.add(name: "Authorization", value: "Bearer \(token)") }
    request.body = .bytes(ByteBuffer(string: body))
    let response = try await PinnedClients.client(caPEM: caPEM).execute(request, timeout: .seconds(30))
    let bytes = try await response.body.collect(upTo: 1 << 20)
    return (Int(response.status.code), String(buffer: bytes))
}

private func call(_ tool: String, _ arguments: String = "{}", id: Int = 1) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
}

@Test func mcpOnThePublicListenerHonorsTokenScopesAndAudits() async throws {
    let head = try Daemon(node: "head", head: true)
    try await head.start()
    defer { head.cleanup() }
    let reader = try #require(try await eventually { try await head.client.createAPIToken(name: "claude-read", scope: .read) })
    let writer = try await head.client.createAPIToken(name: "claude-write", scope: .write)
    let address = "127.0.0.1:\(head.apiPort)"
    let caPEM = try await ClientPinning.fetchCA(head: address, credential: reader.token)

    let (unauthenticated, _) = try await mcp(address, caPEM: caPEM, token: nil, call("list_nodes"))
    #expect(unauthenticated == 401)

    let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    let (status, body) = try await mcp(address, caPEM: caPEM, token: reader.token, initialize)
    #expect(status == 200)
    #expect(body.contains(#""tools""#))

    // A read token may POST to /mcp, but only read tools work.
    let (_, listed) = try await mcp(address, caPEM: caPEM, token: reader.token,
                                    #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
    #expect(listed.contains("list_processes"))
    #expect(!listed.contains("restart_process"))
    let (_, nodes) = try await mcp(address, caPEM: caPEM, token: reader.token, call("list_nodes"))
    #expect(nodes.contains(#"\"node\" : \"head\""#) || nodes.contains("head"))
    let (_, refused) = try await mcp(address, caPEM: caPEM, token: reader.token, call("stop_process", #"{"service":"api"}"#))
    #expect(refused.contains(#""isError":true"#))
    #expect(refused.contains("write token"))

    let (_, planned) = try await mcp(address, caPEM: caPEM, token: writer.token,
                                     call("restart_process", #"{"service":"api","dry_run":true}"#))
    #expect(planned.contains("dryRun"))

    let file = head.env.root.appending(path: "logstore/audit-\(LogStore.dayName(Date())).jsonl")
    let audit = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(audit.contains { $0.contains(#""who":"claude-read""#) && $0.contains(#""tool":"list_nodes""#) })
    #expect(audit.contains { $0.contains(#""tool":"stop_process""#) && $0.contains("write token") && $0.contains(#""status":400"#) })
    #expect(audit.contains { $0.contains(#""who":"claude-write""#) && $0.contains(#""arguments":"{\"dry_run\":true,\"service\":\"api\"}""#) })
    #expect(!audit.contains { $0.contains(#""path":"\/mcp""#) && !$0.contains(#""tool""#) }, "MCP is audited per tool, not per request")
    for token in [reader.token, writer.token] {
        #expect(!audit.joined().contains(String(token.split(separator: ".")[0])))
    }
    await head.stop()
}
