import Foundation
import GRDB
import TenderCore

public struct LogStoreLimits: Sendable {
    public var maxAgeDays: Int
    public var maxBytes: Int64

    public init(maxAgeDays: Int = 30, maxBytes: Int64 = 5 << 30) {
        self.maxAgeDays = maxAgeDays
        self.maxBytes = maxBytes
    }
}

/// The head's durable logs: one SQLite file per UTC day of `ingest_ts`, so a node
/// with a wrong clock can't write into the wrong day, and expiring a day is deleting a file.
public actor LogStore {
    public let directory: URL
    private let limits: LogStoreLimits
    private let meta: DatabaseQueue
    private var days: [String: DatabaseQueue] = [:]
    private var acked: [NodeID: UInt64] = [:]
    private var ingested: [NodeID: UInt64] = [:]
    private var subscribers: [UUID: (query: LogQuery, continuation: AsyncStream<LogEntry>.Continuation)] = [:]

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public init(directory: URL, limits: LogStoreLimits = LogStoreLimits()) throws {
        self.directory = directory
        self.limits = limits
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        meta = try DatabaseQueue(path: directory.appending(path: "progress.db").path(percentEncoded: false))
        try meta.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS node_progress (node TEXT PRIMARY KEY, acked INTEGER NOT NULL, ingested INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS offloaded (name TEXT PRIMARY KEY, at REAL NOT NULL);
                """)
        }
        let rows = try meta.read { db in try Row.fetchAll(db, sql: "SELECT * FROM node_progress") }
        for row in rows {
            let node = NodeID(row["node"] as String)
            let ackedValue: Int64 = row["acked"]
            let ingestedValue: Int64 = row["ingested"]
            acked[node] = UInt64(ackedValue)
            ingested[node] = UInt64(ingestedValue)
        }
    }

    public static func dayName(_ date: Date) -> String { dayFormat.string(from: date) }

    private func fileURL(day: String) -> URL { directory.appending(path: "logs-\(day).db") }

    private func database(day: String) throws -> DatabaseQueue {
        if let existing = days[day] { return existing }
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        }
        let queue = try DatabaseQueue(path: fileURL(day: day).path(percentEncoded: false), configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS logs (
                    id INTEGER PRIMARY KEY,
                    node TEXT NOT NULL, seq INTEGER NOT NULL, node_ts REAL NOT NULL, ingest_ts REAL NOT NULL,
                    service TEXT NOT NULL, instance INTEGER NOT NULL, stream TEXT NOT NULL, line TEXT NOT NULL,
                    UNIQUE (node, seq)
                );
                CREATE INDEX IF NOT EXISTS logs_service_time ON logs (service, node_ts);
                CREATE INDEX IF NOT EXISTS logs_time ON logs (node_ts);
                CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5 (line, content='logs', content_rowid='id');
                CREATE TABLE IF NOT EXISTS gaps (
                    node TEXT NOT NULL, through_seq INTEGER NOT NULL, dropped INTEGER NOT NULL, recorded_at REAL NOT NULL,
                    PRIMARY KEY (node, through_seq)
                );
                """)
        }
        // Keep only the files likely to be written or read again open.
        if days.count >= 3, let oldest = days.keys.sorted().first { days[oldest] = nil }
        days[day] = queue
        return queue
    }

    /// Stores a batch and returns the highest sequence number safe to prune. If lines are
    /// missing before this batch, it's refused and the old ack tells the worker to rewind.
    /// A head that lost its state knows nothing about the node, so it accepts what comes.
    public func ingest(_ batch: LogBatch, now: Date = Date()) throws -> UInt64 {
        let current = acked[batch.node]
        if let current, batch.previousSeq > current,
           !batch.gaps.contains(where: { $0.throughSeq >= batch.previousSeq }) {
            return current
        }
        // Over the size limit even after retention, which never deletes today: stop
        // accepting. Lines stay in the worker's spool, within its own limits, rather
        // than filling the head's disk.
        if let current, (try? totalBytes()) ?? 0 > limits.maxBytes + limits.maxBytes / 10 {
            try enforceRetention(now: now)
            if ((try? totalBytes()) ?? 0) > limits.maxBytes + limits.maxBytes / 10 { return current }
        }
        let floor = current ?? 0
        let fresh = batch.records.filter { $0.seq > floor }
        let node = batch.node
        let day = Self.dayName(now)
        var newAck = max(floor, batch.previousSeq)
        for record in batch.records { newAck = max(newAck, record.seq) }

        if !fresh.isEmpty || !batch.gaps.isEmpty {
            try database(day: day).write { db in
                let insert = try db.makeStatement(sql: """
                    INSERT OR IGNORE INTO logs (node, seq, node_ts, ingest_ts, service, instance, stream, line)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                let index = try db.makeStatement(sql: "INSERT INTO logs_fts (rowid, line) VALUES (?, ?)")
                for record in fresh {
                    try insert.execute(arguments: [node.rawValue, Int64(record.seq), record.nodeTime.timeIntervalSince1970,
                                                   now.timeIntervalSince1970, record.service, record.instance,
                                                   record.stream.rawValue, record.line])
                    if db.changesCount > 0 {
                        try index.execute(arguments: [db.lastInsertedRowID, record.line])
                    }
                }
                for gap in batch.gaps {
                    try db.execute(sql: "INSERT OR IGNORE INTO gaps (node, through_seq, dropped, recorded_at) VALUES (?, ?, ?, ?)",
                                   arguments: [node.rawValue, Int64(gap.throughSeq), gap.droppedLines, gap.recordedAt.timeIntervalSince1970])
                }
            }
        }
        acked[node] = newAck
        ingested[node, default: 0] += UInt64(fresh.count)
        let total = ingested[node] ?? 0
        try meta.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO node_progress (node, acked, ingested) VALUES (?, ?, ?)",
                           arguments: [node.rawValue, Int64(newAck), Int64(total)])
        }
        if !subscribers.isEmpty {
            for record in fresh {
                let entry = LogEntry(node: node, seq: record.seq, nodeTime: record.nodeTime, ingestTime: now,
                                     service: record.service, instance: record.instance, stream: record.stream, line: record.line)
                for subscriber in subscribers.values where subscriber.query.matches(entry) {
                    subscriber.continuation.yield(entry)
                }
            }
        }
        return newAck
    }

    public func ingestedLines() -> [NodeID: UInt64] { ingested }

    // MARK: Reading

    public func dayFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix("logs-") && $0.hasSuffix(".db") }
            .map { String($0.dropFirst(5).dropLast(3)) }
            .sorted()
    }

    /// Double-quotes each word so that search text can't use FTS5 query syntax.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Newest matches, returned oldest first. Files are read newest first, one at a time,
    /// rather than with ATTACH, which SQLite limits to 10 files, and it stops once it has enough.
    public func search(_ query: LogQuery) throws -> LogSearchResult {
        let limit = min(max(query.limit, 1), LogQuery.maxLimit)
        var filters: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let service = query.service { filters.append("l.service = ?"); arguments.append(service) }
        if let node = query.node { filters.append("l.node = ?"); arguments.append(node) }
        if let stream = query.stream { filters.append("l.stream = ?"); arguments.append(stream.rawValue) }
        if let since = query.since { filters.append("l.node_ts >= ?"); arguments.append(since.timeIntervalSince1970) }
        if let until = query.until { filters.append("l.node_ts <= ?"); arguments.append(until.timeIntervalSince1970) }
        var from = "logs l"
        if let text = query.text, let match = Self.ftsQuery(text) {
            from = "logs_fts f JOIN logs l ON l.id = f.rowid"
            filters.append("logs_fts MATCH ?")
            arguments.append(match)
        }
        let whereClause = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")

        // A skewed node's times can fall a day either side of when they were ingested.
        let lowerDay = query.since.map { Self.dayName($0.addingTimeInterval(-86400)) }
        var result: [LogEntry] = []
        var gaps: [LogGap] = []
        for day in try dayFiles().reversed() {
            if let lowerDay, day < lowerDay { break }
            if result.count >= limit { break }
            let remaining = limit - result.count
            let rows: (entries: [LogEntry], gaps: [LogGap]) = try database(day: day).read { db in
                let entries = try Row.fetchAll(db, sql: """
                    SELECT l.* FROM \(from) \(whereClause) ORDER BY l.node_ts DESC, l.ingest_ts DESC, l.seq DESC LIMIT ?
                    """, arguments: StatementArguments(arguments + [remaining])).map(Self.entry)
                let gaps = try Row.fetchAll(db, sql: "SELECT * FROM gaps").map { row in
                    LogGap(node: NodeID(row["node"] as String), droppedLines: row["dropped"],
                           throughSeq: UInt64(row["through_seq"] as Int64),
                           recordedAt: Date(timeIntervalSince1970: row["recorded_at"]))
                }
                return (entries, gaps)
            }
            result += rows.entries
            gaps += rows.gaps.filter { gap in
                (query.node == nil || gap.node?.rawValue == query.node)
                    && (query.since.map { gap.recordedAt >= $0 } ?? true)
            }
        }
        return LogSearchResult(entries: result.reversed(), gaps: gaps.sorted { $0.recordedAt < $1.recordedAt })
    }

    private static func entry(_ row: Row) -> LogEntry {
        LogEntry(node: NodeID(row["node"] as String), seq: UInt64(row["seq"] as Int64),
                 nodeTime: Date(timeIntervalSince1970: row["node_ts"]),
                 ingestTime: Date(timeIntervalSince1970: row["ingest_ts"]),
                 service: row["service"], instance: row["instance"],
                 stream: LogLine.Stream(rawValue: row["stream"]) ?? .out, line: row["line"])
    }

    /// New lines as they land. A subscriber too slow to keep up loses the oldest.
    public func subscribe(_ query: LogQuery) -> AsyncStream<LogEntry> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: LogEntry.self, bufferingPolicy: .bufferingNewest(5_000))
        subscribers[id] = (query, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    // MARK: Retention

    /// Deletes days older than the age limit, then the oldest until under the size limit.
    /// Today's file is never deleted. Returns the days removed.
    @discardableResult
    public func enforceRetention(now: Date = Date()) throws -> [String] {
        let today = Self.dayName(now)
        let cutoff = Self.dayName(now.addingTimeInterval(-TimeInterval(limits.maxAgeDays) * 86400))
        var removed: [String] = []
        var remaining = try dayFiles()
        for day in remaining where day < cutoff && day != today {
            try delete(day: day)
            removed.append(day)
        }
        remaining.removeAll { removed.contains($0) }
        var total = remaining.reduce(Int64(0)) { $0 + size(day: $1) }
        for day in remaining where total > limits.maxBytes && day != today {
            total -= size(day: day)
            try delete(day: day)
            removed.append(day)
        }
        return removed
    }

    public func totalBytes() throws -> Int64 {
        try dayFiles().reduce(Int64(0)) { $0 + size(day: $1) }
    }

    private func size(day: String) -> Int64 {
        let base = fileURL(day: day).path(percentEncoded: false)
        return ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: base + suffix)
            return sum + ((attributes?[.size] as? Int64) ?? 0)
        }
    }

    private func delete(day: String) throws {
        days[day] = nil
        let base = fileURL(day: day).path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: base + suffix) }
    }

    // MARK: Offload

    /// Closed day files not yet offloaded, each flushed so that the one file is complete.
    public func closedDaysToOffload(now: Date = Date()) throws -> [(day: String, url: URL)] {
        let today = Self.dayName(now)
        let done = try meta.read { db in Set(try String.fetchAll(db, sql: "SELECT name FROM offloaded")) }
        var result: [(String, URL)] = []
        for day in try dayFiles() where day < today && !done.contains("logs-\(day).db") {
            try database(day: day).writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
            result.append((day, fileURL(day: day)))
        }
        return result
    }

    public func isOffloaded(_ name: String) throws -> Bool {
        try meta.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM offloaded WHERE name = ?", arguments: [name]) == true }
    }

    public func markOffloaded(_ name: String, now: Date = Date()) throws {
        try meta.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO offloaded (name, at) VALUES (?, ?)",
                           arguments: [name, now.timeIntervalSince1970])
        }
    }
}
