import Foundation

/// Reads the end of a log file.
public enum LogReader {
    /// The last `count` complete lines. Reads at most `maxBytes` from the end, so
    /// output stays bounded however long the lines are. A missing file has no lines.
    public static func lastLines(of url: URL, count: Int, maxBytes: Int = 8 << 20) throws -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        var position = size
        var chunks: [Data] = []
        var total = 0
        var newlines = 0
        let chunk: UInt64 = 64 * 1024
        while position > 0, total < maxBytes, newlines <= count {
            let length = min(chunk, position)
            position -= length
            try handle.seek(toOffset: position)
            let bytes = try handle.read(upToCount: Int(length)) ?? Data()
            newlines += bytes.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            total += bytes.count
            chunks.append(bytes)
        }
        var data = Data(capacity: total)
        for part in chunks.reversed() { data.append(part) }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        // If the read stopped mid-file, the first line is probably cut off.
        if position > 0, lines.count > count || data.count >= maxBytes { lines.removeFirst() }
        return lines.suffix(count).map(String.init)
    }
}

/// Offset-tracked tailing. Call `poll()` repeatedly. Starts over when the file is
/// truncated (copy-truncate rotation) or replaced (a new inode).
public struct LogFollower: Sendable {
    public let url: URL
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var partial = Data()
    private let maxReadPerPoll = 1 << 20

    /// Where a follower has read to: complete lines only, so it can be saved and resumed.
    public struct Position: Sendable, Equatable {
        public var inode: UInt64
        public var offset: UInt64

        public init(inode: UInt64, offset: UInt64) {
            self.inode = inode
            self.offset = offset
        }
    }

    public var position: Position { Position(inode: inode ?? 0, offset: offset - UInt64(partial.count)) }

    /// Resumes from a saved position. Without one, reads the file from its start.
    public init(url: URL, resumingFrom position: Position?) {
        self.url = url
        if let position {
            offset = position.offset
            inode = position.inode
        }
    }

    public init(url: URL, startAtEnd: Bool = true) {
        self.url = url
        if startAtEnd, let status = Self.status(of: url) {
            offset = status.size
            inode = status.inode
        }
    }

    private static func status(of url: URL) -> (size: UInt64, inode: UInt64)? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return (UInt64(info.st_size), UInt64(info.st_ino))
    }

    /// Complete lines written since the last call.
    public mutating func poll() throws -> [String] {
        guard let status = Self.status(of: url) else {
            offset = 0
            inode = nil
            partial = Data()
            return []
        }
        if status.inode != inode || status.size < offset {
            offset = 0
            partial = Data()
        }
        inode = status.inode
        guard status.size > offset else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: maxReadPerPoll) ?? Data()
        offset += UInt64(data.count)
        partial.append(data)

        guard let lastNewline = partial.lastIndex(of: 10) else {
            // A huge line without a newline is emitted as is rather than buffered forever.
            if partial.count >= maxReadPerPoll {
                defer { partial = Data() }
                return [String(decoding: partial, as: UTF8.self)]
            }
            return []
        }
        let complete = partial[partial.startIndex..<lastNewline]
        partial = Data(partial[partial.index(after: lastNewline)...])
        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Size-based rotation by copy-truncate. launchd holds the log's file descriptor
/// open for the life of the job, so renaming would leave it writing to the old
/// file. Lines written between the copy and the truncate are lost; that small
/// window is the accepted cost of not restarting the process.
public struct LogRotator: Sendable {
    public var maxBytes: UInt64
    /// How many rotated copies (`x.log.1` … `x.log.N`) to keep.
    public var keep: Int

    public init(maxBytes: UInt64 = 50 << 20, keep: Int = 3) {
        self.maxBytes = maxBytes
        self.keep = keep
    }

    /// Returns true if the file was rotated.
    @discardableResult
    public func rotateIfNeeded(_ url: URL) throws -> Bool {
        let files = FileManager.default
        let path = url.path(percentEncoded: false)
        guard let size = (try? files.attributesOfItem(atPath: path))?[.size] as? UInt64, size > maxBytes else {
            return false
        }
        func rotated(_ index: Int) -> String { "\(path).\(index)" }

        try? files.removeItem(atPath: rotated(keep))
        if keep > 1 {
            for index in stride(from: keep - 1, through: 1, by: -1) where files.fileExists(atPath: rotated(index)) {
                try files.moveItem(atPath: rotated(index), toPath: rotated(index + 1))
            }
        }
        if keep > 0 { try files.copyItem(atPath: path, toPath: rotated(1)) }
        guard truncate(path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }
}
