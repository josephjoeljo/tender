import Foundation
import HTTPTypes
import Hummingbird
import TenderCore
import TenderMCP

enum TenderMCPRoute {
    static let path = "/mcp"
}

/// The MCP tools' view of the head: its own services, called directly.
struct HeadBackend: ClusterBackend {
    let head: HeadServices

    func nodes() async throws -> NodeList { NodeList(nodes: await head.state.summaries()) }
    func processes() async throws -> ProcessList { await head.clusterStatus() }
    func searchLogs(_ query: LogQuery) async throws -> LogSearchResult { try await head.logs.search(query) }
    func releases(service: String) async throws -> ClusterReleases { await head.clusterReleases(service: service) }
    func start(service: String, node: String?) async throws -> ProcessList {
        try await head.command({ .startExisting(service: $0) }, service: service, node: node)
    }
    func stop(service: String, node: String?) async throws -> ProcessList {
        try await head.command({ .stop(service: $0) }, service: service, node: node)
    }
    func restart(service: String, node: String?) async throws -> ProcessList {
        try await head.command({ .restart(service: $0) }, service: service, node: node)
    }
    func deploy(_ request: DeployRequest) async throws -> DeployResponse { await head.deploy(request) }
    func rollback(service: String, to sha12: String?, node: String?) async throws -> ProcessList {
        try await head.rollback(service: service, to: sha12, node: node)
    }
}

extension HeadServices {
    var tools: TenderTools {
        mcpTools.withLockedValue { tools in
            if let tools { return tools }
            let audit = self.audit
            let created = TenderTools(backend: HeadBackend(head: self), onCall: { call in
                audit.record(.init(time: call.time, who: call.who, method: "MCP", path: TenderMCPRoute.path,
                                   status: call.error == nil ? 200 : 400, tool: call.tool, arguments: call.arguments,
                                   error: call.error, durationMs: Int((call.duration * 1000).rounded())))
            })
            tools = created
            return created
        }
    }

    /// MCP over streamable HTTP on the public listener. `BearerAuthMiddleware` has
    /// already checked the token; its name and scope decide what the tools allow.
    func installMCPRoute(on router: Router<BasicRequestContext>) {
        let store = self.store
        let handler: @Sendable (Request, BasicRequestContext) async throws -> Response = { [self] request, _ in
            let presented = request.headers[.authorization]?.dropFirst("Bearer ".count)
                .split(separator: ".").first.map(String.init) ?? ""
            guard let token = try? store.apiToken(secret: presented) else {
                return errorResponse(NodeCallError(code: "unauthorized", message: "Unknown token.", httpStatus: 401))
            }
            var headers: [String: String] = [:]
            for field in request.headers { headers[field.name.canonicalName] = field.value }
            var request = request
            let body = request.method == .post ? Data((try await request.collectBody(upTo: 1 << 20)).readableBytesView) : nil
            let exchange = await TenderMCPServer.handle(method: request.method.rawValue, headers: headers, body: body,
                                                        tools: tools, caller: MCPCaller(name: token.name, scope: token.scope))
            var fields = HTTPFields()
            for (name, value) in exchange.headers {
                if let name = HTTPField.Name(name) { fields[name] = value }
            }
            return Response(status: HTTPResponse.Status(code: exchange.status), headers: fields,
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: exchange.body ?? Data())))
        }
        router.post(RouterPath(TenderMCPRoute.path), use: handler)
        router.get(RouterPath(TenderMCPRoute.path), use: handler)
        router.delete(RouterPath(TenderMCPRoute.path), use: handler)
    }
}
