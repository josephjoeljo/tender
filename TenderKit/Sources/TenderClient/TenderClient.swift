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
        case .daemonUnreachable(let path, _):
            "Can't reach tenderd at \(path). Is it running? Try `tender daemon install --dev`."
        case .api(_, _, let message): message
        case .invalidResponse(let detail): "Unexpected response from tenderd: \(detail)"
        }
    }
}

/// Typed client for the Tender HTTP/JSON API, here over the local Unix socket.
public struct TenderClient: Sendable {
    public let socketPath: String
    private let timeout: TimeAmount

    public init(socketPath: String, timeout: Duration = .seconds(120)) {
        self.socketPath = socketPath
        self.timeout = .seconds(timeout.components.seconds)
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

    /// Creates or updates a service and starts it.
    public func start(_ spec: ServiceSpec) async throws -> ProcessList {
        try await send(.POST, "/v1/processes", body: try JSONEncoder().encode(spec))
    }

    /// Starts a service that already exists.
    public func start(service: String) async throws -> ProcessList {
        try await send(.POST, "/v1/processes/\(try escaped(service))/start")
    }

    public func stop(service: String) async throws -> ProcessList {
        try await send(.POST, "/v1/processes/\(try escaped(service))/stop")
    }

    public func restart(service: String) async throws -> ProcessList {
        try await send(.POST, "/v1/processes/\(try escaped(service))/restart")
    }

    public func delete(service: String) async throws -> ProcessList {
        try await send(.DELETE, "/v1/processes/\(try escaped(service))")
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
                    try self.probeSocket()
                    let path = try self.logsPath(service, lines, instance, stream, follow: true)
                    guard let url = URL(httpURLWithSocketPath: self.socketPath, uri: path) else {
                        throw TenderClientError.invalidResponse("bad socket path \(self.socketPath)")
                    }
                    let response = try await HTTPClient.shared.execute(
                        HTTPClientRequest(url: url.absoluteString), deadline: .distantFuture)
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

    public func releases(service: String) async throws -> ReleaseList {
        try await send(.GET, "/v1/releases/\(try escaped(service))")
    }

    /// Goes back to `sha12`, or by default to the release before the current one.
    public func rollback(service: String, to sha12: String? = nil) async throws -> ProcessList {
        try await send(.POST, "/v1/releases/\(try escaped(service))/rollback",
                       body: try JSONEncoder().encode(RollbackRequest(to: sha12)))
    }

    /// Boots out orphaned launchd jobs.
    public func collectGarbage() async throws -> ProcessList {
        try await send(.POST, "/v1/gc")
    }

    private func escaped(_ component: String) throws -> String {
        guard let value = component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
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

    private func probeSocket() throws {
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
        guard let url = URL(httpURLWithSocketPath: socketPath, uri: path) else {
            throw TenderClientError.invalidResponse("bad socket path \(socketPath)")
        }
        // HTTPClient retries a dead socket until its deadline. Fail fast instead.
        try probeSocket()
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method
        if let body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: body))
        }
        do {
            let response = try await HTTPClient.shared.execute(request, timeout: timeout)
            let buffer = try await response.body.collect(upTo: 16 << 20)
            return (Int(response.status.code), Data(buffer.readableBytesView))
        } catch {
            throw TenderClientError.daemonUnreachable(socketPath: socketPath, underlying: "\(error)")
        }
    }
}
