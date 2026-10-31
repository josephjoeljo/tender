import Foundation
import GRDB
import LogTail
import TenderCore

public struct LogSpoolLimits: Sendable {
    public var maxBytes: Int64
    public var maxAge: TimeInterval

    public init(maxBytes: Int64 = 1 << 30, maxAge: TimeInterval = 7 * 86400) {
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }
}

/// A worker's durable queue of log lines. Lines and the tail offsets they came from are
/// saved in one transaction, so a restart neither loses nor duplicates lines.
public struct LogSpool: Sendable {
    public static let maxLineBytes = 64 << 10
    private let queue: DatabaseQueue
    private let limits: LogSpoolLimits

    public init(directory: URL, limits: LogSpoolLimits = LogSpoolLimits()) throws {
        self.limits = limits
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "spool.db").path(percentEncoded: false)
        Darwin.close(Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600))
        chmod(path, 0o600)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        }
        queue = try DatabaseQueue(path: path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS spool (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    node_ts REAL NOT NULL, service TEXT NOT NULL, instance INTEGER NOT NULL,
                    stream TEXT NOT NULL, line TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS offsets (path TEXT PRIMARY KEY, inode INTEGER NOT NULL, offset INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS gaps (through_seq INTEGER PRIMARY KEY, dropped INTEGER NOT NULL, recorded_at REAL NOT NULL);
                """)
        }
    }

    public func position(of url: URL) throws -> LogFollower.Position? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM offsets WHERE path = ?", arguments: [url.path(percentEncoded: false)])
                .map { LogFollower.Position(inode: UInt64($0["inode"] as Int64), offset: UInt64($0["offset"] as Int64)) }
        }
    }

    public struct Pending: Sendable {
        public var service: String
        public var instance: Int
        public var stream: LogLine.Stream
        public var lines: [String]
        public var file: URL
        public var position: LogFollower.Position

        public init(service: String, instance: Int, stream: LogLine.Stream, lines: [String], file: URL,
                    position: LogFollower.Position) {
            self.service = service
            self.instance = instance
            self.stream = stream
            self.lines = lines
            self.file = file
            self.position = position
        }
    }

    public func append(_ pending: [Pending], now: Date = Date()) throws {
        try queue.write { db in
            let insert = try db.makeStatement(sql: "INSERT INTO spool (node_ts, service, instance, stream, line) VALUES (?, ?, ?, ?, ?)")
            var bytes: Int64 = 0
            for item in pending {
                for line in item.lines {
                    let text = Self.bounded(line)
                    bytes += Int64(text.utf8.count)
                    try insert.execute(arguments: [now.timeIntervalSince1970, item.service, item.instance, item.stream.rawValue, text])
                }
                try db.execute(sql: "INSERT OR REPLACE INTO offsets (path, inode, offset) VALUES (?, ?, ?)",
                               arguments: [item.file.path(percentEncoded: false), Int64(item.position.inode), Int64(item.position.offset)])
            }
            try Self.add(bytes, to: "bytes", db)
        }
    }

    private static func bounded(_ line: String) -> String {
        guard line.utf8.count > maxLineBytes else { return line }
        return String(decoding: line.utf8.prefix(maxLineBytes), as: UTF8.self) + "…[truncated]"
    }

    private static func add(_ delta: Int64, to name: String, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO counters (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = MAX(value + excluded.value, 0)",
                       arguments: [name, delta])
    }

    private static func counter(_ name: String, _ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT value FROM counters WHERE name = ?", arguments: [name]) ?? 0
    }

    /// The next lines after `cursor`, bounded by count and bytes.
    public func nextBatch(node: NodeID, maxLines: Int = 1_000, maxBytes: Int = 4 << 20) throws -> LogBatch {
        try queue.read { db in
            let cursor = UInt64(try Self.counter("acked", db))
            let gaps = try Row.fetchAll(db, sql: "SELECT * FROM gaps ORDER BY through_seq").map { row in
                LogGap(droppedLines: row["dropped"], throughSeq: UInt64(row["through_seq"] as Int64),
                       recordedAt: Date(timeIntervalSince1970: row["recorded_at"]))
            }
            let previous = max(cursor, gaps.last?.throughSeq ?? 0)
            var records: [LogRecord] = []
            var bytes = 0
            let rows = try Row.fetchCursor(db, sql: "SELECT * FROM spool WHERE seq > ? ORDER BY seq LIMIT ?",
                                           arguments: [Int64(previous), maxLines])
            while let row = try rows.next() {
                let line: String = row["line"]
                bytes += line.utf8.count
                if bytes > maxBytes, !records.isEmpty { break }
                records.append(LogRecord(seq: UInt64(row["seq"] as Int64), nodeTime: Date(timeIntervalSince1970: row["node_ts"]),
                                         service: row["service"], instance: row["instance"],
                                         stream: LogLine.Stream(rawValue: row["stream"]) ?? .out, line: line))
            }
            return LogBatch(node: node, previousSeq: previous, records: records, gaps: gaps)
        }
    }

    /// The head has everything through `seq`.
    public func acknowledge(through seq: UInt64) throws {
        try queue.write { db in
            let previous = try Self.counter("acked", db)
            guard Int64(seq) > previous else { return }
            let freed = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(CAST(line AS BLOB))), 0) FROM spool WHERE seq <= ?", arguments: [Int64(seq)]) ?? 0
            try db.execute(sql: "DELETE FROM spool WHERE seq <= ?", arguments: [Int64(seq)])
            try db.execute(sql: "DELETE FROM gaps WHERE through_seq <= ?", arguments: [Int64(seq)])
            try Self.add(-freed, to: "bytes", db)
            try Self.add(Int64(seq) - previous, to: "acked", db)
        }
    }

    /// Drops the oldest unacknowledged lines beyond the limits and records a gap.
    /// Returns how many were dropped.
    @discardableResult
    public func enforceLimits(now: Date = Date()) throws -> Int {
        try queue.write { db in
            var dropped = 0
            var through: Int64 = 0
            var freed: Int64 = 0
            let cutoff = now.timeIntervalSince1970 - limits.maxAge
            var bytes = try Self.counter("bytes", db)
            // In chunks, down to 90%, so that it doesn't run for every new line.
            while true {
                let overSize = bytes > limits.maxBytes
                let sizeTarget = overSize ? limits.maxBytes / 10 * 9 : limits.maxBytes
                let rows = try Row.fetchAll(db, sql: """
                    SELECT seq, node_ts, LENGTH(CAST(line AS BLOB)) AS size FROM spool ORDER BY seq LIMIT 5000
                    """)
                guard !rows.isEmpty else { break }
                var stop = false
                var lastInChunk: Int64 = 0
                for row in rows {
                    let time: Double = row["node_ts"]
                    guard bytes > sizeTarget && overSize || time < cutoff else {
                        stop = true
                        break
                    }
                    let size: Int64 = row["size"]
                    bytes -= size
                    freed += size
                    dropped += 1
                    lastInChunk = row["seq"]
                }
                if lastInChunk > 0 {
                    through = lastInChunk
                    try db.execute(sql: "DELETE FROM spool WHERE seq <= ?", arguments: [lastInChunk])
                }
                if stop { break }
            }
            guard dropped > 0 else { return 0 }
            try Self.add(-freed, to: "bytes", db)
            try Self.add(Int64(dropped), to: "dropped", db)
            try db.execute(sql: "INSERT OR REPLACE INTO gaps (through_seq, dropped, recorded_at) VALUES (?, ?, ?)",
                           arguments: [through, dropped, now.timeIntervalSince1970])
            return dropped
        }
    }

    public func backlog() throws -> Int {
        try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spool") ?? 0 }
    }

    public func droppedTotal() throws -> Int {
        try queue.read { db in Int(try Self.counter("dropped", db)) }
    }

    public func byteCount() throws -> Int64 {
        try queue.read { db in try Self.counter("bytes", db) }
    }

    /// The head told us to go back: it's missing lines we thought it had.
    public func rewind(to seq: UInt64) throws {
        try queue.write { db in
            let current = try Self.counter("acked", db)
            if Int64(seq) < current {
                try db.execute(sql: "UPDATE counters SET value = ? WHERE name = 'acked'", arguments: [Int64(seq)])
            }
        }
    }
}
