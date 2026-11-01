import Foundation
import LogTail
import Testing
import TenderCore
@testable import TenderAgent

private let node = NodeID("n")
private func pending(_ lines: [String], file: String = "/x", offset: UInt64 = 1) -> LogSpool.Pending {
    LogSpool.Pending(service: "api", instance: 0, stream: .out, lines: lines, file: URL(filePath: file),
                     position: LogFollower.Position(inode: 5, offset: offset))
}

private func makeSpool(_ limits: LogSpoolLimits = LogSpoolLimits()) throws -> (LogSpool, URL) {
    let directory = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    return (try LogSpool(directory: directory, limits: limits), directory)
}

@Test func spoolBatchesAndPrunesOnAck() throws {
    let (spool, directory) = try makeSpool()
    defer { try? FileManager.default.removeItem(at: directory) }
    try spool.append([pending(["a", "b", "c"])])
    var batch = try spool.nextBatch(node: node, maxLines: 2)
    #expect(batch.records.map(\.line) == ["a", "b"])
    #expect(batch.records.map(\.seq) == [1, 2])
    #expect(batch.previousSeq == 0)
    try spool.acknowledge(through: 2)
    #expect(try spool.backlog() == 1)
    batch = try spool.nextBatch(node: node)
    #expect(batch.previousSeq == 2)
    #expect(batch.records.map(\.line) == ["c"])
    try spool.acknowledge(through: 3)
    #expect(try spool.byteCount() == 0)
    // Sequence numbers don't get reused, even with an empty table.
    try spool.append([pending(["d"])])
    #expect(try spool.nextBatch(node: node).records.first?.seq == 4)
}

@Test func spoolSurvivesAndKeepsOffsetsWithLinesAtomically() throws {
    let directory = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try LogSpool(directory: directory)
    try first.append([pending(["a"], file: "/log", offset: 42)])
    let second = try LogSpool(directory: directory)
    #expect(try second.position(of: URL(filePath: "/log")) == LogFollower.Position(inode: 5, offset: 42))
    #expect(try second.backlog() == 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "spool.db").path(percentEncoded: false))
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

@Test func spoolDropsOldestOverSizeAndRecordsAGap() throws {
    let (spool, directory) = try makeSpool(LogSpoolLimits(maxBytes: 100))
    defer { try? FileManager.default.removeItem(at: directory) }
    try spool.append([pending((0..<50).map { String(format: "line%04d", $0) })]) // 8 bytes each, 400 total
    let dropped = try spool.enforceLimits()
    #expect(dropped > 0)
    #expect(try spool.byteCount() <= 100)
    #expect(try spool.droppedTotal() == dropped)
    #expect(try spool.backlog() == 50 - dropped)
    let batch = try spool.nextBatch(node: node)
    #expect(batch.gaps.first?.droppedLines == dropped)
    #expect(batch.gaps.first?.throughSeq == UInt64(dropped))
    #expect(batch.previousSeq == UInt64(dropped))
    #expect(batch.records.first?.seq == UInt64(dropped + 1))
    try spool.acknowledge(through: batch.records.last!.seq)
    #expect(try spool.nextBatch(node: node).gaps.isEmpty)
    #expect(try spool.enforceLimits() == 0)
}

@Test func spoolDropsByAge() throws {
    let (spool, directory) = try makeSpool(LogSpoolLimits(maxAge: 60))
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    try spool.append([pending(["old"])], now: now.addingTimeInterval(-120))
    try spool.append([pending(["new"])], now: now)
    #expect(try spool.enforceLimits(now: now) == 1)
    #expect(try spool.nextBatch(node: node).records.map(\.line) == ["new"])
}

@Test func enormousLineIsBounded() throws {
    let (spool, directory) = try makeSpool()
    defer { try? FileManager.default.removeItem(at: directory) }
    try spool.append([pending([String(repeating: "x", count: 1 << 20)])])
    let line = try #require(try spool.nextBatch(node: node).records.first?.line)
    #expect(line.utf8.count < LogSpool.maxLineBytes + 100)
    #expect(line.hasSuffix("[truncated]"))
}

@Test func batchIsBoundedByBytes() throws {
    let (spool, directory) = try makeSpool()
    defer { try? FileManager.default.removeItem(at: directory) }
    try spool.append([pending((0..<10).map { _ in String(repeating: "y", count: 1000) })])
    #expect(try spool.nextBatch(node: node, maxBytes: 2500).records.count == 2)
    #expect(try spool.nextBatch(node: node, maxBytes: 10).records.count == 1, "one line always fits, so it can't stall")
}

@Test func rewindGoesBackOnly() throws {
    let (spool, directory) = try makeSpool()
    defer { try? FileManager.default.removeItem(at: directory) }
    try spool.append([pending(["a", "b"])])
    try spool.acknowledge(through: 1)
    try spool.rewind(to: 0)
    #expect(try spool.nextBatch(node: node).previousSeq == 0)
    try spool.rewind(to: 5)
    #expect(try spool.nextBatch(node: node).previousSeq == 0)
}
