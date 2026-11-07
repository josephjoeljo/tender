import Foundation
import Hummingbird
import Logging
import NIOConcurrencyHelpers
import ServiceLifecycle
import TenderAgent
import TenderCore
import TenderLogStore
import TenderMetrics

/// Who changed what, when, and how it went. One JSON line per mutating call, in a file
/// per UTC day. Request bodies are left out, because they can hold secrets.
public final class AuditLog: Sendable {
    public typealias Record = AuditRecord

    /// Set while a call runs, so that its handler can add a `detail` to the call's record.
    @TaskLocal static var note: AuditNote?

    public let directory: URL
    private let lock = NIOLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fileURL(day: String) -> URL { directory.appending(path: "audit-\(day).jsonl") }

    public func record(_ record: Record) {
        guard let line = try? encoder.encode(record) else { return }
        let url = fileURL(day: LogStore.dayName(record.time))
        lock.withLock {
            let path = url.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data("\n".utf8))
        }
    }

    /// Records matching `query`, newest first, reading day files from the newest back and
    /// stopping once `limit` is reached. Lines that don't decode are skipped.
    public func read(_ query: AuditQuery) -> AuditList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let sinceDay = query.since.map { "audit-\(LogStore.dayName($0)).jsonl" }
        let untilDay = query.until.map { "audit-\(LogStore.dayName($0)).jsonl" }
        let days = names.filter { $0.hasPrefix("audit-") && $0.hasSuffix(".jsonl") }
            .filter { name in sinceDay.map { name >= $0 } ?? true && untilDay.map { name <= $0 } ?? true }
            .sorted(by: >)
        var records: [AuditRecord] = []
        for day in days {
            let data = lock.withLock { try? Data(contentsOf: directory.appending(path: day)) } ?? Data()
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                guard let record = try? decoder.decode(AuditRecord.self, from: Data(line)), query.matches(record) else { continue }
                if records.count == query.limit { return AuditList(records: records, truncated: true) }
                records.append(record)
            }
        }
        return AuditList(records: records)
    }

    /// Days before `today`, by file name.
    public func closedFiles(today: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasPrefix("audit-") && $0.hasSuffix(".jsonl") && $0 < "audit-\(today).jsonl" }
            .sorted().map { directory.appending(path: $0) }
    }
}

/// Records every call that isn't a read. The path can't hold a secret: tokens travel
/// in headers and bodies, which aren't recorded, and query strings are dropped.
struct AuditMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let audit: AuditLog
    let who: @Sendable (Request) -> String

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard request.method != .get, request.routedPath != "/v1/join" else { return try await next(request, context) }
        let note = AuditNote()
        do {
            let response = try await AuditLog.$note.withValue(note) { try await next(request, context) }
            audit.record(.init(time: Date(), who: who(request), method: request.method.rawValue,
                               path: request.routedPath, status: response.status.code, detail: note.text, node: node(request)))
            return response
        } catch {
            audit.record(.init(time: Date(), who: who(request), method: request.method.rawValue,
                               path: request.routedPath, status: 500, detail: note.text, node: node(request)))
            throw error
        }
    }

    /// The only query parameter kept: a node reference, which can't hold a secret.
    private func node(_ request: Request) -> String? {
        request.uri.queryParameters.get("node").map { String($0) }.flatMap { $0.count <= 128 ? $0 : nil }
    }
}

final class AuditNote: Sendable {
    private let box = NIOLockedValueBox<String?>(nil)

    var text: String? {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
}

/// Uploads closed days once each. A failure is retried at the next pass, and nothing
/// depends on it: retention works on age and size, whether or not a file was uploaded.
public struct NightlyOffload: Service {
    let logs: LogStore
    let audit: AuditLog
    let uploader: @Sendable () throws -> (any BlobUploader)?
    let logger: Logger
    let interval: Duration

    public init(logs: LogStore, audit: AuditLog, uploader: @escaping @Sendable () throws -> (any BlobUploader)?,
                logger: Logger = Logger(label: "tender.offload"), interval: Duration = .seconds(1800)) {
        self.logs = logs
        self.audit = audit
        self.uploader = uploader
        self.logger = logger
        self.interval = interval
    }

    /// Returns how many files went up.
    @discardableResult
    public func runOnce(now: Date = Date()) async throws -> Int {
        guard let uploader = try uploader() else { return 0 }
        var uploaded = 0
        for (_, url) in try await logs.closedDaysToOffload(now: now) {
            try await uploader.upload(file: url, as: "logs/\(url.lastPathComponent)")
            try await logs.markOffloaded(url.lastPathComponent, now: now)
            uploaded += 1
        }
        for url in audit.closedFiles(today: LogStore.dayName(now)) where try await !logs.isOffloaded(url.lastPathComponent) {
            try await uploader.upload(file: url, as: "audit/\(url.lastPathComponent)")
            try await logs.markOffloaded(url.lastPathComponent, now: now)
            uploaded += 1
        }
        return uploaded
    }

    public func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do {
                    let count = try await runOnce()
                    if count > 0 { logger.info("offloaded files", metadata: ["count": "\(count)"]) }
                } catch {
                    logger.error("offload failed, will retry", metadata: ["error": "\(error)"])
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}

/// Counts deploys per service and result, for `/metrics`.
final class DeployCounter: Sendable {
    private let counts = NIOLockedValueBox<[String: [String: UInt64]]>([:])

    func add(service: String, result: String) {
        counts.withLockedValue { $0[service, default: [:]][result, default: 0] += 1 }
    }

    var snapshot: [MetricsSnapshot.DeployCount] {
        counts.withLockedValue { counts in
            counts.flatMap { service, results in
                results.map { MetricsSnapshot.DeployCount(service: service, result: $0.key, count: $0.value) }
            }.sorted { ($0.service, $0.result) < ($1.service, $1.result) }
        }
    }
}
