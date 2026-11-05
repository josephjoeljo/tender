import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import TenderCore

public enum TenderClientError: Error, CustomStringConvertible {
    case daemonUnreachable(socketPath: String, underlying: String)
    case api(status: Int, code: String, message: String)
    case invalidResponse(String)

    public var code: String {
        switch self {
        case .daemonUnreachable: "daemon_unreachable"
        case .api(_, let code, _): code
        case .invalidResponse: "invalid_response"
        }
    }

    public var description: String {
        switch self {
        case .daemonUnreachable(let path, let underlying):
            "Can't reach tenderd at \(path) (\(underlying)). Is it running? Try `tender daemon install --dev`, or sudo for a production daemon."
        case .api(_, _, let message): message
        case .invalidResponse(let detail): "Unexpected response from tenderd: \(detail)"
        }
    }
}

/// Typed client for the Tender HTTP/JSON API, here over the local Unix socket.
public struct TenderClient: Sendable {
    public enum Transport: Sendable {
        case unixSocket(String)
        /// A head over TLS, pinned to the cluster's CA.
        case https(head: String, caPEM: String, token: String)
    }

    public let transport: Transport
    private let timeout: TimeAmount

    public init(socketPath: String, timeout: Duration = .seconds(120)) {
        transport = .unixSocket(socketPath)
        self.timeout = .seconds(timeout.components.seconds)
    }

    public init(head: String, caPEM: String, token: String, defaultPort: Int = 7071, timeout: Duration = .seconds(120)) {
        transport = .https(head: head.contains(":") ? head : "\(head):\(defaultPort)", caPEM: caPEM, token: token)
        self.timeout = .seconds(timeout.components.seconds)
    }

    /// What this client talks to, for error messages.
    public var endpoint: String {
        switch transport {
        case .unixSocket(let path): path
        case .https(let head, _, _): head
        }
    }

    private func request(_ path: String) throws -> (HTTPClient, HTTPClientRequest) {
        switch transport {
        case .unixSocket(let socket):
            try probeSocket(socket)
            guard let url = URL(httpURLWithSocketPath: socket, uri: path) else {
                throw TenderClientError.invalidResponse("bad socket path \(socket)")
            }
            return (HTTPClient.shared, HTTPClientRequest(url: url.absoluteString))
        case .https(let head, let caPEM, let token):
            var request = HTTPClientRequest(url: "https://\(head)\(path)")
            request.headers.add(name: "Authorization", value: "Bearer \(token)")
            return (try PinnedClients.client(caPEM: caPEM), request)
        }
    }

    /// `TENDER_SOCKET` if set, else the dev daemon's socket if there is one,
    /// else the production socket.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["TENDER_SOCKET"], !override.isEmpty { return override }
        let development = TenderEnvironment.development.socketPath.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: development) { return development }
        return TenderEnvironment.production.socketPath.path(percentEncoded: false)
    }

    public func list() async throws -> ProcessList {
        try await send(.GET, "/v1/processes")
    }

    private func nodeQuery(_ node: String?) throws -> String {
        guard let node else { return "" }
        return "?node=\(try escaped(node))"
    }

    // MARK: Cluster

    public func nodes() async throws -> NodeList {
        try await send(.GET, "/v1/nodes")
    }

    /// Where the local daemon is listening. Only meaningful over the socket.
    public func network() async throws -> NetworkState {
        try await send(.GET, "/v1/network")
    }

    /// The head's in-memory stats for one node: up to a day, at most `limit` points
    /// (the head caps it), oldest first. A worker's daemon answers `http_404`.
    public func nodeHistory(node: String, since: Date? = nil, limit: Int? = nil) async throws -> NodeStatsHistory {
        var items: [String] = []
        if let since { items.append("since=\(since.timeIntervalSince1970)") }
        if let limit { items.append("limit=\(limit)") }
        let query = items.isEmpty ? "" : "?" + items.joined(separator: "&")
        return try await send(.GET, "/v1/nodes/\(try escaped(node))/history\(query)")
    }

    public func createJoinToken(ttlSeconds: Int? = nil) async throws -> JoinTokenResponse {
        try await send(.POST, "/v1/tokens", body: try JSONEncoder().encode(JoinTokenRequest(ttlSeconds: ttlSeconds)))
    }

    /// Asks the local daemon to join a head. Only meaningful over the socket.
    public func join(head: String, token: String, nodeID: String? = nil) async throws -> JoinStatus {
        try await send(.POST, "/v1/join", body: try JSONEncoder().encode(LocalJoinRequest(head: head, token: token, nodeID: nodeID)))
    }

    /// Makes the local daemon forget its cluster and restart. A worker's socket only.
    public func leave() async throws -> ProcessList {
        try await send(.POST, "/v1/leave")
    }

    public func revokeNode(_ id: String) async throws -> NodeList {
        try await send(.POST, "/v1/nodes/\(try escaped(id))/revoke")
    }

    /// Deletes the node's records on the head. Only over the socket.
    public func removeNode(_ id: String, force: Bool = false, purgeLogs: Bool = false) async throws -> NodeList {
        var query: [String] = []
        if force { query.append("force=true") }
        if purgeLogs { query.append("purge_logs=true") }
        return try await send(.DELETE, "/v1/nodes/\(try escaped(id))" + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    public func exportCA() async throws -> CertificateExport {
        try await send(.GET, "/v1/ca/export")
    }

    public func createAPIToken(name: String, scope: APIScope) async throws -> APITokenCreated {
        try await send(.POST, "/v1/api-tokens", body: try JSONEncoder().encode(APITokenCreateRequest(name: name, scope: scope)))
    }

    public func apiTokens() async throws -> APITokenList {
        try await send(.GET, "/v1/api-tokens")
    }

    public func revokeAPIToken(name: String) async throws -> APITokenList {
        try await send(.DELETE, "/v1/api-tokens/\(try escaped(name))")
    }

    /// Creates or updates a service and starts it.
    public func start(_ spec: ServiceSpec) async throws -> ProcessList {
        try await send(.POST, "/v1/processes", body: try JSONEncoder().encode(spec))
    }

    /// Starts a service that already exists.
    public func start(service: String, node: String? = nil) async throws -> ProcessList {
        try await send(.POST, "/v1/processes/\(try escaped(service))/start\(try nodeQuery(node))")
    }

    public func stop(service: String, node: String? = nil) async throws -> ProcessList {
        try await send(.POST, "/v1/processes/\(try escaped(service))/stop\(try nodeQuery(node))")
    }

    public func restart(service: String, node: String? = nil) async throws -> ProcessList {
        try await send(.POST, "/v1/processes/\(try escaped(service))/restart\(try nodeQuery(node))")
    }

    public func delete(service: String, node: String? = nil) async throws -> ProcessList {
        try await send(.DELETE, "/v1/processes/\(try escaped(service))\(try nodeQuery(node))")
    }

    public func logs(service: String, lines: Int = 200, instance: Int? = nil,
                     stream: LogLine.Stream? = nil) async throws -> LogResponse {
        try await send(.GET, try logsPath(service, lines, instance, stream, follow: false))
    }

    /// The last `lines` lines, then new lines as they are written, until cancelled.
    public func followLogs(service: String, lines: Int = 200, instance: Int? = nil,
                           stream: LogLine.Stream? = nil) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let path = try self.logsPath(service, lines, instance, stream, follow: true)
                    let (client, request) = try self.request(path)
                    let response = try await client.execute(request, deadline: .distantFuture)
                    guard response.status == .ok else {
                        let body = Data(try await response.body.collect(upTo: 1 << 20).readableBytesView)
                        throw Self.apiError(status: Int(response.status.code), data: body)
                    }
                    var pending = Data()
                    for try await chunk in response.body {
                        pending.append(contentsOf: chunk.readableBytesView)
                        while let newline = pending.firstIndex(of: 10) {
                            let line = pending[pending.startIndex..<newline]
                            pending = Data(pending[pending.index(after: newline)...])
                            if !line.isEmpty {
                                continuation.yield(try JSONDecoder().decode(LogLine.self, from: line))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func logsPath(_ service: String, _ lines: Int, _ instance: Int?, _ stream: LogLine.Stream?,
                          follow: Bool) throws -> String {
        var path = "/v1/processes/\(try escaped(service))/logs?lines=\(lines)"
        if let instance { path += "&instance=\(instance)" }
        if let stream { path += "&stream=\(stream.rawValue)" }
        if follow { path += "&follow=true" }
        return path
    }

    public func releases(service: String, node: String? = nil) async throws -> ReleaseList {
        try await send(.GET, "/v1/releases/\(try escaped(service))\(try nodeQuery(node))")
    }

    /// Goes back to `sha12`, or by default to the release before the current one.
    public func rollback(service: String, to sha12: String? = nil, node: String? = nil) async throws -> ProcessList {
        try await send(.POST, "/v1/releases/\(try escaped(service))/rollback\(try nodeQuery(node))",
                       body: try JSONEncoder().encode(RollbackRequest(to: sha12)))
    }

    /// Brings an existing launchd job under management.
    public func adopt(label: String, logPath: String? = nil, node: String? = nil) async throws -> ProcessList {
        try await send(.POST, "/v1/adopt\(try nodeQuery(node))", body: try JSONEncoder().encode(AdoptRequest(label: label, logPath: logPath)))
    }

    /// Stops managing an adopted job, leaving the job itself untouched.
    public func forget(label: String, node: String? = nil) async throws -> ProcessList {
        try await send(.DELETE, "/v1/adopt/\(try escaped(label))\(try nodeQuery(node))")
    }

    private func logQueryItems(_ query: LogQuery) throws -> String {
        var items: [String] = ["limit=\(query.limit)"]
        if let service = query.service { items.append("service=\(try escaped(service))") }
        if let node = query.node { items.append("node=\(try escaped(node))") }
        if let stream = query.stream { items.append("stream=\(stream.rawValue)") }
        if let since = query.since { items.append("since=\(since.timeIntervalSince1970)") }
        if let until = query.until { items.append("until=\(until.timeIntervalSince1970)") }
        if let text = query.text { items.append("query=\(try escaped(text))") }
        return items.joined(separator: "&")
    }

    /// Searches the head's logs. A worker's daemon answers `http_404`.
    public func searchLogs(_ query: LogQuery) async throws -> LogSearchResult {
        try await send(.GET, "/v1/logs?\(try logQueryItems(query))")
    }

    /// New matching lines from every node, from the head, until cancelled.
    public func followClusterLogs(_ query: LogQuery) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (client, request) = try self.request("/v1/logs/follow?\(try self.logQueryItems(query))")
                    let response = try await client.execute(request, deadline: .distantFuture)
                    guard response.status == .ok else {
                        let body = Data(try await response.body.collect(upTo: 1 << 20).readableBytesView)
                        throw Self.apiError(status: Int(response.status.code), data: body)
                    }
                    var pending = Data()
                    let separator = Data("\n\n".utf8)
                    for try await chunk in response.body {
                        pending.append(contentsOf: chunk.readableBytesView)
                        while let range = pending.range(of: separator) {
                            let event = pending[pending.startIndex..<range.lowerBound]
                            pending = Data(pending[range.upperBound...])
                            if event.starts(with: Data("data: ".utf8)) {
                                continuation.yield(try JSONDecoder().decode(LogEntry.self, from: event.dropFirst(6)))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func deploy(service: String, version: String, node: String? = nil) async throws -> DeployResponse {
        try await send(.POST, "/v1/deploy", body: try JSONEncoder().encode(DeployRequest(service: service, version: version, node: node)))
    }

    public func clusterReleases(service: String) async throws -> ClusterReleases {
        try await send(.GET, "/v1/releases?service=\(try escaped(service))")
    }

    /// Saves a service account key on the node this client talks to. Socket only.
    public func setCredentials(serviceAccountJSON: String) async throws -> CredentialsResponse {
        try await send(.POST, "/v1/credentials", body: try JSONEncoder().encode(CredentialsRequest(serviceAccountJSON: serviceAccountJSON)))
    }

    // MARK: Secrets

    /// `name` is `<service>/<NAME>` or `shared/<NAME>`. Through a head, a service's secret
    /// goes to every node running it unless `node` is given; a shared one needs `node` or
    /// `allNodes`. Services that reference it restart.
    public func setSecret(_ name: String, value: Data, node: String? = nil, allNodes: Bool = false) async throws -> SecretList {
        try await send(.PUT, "/v1/secrets/\(try secretPath(name))\(try secretQuery(node: node, allNodes: allNodes))",
                       body: try JSONEncoder().encode(SecretSetRequest(value: value)))
    }

    public func deleteSecret(_ name: String, node: String? = nil, allNodes: Bool = false) async throws -> SecretList {
        try await send(.DELETE, "/v1/secrets/\(try secretPath(name))\(try secretQuery(node: node, allNodes: allNodes))")
    }

    /// Names, nodes, revisions and users. Values never leave the node they're on.
    public func secrets(node: String? = nil) async throws -> SecretList {
        try await send(.GET, "/v1/secrets\(try nodeQuery(node))")
    }

    private func secretPath(_ name: String) throws -> String {
        guard let parsed = SecretName(path: name) else {
            throw TenderClientError.api(status: 400, code: "invalid_secret_name",
                                        message: "'\(name)' isn't <service>/<NAME> or shared/<NAME>. NAME uses letters, digits and '_'.")
        }
        return "\(try escaped(parsed.service ?? "shared"))/\(try escaped(parsed.name))"
    }

    private func secretQuery(node: String?, allNodes: Bool) throws -> String {
        if allNodes { return node == nil ? "?all=true" : "\(try nodeQuery(node))&all=true" }
        return try nodeQuery(node)
    }

    // MARK: Service files

    /// Diffs `request.items` against the cluster and, unless it's a dry run, applies them.
    /// Per-item and per-node failures are in the response, not thrown.
    public func apply(_ request: ApplyRequest) async throws -> ApplyResponse {
        try await send(.POST, "/v1/apply", body: try JSONEncoder().encode(request))
    }

    /// Every service and adopted job, in full. Through a head, needs a write token.
    public func specs(node: String? = nil) async throws -> SpecList {
        try await send(.GET, "/v1/specs\(try nodeQuery(node))")
    }

    /// Boots out orphaned launchd jobs.
    public func collectGarbage(node: String? = nil) async throws -> ProcessList {
        try await send(.POST, "/v1/gc\(try nodeQuery(node))")
    }

    /// RFC 3986 unreserved characters. The server matches path segments literally,
    /// so labels' dots and dashes must stay as they are.
    private static let pathComponentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private func escaped(_ component: String) throws -> String {
        guard let value = component.addingPercentEncoding(withAllowedCharacters: Self.pathComponentCharacters) else {
            throw TenderClientError.invalidResponse("can't encode '\(component)'")
        }
        return value
    }

    private func send<T: Decodable>(_ method: HTTPMethod, _ path: String, body: Data? = nil) async throws -> T {
        let (status, data) = try await perform(method, path, body: body)
        guard (200..<300).contains(status) else {
            throw Self.apiError(status: status, data: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TenderClientError.invalidResponse("\(error)")
        }
    }

    private static func apiError(status: Int, data: Data) -> TenderClientError {
        if let error = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            return .api(status: status, code: error.code, message: error.message)
        }
        return .api(status: status, code: "http_\(status)", message: "tenderd returned HTTP \(status).")
    }

    private func probeSocket(_ socketPath: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TenderClientError.daemonUnreachable(socketPath: socketPath, underlying: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = Array(socketPath.utf8CString)
        guard path.count <= capacity else {
            throw TenderClientError.daemonUnreachable(socketPath: socketPath, underlying: "socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw TenderClientError.daemonUnreachable(socketPath: socketPath, underlying: String(cString: strerror(errno)))
        }
    }

    func perform(_ method: HTTPMethod, _ path: String, body: Data? = nil) async throws -> (status: Int, data: Data) {
        var (client, request) = try self.request(path)
        request.method = method
        if let body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: body))
        }
        do {
            let response = try await client.execute(request, timeout: timeout)
            let buffer = try await response.body.collect(upTo: 16 << 20)
            return (Int(response.status.code), Data(buffer.readableBytesView))
        } catch {
            throw TenderClientError.daemonUnreachable(socketPath: endpoint, underlying: "\(error)")
        }
    }
}
