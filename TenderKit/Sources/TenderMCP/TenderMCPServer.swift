import Foundation
import MCP
import TenderCore

/// One HTTP exchange, so that the head serves MCP without importing the SDK (whose
/// `HTTPResponse` would clash with Hummingbird's).
public struct MCPHTTPExchange: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data?
}

/// Builds MCP servers around `TenderTools`.
public enum TenderMCPServer {
    static let instructions = """
        Tender runs services on a cluster of Macs under launchd. Start with get_metrics_summary or \
        list_processes, then describe_process or search_logs for one service. Responses are bounded; \
        when one says it was cut, narrow the request. Write tools need a write token and are rate \
        limited; pass dry_run first when unsure.
        """

    static func makeServer(tools: TenderTools, caller: MCPCaller) async -> Server {
        let server = Server(name: "tender", version: TenderVersion.current, instructions: instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools.definitions(for: caller))
        }
        await server.withMethodHandler(CallTool.self) { params in
            await tools.call(params.name, arguments: params.arguments ?? [:], caller: caller)
        }
        return server
    }

    /// Streamable HTTP without sessions: every POST is answered with one JSON response,
    /// and GET (the optional server-to-client stream) is refused with 405. A server per
    /// request keeps clients apart: JSON-RPC ids from different clients may collide.
    /// The caller is already authenticated; the Origin check is left out because a
    /// browser page can't attach the bearer token.
    public static func handle(method: String, headers: [String: String], body: Data?,
                              tools: TenderTools, caller: MCPCaller) async -> MCPHTTPExchange {
        let transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ]))
        let server = await makeServer(tools: tools, caller: caller)
        do {
            try await server.start(transport: transport)
        } catch {
            return MCPHTTPExchange(status: 500, headers: [:], body: Data("\(error)".utf8))
        }
        let response = await transport.handleRequest(HTTPRequest(method: method, headers: headers, body: body, path: "/mcp"))
        await server.stop()
        return MCPHTTPExchange(status: response.statusCode, headers: response.headers, body: response.bodyData)
    }

    /// `tender mcp`: MCP over stdin/stdout until the client closes it.
    public static func runStdio(tools: TenderTools, caller: MCPCaller) async throws {
        let server = await makeServer(tools: tools, caller: caller)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
