import Foundation

/// A line in a worker's spool, on its way to the head.
public struct LogRecord: Codable, Sendable, Equatable {
    public var seq: UInt64
    public var nodeTime: Date
    public var service: String
    public var instance: Int
    public var stream: LogLine.Stream
    public var line: String

    public init(seq: UInt64, nodeTime: Date, service: String, instance: Int, stream: LogLine.Stream, line: String) {
        self.seq = seq
        self.nodeTime = nodeTime
        self.service = service
        self.instance = instance
        self.stream = stream
        self.line = line
    }
}

/// Lines a worker dropped because its spool was over its limits.
public struct LogGap: Codable, Sendable, Equatable {
    public var node: NodeID?
    public var droppedLines: Int
    /// The highest sequence number lost.
    public var throughSeq: UInt64
    public var recordedAt: Date

    public init(node: NodeID? = nil, droppedLines: Int, throughSeq: UInt64, recordedAt: Date) {
        self.node = node
        self.droppedLines = droppedLines
        self.throughSeq = throughSeq
        self.recordedAt = recordedAt
    }
}

public struct LogBatch: Codable, Sendable, Equatable {
    public var node: NodeID
    /// The sequence number just before this batch's first line.
    public var previousSeq: UInt64
    public var records: [LogRecord]
    public var gaps: [LogGap]

    public init(node: NodeID, previousSeq: UInt64, records: [LogRecord], gaps: [LogGap] = []) {
        self.node = node
        self.previousSeq = previousSeq
        self.records = records
        self.gaps = gaps
    }
}

/// A line as stored by the head.
public struct LogEntry: Codable, Sendable, Equatable {
    public var node: NodeID
    public var seq: UInt64
    public var nodeTime: Date
    public var ingestTime: Date
    public var service: String
    public var instance: Int
    public var stream: LogLine.Stream
    public var line: String

    public init(node: NodeID, seq: UInt64, nodeTime: Date, ingestTime: Date, service: String, instance: Int,
                stream: LogLine.Stream, line: String) {
        self.node = node
        self.seq = seq
        self.nodeTime = nodeTime
        self.ingestTime = ingestTime
        self.service = service
        self.instance = instance
        self.stream = stream
        self.line = line
    }
}

public struct LogQuery: Codable, Sendable, Equatable {
    public static let maxLimit = 5_000

    public var service: String?
    public var node: String?
    public var stream: LogLine.Stream?
    public var since: Date?
    public var until: Date?
    /// Words that must all appear, matched by the full-text index.
    public var text: String?
    public var limit: Int

    public init(service: String? = nil, node: String? = nil, stream: LogLine.Stream? = nil, since: Date? = nil,
                until: Date? = nil, text: String? = nil, limit: Int = 200) {
        self.service = service
        self.node = node
        self.stream = stream
        self.since = since
        self.until = until
        self.text = text
        self.limit = limit
    }

    /// For live follow, where the full-text index isn't involved.
    public func matches(_ entry: LogEntry) -> Bool {
        if let service, entry.service != service { return false }
        if let node, entry.node.rawValue != node { return false }
        if let stream, entry.stream != stream { return false }
        if let text {
            let line = entry.line.lowercased()
            for word in text.lowercased().split(whereSeparator: \.isWhitespace) where !line.contains(word) { return false }
        }
        return true
    }
}

/// Oldest first. Order across nodes is approximate: their clocks differ.
public struct LogSearchResult: Codable, Sendable, Equatable {
    public var entries: [LogEntry]
    public var gaps: [LogGap]

    public init(entries: [LogEntry], gaps: [LogGap] = []) {
        self.entries = entries
        self.gaps = gaps
    }
}
